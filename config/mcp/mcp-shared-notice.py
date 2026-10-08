#!/usr/bin/env python3
"""Runs Studio's MCP server and tells every client what this setup adds to it.

Several agents can be connected to one Studio through the bridge at once, and nothing in
Studio's own MCP says so. MCP's initialize response has an `instructions` field that
clients put in front of the model (Claude Code adds it to the system prompt), so this
appends mcp-shared-notice.md there - after Studio's own instructions, if it sends any.

The notice also says how a Rojo project gets into Studio (`studio-sync`, run in
code-docker), but an agent working out how to sync looks through its tools, not back
through its system prompt - one told "it's in the instructions" still answered that it
knew nothing about Rojo. So the tool list gets one more entry, ROJO_TOOL, whose
description says it and whose result is rojo-sync-guide.md. This script answers calls to
it itself; Studio never sees them.

Every other message passes through byte for byte.

Usage: mcp-shared-notice.py <command> [args...]   (stderr goes to the command)
"""
import json
import signal
import subprocess
import sys
import threading

NOTICE_FILE = "/etc/mcp-bridge/mcp-shared-notice.md"
ROJO_GUIDE_FILE = "/etc/mcp-bridge/rojo-sync-guide.md"

ROJO_TOOL = {
    "name": "rojo_sync_guide",
    "title": "How to sync a Rojo project into Studio",
    "description": (
        "Rojo projects (default.project.json, *.project.json) go into this Studio with "
        "`studio-sync`, run in the project directory from a shell in code-docker - not by "
        "recreating their files through MCP tools. Call this for the commands, ownership "
        "rules and how to check the result. Needs no studio_id."
    ),
    "inputSchema": {"type": "object", "properties": {}},
    "annotations": {"readOnlyHint": True, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False},
}

out_lock = threading.Lock()


def write_out(data: bytes) -> None:
    with out_lock:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()


def encode(message: dict) -> bytes:
    return json.dumps(message, ensure_ascii=False).encode() + b"\n"


def from_server(line: bytes, notice: str, rojo_guide: str) -> bytes:
    try:
        message = json.loads(line)
    except ValueError:
        return line
    result = message.get("result") if isinstance(message, dict) else None
    if not isinstance(result, dict):
        return line
    # Only the initialize response carries both of these.
    if notice and "protocolVersion" in result and "serverInfo" in result:
        existing = result.get("instructions")
        result["instructions"] = f"{existing}\n\n{notice}" if existing else notice
        return encode(message)
    # A tools/list response; on the last page if it is paginated.
    if rojo_guide and isinstance(result.get("tools"), list) and not result.get("nextCursor"):
        result["tools"].append(ROJO_TOOL)
        return encode(message)
    return line


def answer_rojo_call(line: bytes, rojo_guide: str) -> bool:
    """Answers a tools/call for ROJO_TOOL. False for anything else, to forward it."""
    try:
        message = json.loads(line)
    except ValueError:
        return False
    if not isinstance(message, dict) or message.get("method") != "tools/call" or "id" not in message:
        return False
    params = message.get("params")
    if not isinstance(params, dict) or params.get("name") != ROJO_TOOL["name"]:
        return False
    # resultType is required from servers on protocol revision 2026-07-28, which
    # StudioMCP.exe can negotiate (Claude Code rejected the result without it); clients
    # on earlier revisions ignore it.
    write_out(encode({
        "jsonrpc": "2.0",
        "id": message["id"],
        "result": {"content": [{"type": "text", "text": rojo_guide}], "isError": False, "resultType": "complete"},
    }))
    return True


def read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError as error:
        # Advice, not a gate - run the server without it.
        print(f"[mcp-shared-notice] {error}; leaving that part out", file=sys.stderr)
        return ""


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: mcp-shared-notice.py <command> [args...]", file=sys.stderr)
        return 2
    notice = read_text(NOTICE_FILE)
    rojo_guide = read_text(ROJO_GUIDE_FILE)

    child = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda signum, _frame: child.send_signal(signum))

    def client_to_server() -> None:
        try:
            for line in sys.stdin.buffer:
                if rojo_guide and answer_rojo_call(line, rojo_guide):
                    continue
                child.stdin.write(line)
                child.stdin.flush()
        except (BrokenPipeError, ValueError):
            pass
        finally:
            # EOF from the client ends the server, as it would have without this script.
            try:
                child.stdin.close()
            except OSError:
                pass

    threading.Thread(target=client_to_server, daemon=True).start()

    for line in child.stdout:
        write_out(from_server(line, notice, rojo_guide))
    return child.wait()


if __name__ == "__main__":
    sys.exit(main())
