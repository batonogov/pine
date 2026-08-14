#!/usr/bin/python3
"""Deterministic local LSP fixture for lifecycle soak coverage."""

import json
import os
import sys


def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line == b"\r\n":
            break
        name, value = line.decode("ascii").split(":", 1)
        headers[name.lower()] = value.strip()

    length = int(headers["content-length"])
    payload = sys.stdin.buffer.read(length)
    if len(payload) != length:
        return None
    return json.loads(payload)


def write_message(payload):
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(
        f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
    )
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "graceful"
    initialized = False
    while True:
        message = read_message()
        if message is None:
            return 0

        method = message.get("method")
        if method == "initialize":
            write_message({
                "jsonrpc": "2.0",
                "id": message["id"],
                "result": {"capabilities": {}},
            })
        elif method == "initialized":
            initialized = True
            if mode == "crash":
                os._exit(17)
        elif method == "shutdown":
            write_message({
                "jsonrpc": "2.0",
                "id": message["id"],
                "result": None,
            })
        elif method == "exit":
            return 0
        elif initialized and "id" in message:
            write_message({
                "jsonrpc": "2.0",
                "id": message["id"],
                "result": None,
            })


if __name__ == "__main__":
    raise SystemExit(main())
