#!/usr/bin/env python3
"""Serves Roblox Studio's script output (print, warn, error) on loopback.

Studio writes everything its Output window shows into its log file, as
`[FLog::CreatorOutput]`, `[FLog::CreatorWarning]` and `[FLog::CreatorError]` lines - in
edit mode, from plugins, and from a playtest's server and client alike. This follows
every Studio log (each Studio process writes its own; a short-lived helper process can
start after the main one) and keeps only those lines. The rest of the log never leaves
this process: it is Studio's whole diagnostic stream, network traces included.

Caddy (config/mcp/Caddyfile) puts this behind the MCP bridge's bearer token at
/studio-output; code-docker reads it with config/studio-output/studio-output.

GET /lines?since=<seq>&wait=<seconds>   lines after <seq>, waiting up to <seconds> for one
GET /lines?tail=<n>                     the last <n> lines
Both answer {"lines": [{"seq", "time", "level", "text"}], "next": <seq>, "gap": <bool>};
"gap" means lines between <seq> and the oldest kept one were dropped.
"""
import collections
import glob
import json
import os
import re
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_DIR = os.environ.get("STUDIO_LOG_DIR", "/root/.local/share/vinegar/appdata/Roblox/logs")
PORT = int(os.environ.get("STUDIO_OUTPUT_PORT", "8809"))
KEEP = 5000

# 2026-10-06T10:31:51.290Z,108.290421,01a8,6,Info [FLog::CreatorOutput] edited 4
OUTPUT = re.compile(r"^(\d{4}-\d\d-\d\dT[\d:.]+Z),\S* \[FLog::Creator(Output|Warning|Error)\] (.*)$")
# Any log line starts like this; a line that doesn't is the rest of a multi-line message.
LOG_LINE = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z,")
LEVELS = {"Output": "info", "Warning": "warning", "Error": "error"}
# Studio's own prefixes for the level, which the Output window shows as colour instead.
PREFIXES = {"info": "Info: ", "warning": "Warning: ", "error": "Error: "}

lines = collections.deque(maxlen=KEEP)
next_seq = 1
changed = threading.Condition()


def add(time_, level, text):
    global next_seq
    with changed:
        lines.append({"seq": next_seq, "time": time_, "level": level, "text": text})
        next_seq += 1
        changed.notify_all()


class LogFile:
    def __init__(self, path, offset):
        self.path = path
        self.offset = offset
        self.partial = b""
        self.last_was_output = False

    def read_new(self):
        try:
            with open(self.path, "rb") as f:
                f.seek(self.offset)
                data = f.read()
        except OSError:
            return
        self.offset += len(data)
        *complete, self.partial = (self.partial + data).split(b"\n")
        for raw in complete:
            line = raw.decode("utf-8", "replace").rstrip("\r")
            match = OUTPUT.match(line)
            if match:
                level = LEVELS[match.group(2)]
                text = match.group(3)
                if text.startswith(PREFIXES[level]):
                    text = text[len(PREFIXES[level]):]
                add(match.group(1), level, text)
                self.last_was_output = True
            elif LOG_LINE.match(line):
                self.last_was_output = False
            elif self.last_was_output:
                add(lines[-1]["time"], lines[-1]["level"], line)


def follow():
    files = {}
    paths = sorted(glob.glob(os.path.join(LOG_DIR, "*.log")), key=os.path.getmtime)
    # History comes from the newest log only; older ones are earlier Studio sessions.
    for path in paths:
        files[path] = LogFile(path, 0 if path == paths[-1] else os.path.getsize(path))
    while True:
        for path in glob.glob(os.path.join(LOG_DIR, "*.log")):
            if path not in files:
                files[path] = LogFile(path, 0)
        for log in list(files.values()):
            log.read_new()
            if not os.path.exists(log.path):
                del files[log.path]
        time.sleep(0.5)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path != "/lines":
            self.send_error(404)
            return
        query = urllib.parse.parse_qs(url.query)
        try:
            tail = int(query["tail"][0]) if "tail" in query else None
            since = int(query.get("since", ["0"])[0])
            wait = min(float(query.get("wait", ["0"])[0]), 30.0)
        except ValueError:
            self.send_error(400)
            return

        with changed:
            if tail is None and wait > 0 and not (lines and lines[-1]["seq"] > since):
                changed.wait(wait)
            if tail is not None:
                picked = list(lines)[-tail:] if tail > 0 else []
                gap = False
            else:
                picked = [line for line in lines if line["seq"] > since]
                gap = bool(lines) and since < lines[0]["seq"] - 1
            body = json.dumps({"lines": picked, "next": next_seq - 1, "gap": gap}).encode()

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    while not os.path.isdir(LOG_DIR):
        # Created by Studio's first launch on a fresh install.
        time.sleep(10)
    threading.Thread(target=follow, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
