This Roblox Studio is shared: several agents may be connected to it at the same time, each working on its own part of the open place.

- Before changing or deleting an instance, check it and its ancestors for an `AgentOwner` attribute (`inspect_instance` lists attributes). If it names another agent, leave it and everything under it alone, scripts included.
- Put your own work under a root you create (a Folder, for example) and set its `AgentOwner` attribute to a name that identifies you, such as your git worktree or branch name. Instances without `AgentOwner` are shared; change them only when your task needs it.
- Play mode is shared too. Check `get_studio_state` before `start_stop_play`, don't stop a playtest you didn't start, and expect `get_console_output` to include other agents' output.
