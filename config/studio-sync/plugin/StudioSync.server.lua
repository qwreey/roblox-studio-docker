--[[
	studio-sync: one-shot Rojo syncs requested from outside Studio.

	Built into a plugin next to an unmodified copy of Rojo's own plugin modules (see
	build.sh); this script replaces Rojo's UI entry point. It polls one port on code-docker (through studio-front)
	for a `rojo serve` whose project name is a studio-sync request
	(`studio-sync owner=<name> reply=<port>`, written by the studio-sync CLI), then:

	1. claims the request at the reply port, so only one open place handles it,
	2. runs Rojo's initial sync once - Rojo's own diff and reconciler, no confirmation,
	   no WebSocket afterwards - unless something it would change belongs to another
	   agent (an AgentOwner attribute on it or an ancestor),
	3. sets AgentOwner on the project's top-level instances under each service,
	4. reports the result to the reply port and forgets the session.

	A `studio-sync release owner=<name>` request (`studio-sync --release`, no Rojo behind
	it) instead clears AgentOwner wherever it names that owner.

	A person's ordinary `rojo serve` is never touched: its project name doesn't match.
]]

if not plugin then
	return
end

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

if not RunService:IsEdit() then
	return
end

local Rojo = script:FindFirstAncestor("Rojo")
local Http = require(Rojo.Packages.Http)
local ApiContext = require(Rojo.Plugin.ApiContext)
local ServeSession = require(Rojo.Plugin.ServeSession)

-- code-docker as seen from Studio's network: studio-front forwards these ports to it.
local HOST = "studio-front"
-- studio-sync's fixed serve port. One port, not a range: every probe of a closed port
-- costs a few lines in Studio's log, and concurrent syncs queue on the CLI side anyway.
local PORT = 34880
local POLL_SECONDS = 2
local OWNER_ATTRIBUTE = "AgentOwner"
-- Matches what the CLI lets through (ASCII letters, digits, . _ / -).
local REQUEST_PATTERN = "^studio%-sync owner=([%w%._/%-]+) reply=(%d+)$"
-- `studio-sync --release`: no Rojo involved, the CLI answers /api/rojo itself.
local RELEASE_PATTERN = "^studio%-sync release owner=([%w%._/%-]+) reply=(%d+)$"
-- Engine-made containers that sit between a service and a project's own instances: the
-- project's instances inside them are what gets an owner, never the shared container.
local SHARED_CONTAINERS = { StarterPlayerScripts = true, StarterCharacterScripts = true }

local function post(port, path, body)
	return pcall(function()
		return HttpService:RequestAsync({
			Url = `http://{HOST}:{port}{path}`,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(body),
		})
	end)
end

-- The nearest AgentOwner on the instance or its ancestors, and where it was found.
local function ownerOf(instance)
	local current = instance
	while current ~= nil and current ~= game do
		local owner = current:GetAttribute(OWNER_ATTRIBUTE)
		if owner ~= nil then
			return owner, current
		end
		current = current.Parent
	end
	return nil, nil
end

-- Describes the first instance this sync would touch that another agent owns.
local function findConflict(instanceMap, patch, owner)
	local function check(instance)
		if typeof(instance) ~= "Instance" then
			return nil
		end
		local found, at = ownerOf(instance)
		if found ~= nil and found ~= owner then
			return `{at:GetFullName()} belongs to {found}`
		end
		return nil
	end

	for instance in instanceMap.fromInstances do
		local conflict = check(instance)
		if conflict then
			return conflict
		end
	end
	for _, instance in patch.removed do
		local conflict = check(instance)
		if conflict then
			return conflict
		end
	end
	return nil
end

local function countKeys(dictionary)
	local count = 0
	for _ in dictionary do
		count += 1
	end
	return count
end

-- Rojo renames the DataModel after the served project, and the served project here is
-- studio-sync's wrapper, named after the request. The place keeps its own name.
local function keepPlaceName(instanceMap, patch)
	local gameId = instanceMap.fromInstances[game]
	for index = #patch.updated, 1, -1 do
		local update = patch.updated[index]
		if update.id == gameId then
			update.changedName = nil
			if update.changedClassName == nil and next(update.changedProperties or {}) == nil then
				table.remove(patch.updated, index)
			end
		end
	end
end

