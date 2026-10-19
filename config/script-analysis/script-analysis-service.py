#!/usr/bin/env python3
"""Serves what Roblox Studio's Script Analysis window lists, on loopback.

Studio keeps Script Analysis to itself: no plugin or MCP API reads it. script-analysis.exe
reads it through Qt's UI Automation provider from inside a Studio's Wine desktop (its own
header comment has how); this runs it in every Studio desktop that is up, on request.

Caddy (config/mcp/Caddyfile) puts this behind the MCP bridge's bearer token at
/script-analysis; code-docker reads it with config/script-analysis/studio-analysis.

GET /read[?place=NAME]
            {"studios": [{"window", "status", "rows", "summary", "notes"}]}, one per Studio
            main window, or only those whose title contains NAME - the others aren't
            touched. "status" is shown, side-tab or dock-tab (the window was hidden there,
            shown for the read and hidden again) or closed. A desktop the reader didn't
            answer for has "error" instead.
"""
import json
import os
import re
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("SCRIPT_ANALYSIS_PORT", "8810"))
READER = r"Z:\usr\local\lib\roblox-studio\script-analysis.exe"
PREFIX = os.path.expanduser("~/.local/share/vinegar/prefixes/studio")
# Paging through a long list takes about a second per screenful.
TIMEOUT = 120

# One read at a time: a read clicks tabs and scrolls the tree, and two at once would fight.
reading = threading.Lock()


def studio_wine():
    """The Wine Vinegar runs Studio with (studio-wine.sh's studio_wine_bin)."""
    result = subprocess.run(["bash", "-c", ". /etc/roblox-studio/studio-wine.sh && studio_wine_bin"],
                            capture_output=True, text=True)
    return result.stdout.strip() or None


def studio_desktops():
    """(desktop name, DISPLAY) for every Studio that is up.

    Vinegar launches each Studio as `explorer /desktop=<uuid>,WxH` (desktop-resize-service.sh
    relies on the same shape); our own launches have no size and don't match."""
    result = subprocess.run(["pgrep", "-f", r"explorer\.exe /desktop=[^,]+,"], capture_output=True, text=True)
    desktops = []
    for pid in result.stdout.split():
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmdline = f.read().replace(b"\0", b" ").decode(errors="replace")
            with open(f"/proc/{pid}/environ", "rb") as f:
                environ = dict(entry.split("=", 1) for entry in f.read().decode(errors="replace").split("\0") if "=" in entry)
        except OSError:
            continue
        match = re.search(r"/desktop=([^, ]+),", cmdline)
        if match and environ.get("DISPLAY"):
            desktops.append((match.group(1), environ["DISPLAY"]))
    return desktops


def read_desktop(wine, desktop, display, place):
    out = f"/tmp/script-analysis-{desktop}.txt"
    try:
        os.unlink(out)
    except FileNotFoundError:
        pass
    env = dict(os.environ, DISPLAY=display, WINEPREFIX=PREFIX, WINEDEBUG="-all")
    # The launcher returns before the reader finishes and drops its exit status; the reader
    # ends its file with "!done" instead.
    subprocess.run([wine, "explorer", f"/desktop={desktop}", READER, "Z:" + out.replace("/", "\\")]
                   + ([place] if place else []),
                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        try:
            with open(out, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except FileNotFoundError:
            text = ""
        if text.endswith("!done\n"):
            break
        time.sleep(0.2)
    else:
        return [{"desktop": desktop, "error": f"the reader didn't finish within {TIMEOUT}s"}]

    # A block per Studio main window, each starting with its window line.
    studios, studio = [], None
    for line in text.splitlines():
        key, _, value = line.partition("\t")
        if key == "!done":
            continue
        if key == "window" or studio is None:
            studio = {"window": "", "status": "", "rows": [], "summary": [], "notes": []}
            studios.append(studio)
        if key in ("window", "status"):
            studio[key] = value
        elif key == "row":
            studio["rows"].append(value)
        elif key in ("summary", "note"):
            studio["summary" if key == "summary" else "notes"].append(value)
    return studios


def read_all(place):
    wine = studio_wine()
    if not wine:
        return {"studios": [], "error": "no Wine found to run the reader with"}
    with reading:
        return {"studios": [studio for desktop, display in studio_desktops()
                            for studio in read_desktop(wine, desktop, display, place)]}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path != "/read":
            self.send_error(404)
            return
        place = urllib.parse.parse_qs(url.query).get("place", [""])[0]
        body = json.dumps(read_all(place)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
