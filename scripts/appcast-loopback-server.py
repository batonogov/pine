#!/usr/bin/env python3
"""
Serve a release-smoke update feed over loopback and publish the bound port.

Why this is not `python3 -m http.server`
----------------------------------------
`http.server.HTTPServer.server_bind()` finishes with
`self.server_name = socket.getfqdn(host)` — a reverse DNS lookup performed
inside the constructor, before the caller can read `server_address`. On a
GitHub Actions macOS runner that lookup can stall for tens of seconds, so the
release gate's `Pine-<version>.dmg` feed server never published its port and
the whole `Release` workflow failed closed with a bare "local appcast server
did not publish its port" (Pine #1465 — v2.3.3 shipped with no DMG asset and
no Homebrew tap update because of it).

`LoopbackFeedServer` binds through `socketserver.TCPServer.server_bind()` and
names itself `127.0.0.1` literally, so no resolver is ever consulted: not at
bind time, and not per request (`SimpleHTTPRequestHandler.address_string()`
returns the raw client address). The port is written atomically — staged in a
sibling file and `os.replace()`d into place — so a reader that polls with
`test -s` can never observe a half-written port.

Usage
-----
    appcast-loopback-server.py <feed-root> <port-file>

The server runs until it is killed. `<port-file>` must not already exist: a
stale file from an earlier run would let the caller connect to a server that
is no longer serving the bytes under test.
"""

from __future__ import annotations

import http.server
import os
import socketserver
import sys
from pathlib import Path

EXIT_USAGE = 64
EXIT_STALE_PORT_FILE = 65
EXIT_BAD_FEED_ROOT = 66


class LoopbackFeedServer(http.server.ThreadingHTTPServer):
    """A threading HTTP server that never performs name resolution."""

    daemon_threads = True

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


def publish_port(port_file: Path, port: int) -> None:
    """Write `port` so that no reader can observe a partial value."""
    staging = port_file.with_name(f"{port_file.name}.partial")
    staging.write_text(f"{port}\n", encoding="utf-8")
    os.replace(staging, port_file)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write(
            "usage: appcast-loopback-server.py <feed-root> <port-file>\n"
        )
        return EXIT_USAGE

    root = Path(argv[1])
    port_file = Path(argv[2])

    if not root.is_dir():
        sys.stderr.write(f"feed root is not a directory: {root}\n")
        return EXIT_BAD_FEED_ROOT
    if port_file.exists():
        sys.stderr.write(f"port file already exists: {port_file}\n")
        return EXIT_STALE_PORT_FILE

    def build_handler(*args: object, **kwargs: object):
        return http.server.SimpleHTTPRequestHandler(
            *args, directory=str(root), **kwargs
        )

    with LoopbackFeedServer(("127.0.0.1", 0), build_handler) as server:
        port = server.server_address[1]
        publish_port(port_file, port)
        sys.stderr.write(f"serving {root} on 127.0.0.1:{port}\n")
        sys.stderr.flush()
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