local function stampOwner(instanceMap, owner)
	local roots = {}
	for instance in instanceMap.fromInstances do
		local parent = instance.Parent
		local underService = parent ~= nil and parent.Parent == game
		local underSharedContainer = parent ~= nil and SHARED_CONTAINERS[parent.ClassName] == true
		if (underService or underSharedContainer) and not SHARED_CONTAINERS[instance.ClassName] then
			instance:SetAttribute(OWNER_ATTRIBUTE, owner)
			table.insert(roots, instance:GetFullName())
		end
	end
	table.sort(roots)
	return roots
end

local function syncOnce(apiContext, serverInfo, owner, replyPort)
	local result = { ok = false, owner = owner, place = game.Name }

	local session = ServeSession.new({ apiContext = apiContext, twoWaySync = false })
	session:setConfirmCallback(function(instanceMap, patch)
		keepPlaceName(instanceMap, patch)
		local conflict = findConflict(instanceMap, patch, owner)
		if conflict then
			result.error = `refused: {conflict}`
			return "Abort"
		end
		result.added = countKeys(patch.added)
		result.updated = #patch.updated
		result.removed = #patch.removed
		return "Accept"
	end)
	-- Postcommit callbacks run (task.spawn, no yield) before the initial sync resolves.
	session:hookPostcommit(function(_patch, _instanceMap, unappliedPatch)
		result.unapplied = countKeys(unappliedPatch.added) + #unappliedPatch.updated + #unappliedPatch.removed
	end)

	-- Rojo's own initial sync, without what start() does afterwards (status changes,
	-- place-id writes and the live WebSocket) - this sync is meant to end here.
	local ok, err = session:__initialSync(serverInfo):await()
	if ok then
		result.ok = true
		result.owned = stampOwner(session.__instanceMap, owner)
	elseif result.error == nil then
		result.error = tostring(err)
	end
	session:stop()

	post(replyPort, "/result", result)
	print(`[studio-sync] {serverInfo.projectName}: {if result.ok then "synced" else result.error}`)
end

-- The request is read from /api/rojo directly rather than through ApiContext:connect(),
-- which rejects a server on another protocol or one whose servePlaceIds exclude this
-- place without saying which project it was - the CLI would only see a timeout. Here the
-- request is claimed first and connect()'s refusal is reported back as the result.
local function readRequest(url)
	local ok, info = Http.get(url .. "/api/rojo")
		:andThen(function(response)
			return response:msgpack()
		end)
		:await()
	if not ok or type(info) ~= "table" or type(info.projectName) ~= "string" then
		return nil
	end
	local owner, replyPort = string.match(info.projectName, REQUEST_PATTERN)
	if owner ~= nil then
		return "sync", owner, tonumber(replyPort)
	end
	owner, replyPort = string.match(info.projectName, RELEASE_PATTERN)
	if owner ~= nil then
		return "release", owner, tonumber(replyPort)
	end
	return nil
end

-- Clears AgentOwner wherever it names `owner`; the instances themselves stay.
local function release(owner)
	local released = {}
	for _, instance in game:GetDescendants() do
		local ok, value = pcall(instance.GetAttribute, instance, OWNER_ATTRIBUTE)
		if ok and value == owner then
			instance:SetAttribute(OWNER_ATTRIBUTE, nil)
			table.insert(released, instance:GetFullName())
		end
	end
	table.sort(released)
	return released
end

local function poll()
	local url = `http://{HOST}:{PORT}`
	local kind, owner, replyPort = readRequest(url)
	if kind == nil then
		return
	end
	local claimed, response = post(replyPort, "/claim", { place = game.Name })
	if not (claimed and response.Success) then
		return
	end

	if kind == "release" then
		local ok, released = pcall(release, owner)
		post(replyPort, "/result", if ok
			then { ok = true, owner = owner, place = game.Name, released = released }
			else { ok = false, owner = owner, error = tostring(released) })
		print(`[studio-sync] released {if ok then #released else 0} instance(s) owned by {owner}`)
		return
	end

	local apiContext = ApiContext.new(url)
	local connected, serverInfo = apiContext:connect():await()
	if not connected then
		post(replyPort, "/result", { ok = false, owner = owner, error = tostring(serverInfo) })
	else
		local success, err = pcall(syncOnce, apiContext, serverInfo, owner, replyPort)
		if not success then
			post(replyPort, "/result", { ok = false, owner = owner, error = tostring(err) })
		end
	end
	apiContext:disconnect()
end

local running = true
plugin.Unloading:Connect(function()
	running = false
end)

task.spawn(function()
	while running do
		poll()
		task.wait(POLL_SECONDS)
	end
end)
