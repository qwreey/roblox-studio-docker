# Read-only observer for Studio's desktop size (CLAUDE.md's "Panels: Wine virtual
# desktop"). Prints, on one clock (UTC):
#   - each VNC connection to wayvnc and every desktop size it asks for (sniffed, nothing sent)
#   - desktop-resize's log lines
#   - the X size of every Wine desktop and of what is mapped in it, whenever that changes
#   - whatever you type + Enter, as a marker ("alt-tab to code", ...)
# Stops on Ctrl+C or after 20 minutes. Needs only what the image has (python3, root):
#   docker cp research/vnc-watch.py roblox-studio:/tmp/ &&
#   docker exec -it roblox-studio python3 -u /tmp/vnc-watch.py
# A connection already open when it starts shows as ip:port rather than viewerN.
import os, signal, socket, struct, subprocess, sys, threading, time

def say(msg):
    t = time.time()
    print(time.strftime("%H:%M:%S", time.gmtime(t)) + f".{int(t * 1000) % 1000:03d} {msg}", flush=True)

tails = []
def follow(path, tag):
    p = subprocess.Popen(["tail", "-n0", "-F", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    tails.append(p)
    for line in p.stdout:
        say(f"[{tag}] {line.rstrip()}")

def markers():
    for line in sys.stdin:
        say(f"----- {line.strip()}")

# --- X: Wine desktops and what is mapped in them -------------------------------------
class X:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect("/tmp/.X11-unix/X0")
        self.s.sendall(struct.pack("<BxHHHHxx", 0x6C, 11, 0, 0, 0))
        head = self.read(8)
        data = self.read(struct.unpack("<H", head[6:8])[0] * 4)
        vlen, nformats = struct.unpack("<H", data[16:18])[0], data[21]
        self.root = struct.unpack("<I", data[32 + (vlen + 3) // 4 * 4 + 8 * nformats:][:4])[0]
    def read(self, n):
        b = b""
        while len(b) < n:
            c = self.s.recv(n - len(b))
            if not c: raise EOFError
            b += c
        return b
    def req(self, op, body):
        self.s.sendall(struct.pack("<BBH", op, 0, 1 + len(body) // 4) + body)
        while True:
            r = self.read(32)
            if r[0] == 0: return None
            if r[0] == 1: return r + self.read(struct.unpack("<I", r[4:8])[0] * 4)
    def children(self, w):
        r = self.req(15, struct.pack("<I", w))
        n = struct.unpack("<H", r[16:18])[0] if r else 0
        return struct.unpack(f"<{n}I", r[32:32 + 4 * n]) if r else ()
    def geometry(self, w):
        r = self.req(14, struct.pack("<I", w))
        return "%dx%d%+d%+d" % (struct.unpack("<HHhh", r[16:20] + r[12:16])) if r else "?"
    def mapped(self, w):
        r = self.req(3, struct.pack("<I", w))
        return bool(r) and r[26] == 2
    def name(self, w):
        r = self.req(20, struct.pack("<IIIII", w, 39, 0, 0, 256))
        return r[32:32 + struct.unpack("<I", r[16:20])[0]].decode("utf-8", "replace") if r else ""
    def snapshot(self):
        parts = ["screen " + self.geometry(self.root).split("+")[0]]
        for top in self.children(self.root):
            nm = self.name(top)
            if "Wine Desktop" not in nm or not self.mapped(top): continue
            inner = [f"{self.name(c)[:24] or '-'} {self.geometry(c)}" for c in self.children(top)
                     if self.mapped(c) and self.geometry(c) != "1x1+0+0"]
            parts.append(f"{nm[:8]} {self.geometry(top)} [{', '.join(inner)}]")
        return " | ".join(parts)

def watch_x():
    last = None
    while True:
        try:
            snap = X().snapshot()
        except Exception as e:
            snap = f"X unreadable: {e}"
        if snap != last:
            say(f"[X] {snap}")
            last = snap
        time.sleep(0.5)

# --- VNC: who asks for which size -----------------------------------------------------
def msg_len(b):
    t = b[0]
    if t == 0: return 20
    if t == 2: return 4 + 4 * struct.unpack("!H", b[2:4])[0] if len(b) >= 4 else None
    if t == 3: return 10
    if t == 4: return 8
    if t == 5: return 6
    if t == 6: return 8 + struct.unpack("!I", b[4:8])[0] if len(b) >= 8 else None
    if t == 150: return 10
    if t == 248: return 9 + b[8] if len(b) >= 9 else None
    if t == 251: return 8 + 16 * b[6] if len(b) >= 7 else None
    return None

def watch_vnc(port):
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
    names, next_id = {}, 1
    while True:
        pkt, addr = s.recvfrom(65535)
        if addr[2] == socket.PACKET_OUTGOING or struct.unpack("!H", pkt[12:14])[0] != 0x0800: continue
        ip = pkt[14:]
        if ip[9] != 6: continue
        tcp = ip[(ip[0] & 15) * 4:struct.unpack("!H", ip[2:4])[0]]
        sport, dport = struct.unpack("!HH", tcp[:4])
        if dport != port: continue
        key = (socket.inet_ntoa(ip[12:16]), sport)
        flags, payload = tcp[13], tcp[(tcp[12] >> 4) * 4:]
        if flags & 0x02 and not flags & 0x10:
            names[key] = f"viewer{next_id}"; next_id += 1
            say(f"[vnc] {names[key]} connected ({key[0]}:{key[1]})")
            continue
        name = names.setdefault(key, f"{key[0]}:{key[1]}")
        if flags & 0x05:
            say(f"[vnc] {name} closed"); continue
        i = 0
        while i < len(payload):
            n = msg_len(payload[i:])
            if n is None or i + n > len(payload): break
            if payload[i] == 251:
                say(f"[vnc] {name} asks for %dx%d" % struct.unpack("!HH", payload[i + 2:i + 6]))
            i += n

def stop(*_):
    for p in tails:
        p.kill()
    os._exit(0)
signal.signal(signal.SIGALRM, stop)
signal.alarm(20 * 60)
for path, tag in (("/var/log/desktop-resize/stdout.log", "resize"), ("/var/log/desktop-resize/stderr.log", "resize")):
    threading.Thread(target=follow, args=(path, tag), daemon=True).start()
threading.Thread(target=watch_x, daemon=True).start()
threading.Thread(target=markers, daemon=True).start()
say("watching (type a note + Enter to mark a moment; Ctrl+C to stop)")
try:
    watch_vnc(int(os.environ.get("VNC_PORT", "5900")))
except KeyboardInterrupt:
    stop()
