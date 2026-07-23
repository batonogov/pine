#!/usr/bin/env python3
"""Reproduce Pine's LSP versus Tree-sitter structural prototype.

The Tree-sitter package is tooling-only and pins every dependency in
tree-sitter-probe/Package.resolved. Nothing here is linked into Pine.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIRECTORY.parent.parent
FIXTURE_DIRECTORY = SCRIPT_DIRECTORY / "fixtures"
TREE_SITTER_PACKAGE = SCRIPT_DIRECTORY / "tree-sitter-probe"
BASELINE_RESULT = (
    SCRIPT_DIRECTORY / "results" / "2026-07-23-xcode-27-beta.json"
)

PINNED_REVISIONS = {
    "swift-tree-sitter": "0f40435cdb41673ce4194d731571cf2a2f7c3285",
    "tree-sitter": "da6fe9beb4f7f67beb75914ca8e0d48ae48d6406",
    "tree-sitter-swift": "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5",
}

FIXTURE_DIGESTS = {
    "malformed.swift": "5436d2627864fd92e685780372937251326b49209fbbcb70b2908ee985bb1fcc",
    "valid.swift": "fb3ab0c1cae05e2cc9e48fc0f14cd4f11ac9faee25fe4e2f4fda05383d16fb6e",
}

LARGE_FIXTURE_DECLARATIONS = 2_000
LARGE_FIXTURE_DIGEST = "6f01e70990c9c799a4bb3c50d67297a4dbc65fa8539100805df81a13a013947a"
DEFAULT_TIMEOUT_SECONDS = 30.0
REPRESENTATIVE_UNICODE_SYMBOL = "类型🌲"


class PrototypeError(RuntimeError):
    """A reproducibility or provider failure."""


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def generate_large_fixture(declarations: int = LARGE_FIXTURE_DECLARATIONS) -> str:
    """Create a deterministic, nested Swift buffer above Pine's 50K threshold."""
    sections = [
        "import Foundation\n\n",
        "enum GeneratedNamespace {\n",
    ]
    for index in range(declarations):
        sections.append(
            f"""    struct Model{index:04d} {{
        let label = "tree 🌲 {index:04d}"

        enum State {{
            case ready
            case waiting
        }}

        func transform(value: String) -> String {{
            if value.isEmpty {{
                return label
            }}
            return "\\(label): \\(value)"
        }}
    }}

"""
        )
    sections.append("}\n")
    return "".join(sections)


def validate_inputs() -> dict[str, Any]:
    errors: list[str] = []
    fixture_details: dict[str, Any] = {}
    for name, expected_digest in sorted(FIXTURE_DIGESTS.items()):
        path = FIXTURE_DIRECTORY / name
        if not path.is_file():
            errors.append(f"missing fixture: {path}")
            continue
        content = path.read_bytes()
        actual_digest = sha256_bytes(content)
        if actual_digest != expected_digest:
            errors.append(
                f"{name} digest changed: expected {expected_digest}, got {actual_digest}"
            )
        fixture_details[name] = {
            "sha256": actual_digest,
            "utf8_bytes": len(content),
        }

    resolved_path = TREE_SITTER_PACKAGE / "Package.resolved"
    if not resolved_path.is_file():
        errors.append(f"missing lockfile: {resolved_path}")
    else:
        resolved = json.loads(resolved_path.read_text(encoding="utf-8"))
        actual_pins = {
            pin["identity"]: pin["state"]["revision"] for pin in resolved["pins"]
        }
        if actual_pins != PINNED_REVISIONS:
            errors.append(
                "Package.resolved pins differ from the reviewed revisions: "
                f"{actual_pins}"
            )

    manifest_path = TREE_SITTER_PACKAGE / "Package.swift"
    if not manifest_path.is_file():
        errors.append(f"missing package manifest: {manifest_path}")
    else:
        manifest = manifest_path.read_text(encoding="utf-8")
        for identity in ("swift-tree-sitter", "tree-sitter-swift"):
            revision = PINNED_REVISIONS[identity]
            if revision not in manifest:
                errors.append(
                    f"Package.swift does not pin {identity} at {revision}"
                )

    large_content = generate_large_fixture().encode("utf-8")
    large_digest = sha256_bytes(large_content)
    if LARGE_FIXTURE_DIGEST != "TO_BE_FILLED" and large_digest != LARGE_FIXTURE_DIGEST:
        errors.append(
            "generated large fixture digest changed: "
            f"expected {LARGE_FIXTURE_DIGEST}, got {large_digest}"
        )
    fixture_details["large.generated.swift"] = {
        "sha256": large_digest,
        "utf8_bytes": len(large_content),
        "declarations": LARGE_FIXTURE_DECLARATIONS,
    }

    if not BASELINE_RESULT.is_file():
        errors.append(f"missing baseline result: {BASELINE_RESULT}")
    else:
        baseline = json.loads(BASELINE_RESULT.read_text(encoding="utf-8"))
        if baseline.get("fixtures") != fixture_details:
            errors.append("baseline fixture identities do not match current inputs")
        tree_sitter = baseline.get("tree_sitter", {})
        if "fresh_scratch_resolution_and_release_build_milliseconds" not in tree_sitter:
            errors.append("baseline is missing the fresh-scratch build measurement")
        try:
            validate_baseline_range_evidence(baseline)
        except PrototypeError as error:
            errors.append(f"baseline LSP range evidence is invalid: {error}")

    try:
        validate_lsp_validator_contract()
    except PrototypeError as error:
        errors.append(f"LSP range validator self-check failed: {error}")

    if errors:
        raise PrototypeError("\n".join(errors))
    return fixture_details


def command_output(
    command: list[str],
    *,
    environment: dict[str, str] | None = None,
) -> str:
    result = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
        env=environment,
    )
    return result.stdout.strip()


def developer_environment() -> tuple[dict[str, str], str | None]:
    environment = os.environ.copy()
    if environment.get("DEVELOPER_DIR"):
        return environment, environment["DEVELOPER_DIR"]

    for application in ("Xcode.app", "Xcode-beta.app"):
        developer_directory = Path("/Applications") / application / "Contents/Developer"
        if developer_directory.is_dir():
            environment["DEVELOPER_DIR"] = str(developer_directory)
            return environment, str(developer_directory)

    return environment, None


def resolve_sourcekit_lsp(
    explicit_path: str | None,
    environment: dict[str, str],
) -> Path:
    if explicit_path:
        path = Path(explicit_path).expanduser().resolve()
        if not path.is_file():
            raise PrototypeError(f"sourcekit-lsp does not exist: {path}")
        return path

    try:
        discovered = command_output(
            ["xcrun", "--find", "sourcekit-lsp"],
            environment=environment,
        )
        return Path(discovered).resolve()
    except (OSError, subprocess.CalledProcessError):
        direct = shutil.which("sourcekit-lsp", path=environment.get("PATH"))
        if direct:
            return Path(direct).resolve()
        raise PrototypeError(
            "sourcekit-lsp was not found; pass --sourcekit-lsp or set DEVELOPER_DIR"
        )


class JSONRPCProcess:
    """Minimal synchronous JSON-RPC/LSP process with bounded reads."""

    def __init__(
        self,
        executable: Path,
        environment: dict[str, str],
        timeout_seconds: float,
    ) -> None:
        self.process = subprocess.Popen(
            [str(executable)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=environment,
        )
        if self.process.stdin is None or self.process.stdout is None:
            raise PrototypeError("unable to create sourcekit-lsp pipes")
        self.stdin = self.process.stdin
        self.stdout = self.process.stdout
        self.timeout_seconds = timeout_seconds
        self.buffer = bytearray()
        self.next_identifier = 0

    def send(self, message: dict[str, Any]) -> None:
        payload = json.dumps(
            message,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
        frame = f"Content-Length: {len(payload)}\r\n\r\n".encode("ascii") + payload
        self.stdin.write(frame)
        self.stdin.flush()

    def notify(self, method: str, parameters: dict[str, Any]) -> None:
        self.send(
            {
                "jsonrpc": "2.0",
                "method": method,
                "params": parameters,
            }
        )

    def begin_request(self, method: str, parameters: dict[str, Any]) -> int:
        self.next_identifier += 1
        identifier = self.next_identifier
        self.send(
            {
                "jsonrpc": "2.0",
                "id": identifier,
                "method": method,
                "params": parameters,
            }
        )
        return identifier

    def request(
        self,
        method: str,
        parameters: dict[str, Any],
    ) -> tuple[Any, float]:
        start = time.perf_counter()
        identifier = self.begin_request(method, parameters)
        response = self.wait_for_response(identifier)
        elapsed_milliseconds = (time.perf_counter() - start) * 1_000
        if "error" in response:
            raise PrototypeError(
                f"{method} failed: {json.dumps(response['error'], sort_keys=True)}"
            )
        return response.get("result"), elapsed_milliseconds

    def read_message(self, timeout_seconds: float | None = None) -> dict[str, Any]:
        deadline = time.monotonic() + (timeout_seconds or self.timeout_seconds)
        delimiter = b"\r\n\r\n"

        while True:
            header_end = self.buffer.find(delimiter)
            if header_end >= 0:
                header = bytes(self.buffer[:header_end]).decode("ascii")
                content_length: int | None = None
                for line in header.split("\r\n"):
                    name, separator, value = line.partition(":")
                    if separator and name.lower() == "content-length":
                        content_length = int(value.strip())
                if content_length is None:
                    raise PrototypeError("sourcekit-lsp frame omitted Content-Length")
                payload_start = header_end + len(delimiter)
                payload_end = payload_start + content_length
                if len(self.buffer) >= payload_end:
                    payload = bytes(self.buffer[payload_start:payload_end])
                    del self.buffer[:payload_end]
                    return json.loads(payload)

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise PrototypeError("timed out waiting for sourcekit-lsp")
            readable, _, _ = select.select([self.stdout.fileno()], [], [], remaining)
            if not readable:
                raise PrototypeError("timed out waiting for sourcekit-lsp")
            chunk = os.read(self.stdout.fileno(), 64 * 1024)
            if not chunk:
                raise PrototypeError(
                    f"sourcekit-lsp exited with status {self.process.poll()}"
                )
            self.buffer.extend(chunk)

    def wait_for_response(
        self,
        identifier: int,
        timeout_seconds: float | None = None,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + (timeout_seconds or self.timeout_seconds)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise PrototypeError(
                    f"timed out waiting for sourcekit-lsp request {identifier}"
                )
            message = self.read_message(remaining)
            if message.get("id") == identifier and "method" not in message:
                return message
            if "id" in message and "method" in message:
                self.respond_to_server_request(message)

    def respond_to_server_request(self, message: dict[str, Any]) -> None:
        method = message.get("method")
        result: Any = None
        if method == "workspace/configuration":
            items = message.get("params", {}).get("items", [])
            result = [None for _ in items]
        elif method == "workspace/workspaceFolders":
            result = []
        self.send(
            {
                "jsonrpc": "2.0",
                "id": message["id"],
                "result": result,
            }
        )

    def close(self) -> None:
        try:
            if self.process.poll() is None:
                try:
                    self.request("shutdown", {})
                    self.notify("exit", {})
                except (BrokenPipeError, PrototypeError):
                    pass
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    self.process.wait(timeout=2)
        finally:
            if self.process.poll() is None:
                self.process.kill()
            self.stdin.close()
            self.stdout.close()


class LSPTextSnapshot:
    """Exact UTF-16 position boundaries for one immutable document snapshot."""

    def __init__(self, source: str) -> None:
        self.lines = re.split(r"\r\n|\r|\n", source)
        self.boundaries: list[set[int]] = []
        for line in self.lines:
            offsets = {0}
            offset = 0
            for character in line:
                offset += len(character.encode("utf-16-le")) // 2
                offsets.add(offset)
            self.boundaries.append(offsets)

    def position(
        self,
        value: Any,
        *,
        context: str,
    ) -> tuple[int, int]:
        if not isinstance(value, dict):
            raise PrototypeError(f"{context} is not an LSP Position object")
        line = value.get("line")
        character = value.get("character")
        if (
            not isinstance(line, int)
            or isinstance(line, bool)
            or not isinstance(character, int)
            or isinstance(character, bool)
            or line < 0
            or line >= len(self.lines)
            or character not in self.boundaries[line]
        ):
            raise PrototypeError(
                f"{context} is not a valid UTF-16 boundary: "
                f"{json.dumps(value, sort_keys=True)}"
            )
        return line, character

    def line_position(
        self,
        line: Any,
        character: Any | None,
        *,
        context: str,
        default_to_line_end: bool,
    ) -> tuple[int, int]:
        if (
            not isinstance(line, int)
            or isinstance(line, bool)
            or line < 0
            or line >= len(self.lines)
        ):
            raise PrototypeError(f"{context} has an invalid line: {line!r}")
        if character is None:
            resolved_character = (
                max(self.boundaries[line]) if default_to_line_end else 0
            )
        else:
            if (
                not isinstance(character, int)
                or isinstance(character, bool)
                or character not in self.boundaries[line]
            ):
                raise PrototypeError(
                    f"{context} is not a valid UTF-16 boundary: {character!r}"
                )
            resolved_character = character
        return line, resolved_character


def canonical_lsp_range(
    start: tuple[int, int],
    end: tuple[int, int],
) -> dict[str, dict[str, int]]:
    return {
        "start": {"line": start[0], "character": start[1]},
        "end": {"line": end[0], "character": end[1]},
    }


def canonical_json_sha256(value: Any) -> str:
    content = json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return sha256_bytes(content)


def validate_lsp_range(
    value: Any,
    snapshot: LSPTextSnapshot,
    *,
    context: str,
) -> tuple[tuple[int, int], tuple[int, int]]:
    if not isinstance(value, dict):
        raise PrototypeError(f"{context} is not an LSP Range object")
    start = snapshot.position(value.get("start"), context=f"{context}.start")
    end = snapshot.position(value.get("end"), context=f"{context}.end")
    if end < start:
        raise PrototypeError(f"{context} is reversed")
    return start, end


def range_contains(
    outer: tuple[tuple[int, int], tuple[int, int]],
    inner: tuple[tuple[int, int], tuple[int, int]],
) -> bool:
    return outer[0] <= inner[0] and inner[1] <= outer[1]


def negotiated_utf16_position_encoding(capabilities: Any) -> str:
    if not isinstance(capabilities, dict):
        raise PrototypeError(
            "sourcekit-lsp initialize result omitted a capabilities object"
        )
    if "positionEncoding" not in capabilities:
        return "utf-16"
    advertised = capabilities["positionEncoding"]
    if advertised != "utf-16":
        raise PrototypeError(
            "sourcekit-lsp selected unsupported position encoding "
            f"{advertised!r}; this prototype requires utf-16"
        )
    return advertised


def validate_folding_ranges(
    ranges: Any,
    source: str,
    *,
    context: str,
) -> dict[str, Any]:
    if not isinstance(ranges, list):
        raise PrototypeError(f"{context} did not return a FoldingRange array")
    snapshot = LSPTextSnapshot(source)
    canonical_ranges: list[dict[str, dict[str, int]]] = []
    for index, folding_range in enumerate(ranges):
        item_context = f"{context}[{index}]"
        if not isinstance(folding_range, dict):
            raise PrototypeError(f"{item_context} is not an object")
        start_character = folding_range.get("startCharacter")
        end_character = folding_range.get("endCharacter")
        if "startCharacter" in folding_range and start_character is None:
            raise PrototypeError(f"{item_context}.startCharacter is null")
        if "endCharacter" in folding_range and end_character is None:
            raise PrototypeError(f"{item_context}.endCharacter is null")
        start = snapshot.line_position(
            folding_range.get("startLine"),
            start_character,
            context=f"{item_context}.start",
            default_to_line_end=False,
        )
        end = snapshot.line_position(
            folding_range.get("endLine"),
            end_character,
            context=f"{item_context}.end",
            default_to_line_end=True,
        )
        if end < start:
            raise PrototypeError(f"{item_context} is reversed")
        canonical_ranges.append(canonical_lsp_range(start, end))
    return {
        "folding_ranges": len(ranges),
        "folding_ranges_sha256": canonical_json_sha256(canonical_ranges),
    }


def expected_unicode_selection_range(
    snapshot: LSPTextSnapshot,
) -> dict[str, dict[str, int]]:
    matches: list[tuple[int, int]] = []
    for line_index, line in enumerate(snapshot.lines):
        search_start = 0
        while True:
            character_index = line.find(REPRESENTATIVE_UNICODE_SYMBOL, search_start)
            if character_index < 0:
                break
            prefix = line[:character_index]
            start_character = len(prefix.encode("utf-16-le")) // 2
            matches.append((line_index, start_character))
            search_start = character_index + len(REPRESENTATIVE_UNICODE_SYMBOL)
    if len(matches) != 1:
        raise PrototypeError(
            "expected exactly one representative Unicode symbol in valid.swift, "
            f"found {len(matches)}"
        )
    line, start_character = matches[0]
    end_character = start_character + (
        len(REPRESENTATIVE_UNICODE_SYMBOL.encode("utf-16-le")) // 2
    )
    return canonical_lsp_range(
        (line, start_character),
        (line, end_character),
    )


def validate_document_symbols(
    symbols: Any,
    source: str,
    *,
    context: str,
    require_unicode_symbol: bool,
) -> dict[str, Any]:
    if not isinstance(symbols, list):
        raise PrototypeError(f"{context} did not return a DocumentSymbol array")
    snapshot = LSPTextSnapshot(source)
    expected_unicode = (
        expected_unicode_selection_range(snapshot) if require_unicode_symbol else None
    )
    symbol_count = 0
    selection_count = 0
    unicode_evidence: dict[str, Any] | None = None
    canonical_ranges: list[dict[str, Any]] = []

    def visit(
        items: list[Any],
        parent_range: tuple[tuple[int, int], tuple[int, int]] | None = None,
        parent_path: tuple[int, ...] = (),
    ) -> None:
        nonlocal symbol_count, selection_count, unicode_evidence
        for index, item in enumerate(items):
            path = (*parent_path, index)
            item_context = f"{context}[{'.'.join(str(part) for part in path)}]"
            if not isinstance(item, dict):
                raise PrototypeError(f"{item_context} is not an object")
            name = item.get("name")
            if not isinstance(name, str) or not name:
                raise PrototypeError(f"{item_context}.name is invalid")
            symbol_range = validate_lsp_range(
                item.get("range"),
                snapshot,
                context=f"{item_context}.range",
            )
            selection_range = validate_lsp_range(
                item.get("selectionRange"),
                snapshot,
                context=f"{item_context}.selectionRange",
            )
            if not range_contains(symbol_range, selection_range):
                raise PrototypeError(
                    f"{item_context}.selectionRange is outside its symbol range"
                )
            if parent_range is not None and not range_contains(
                parent_range,
                symbol_range,
            ):
                raise PrototypeError(
                    f"{item_context}.range is outside its parent symbol range"
                )

            symbol_count += 1
            selection_count += 1
            canonical_ranges.append(
                {
                    "path": list(path),
                    "range": canonical_lsp_range(*symbol_range),
                    "selection_range": canonical_lsp_range(*selection_range),
                }
            )
            if name == REPRESENTATIVE_UNICODE_SYMBOL:
                if unicode_evidence is not None:
                    raise PrototypeError(
                        "sourcekit-lsp returned the representative Unicode symbol twice"
                    )
                actual_selection = canonical_lsp_range(*selection_range)
                if actual_selection != expected_unicode:
                    raise PrototypeError(
                        "representative Unicode selectionRange was not the exact "
                        f"UTF-16 identifier range: expected {expected_unicode}, "
                        f"got {actual_selection}"
                    )
                unicode_evidence = {
                    "name": name,
                    "selection_range": actual_selection,
                    "utf8_bytes": len(name.encode("utf-8")),
                    "utf16_units": len(name.encode("utf-16-le")) // 2,
                }

            children = item.get("children")
            if children is not None:
                if not isinstance(children, list):
                    raise PrototypeError(f"{item_context}.children is not an array")
                visit(children, symbol_range, path)

    visit(symbols)
    if require_unicode_symbol and unicode_evidence is None:
        raise PrototypeError(
            "sourcekit-lsp omitted the representative Unicode document symbol"
        )

    result: dict[str, Any] = {
        "document_symbol_ranges": symbol_count,
        "document_symbol_selection_ranges": selection_count,
        "document_symbol_ranges_sha256": canonical_json_sha256(canonical_ranges),
    }
    if unicode_evidence is not None:
        result["representative_unicode_symbol"] = unicode_evidence
    return result


def validate_lsp_validator_contract() -> None:
    """Keep the offline CI path fail-closed for UTF-16 boundary regressions."""

    snapshot = LSPTextSnapshot("a🌲b\nchild")
    valid = validate_lsp_range(
        {
            "start": {"line": 0, "character": 1},
            "end": {"line": 0, "character": 3},
        },
        snapshot,
        context="self-check.valid",
    )
    if valid != ((0, 1), (0, 3)):
        raise PrototypeError("valid surrogate-pair range was not preserved")

    try:
        validate_lsp_range(
            {
                "start": {"line": 0, "character": 2},
                "end": {"line": 0, "character": 3},
            },
            snapshot,
            context="self-check.invalid-surrogate-boundary",
        )
    except PrototypeError:
        pass
    else:
        raise PrototypeError("position inside a surrogate pair was accepted")

    if not range_contains(((0, 0), (1, 5)), valid):
        raise PrototypeError("valid nested range was rejected")
    if range_contains(valid, ((0, 0), (1, 5))):
        raise PrototypeError("out-of-parent range was accepted")

    unicode_source = f"struct {REPRESENTATIVE_UNICODE_SYMBOL} {{\n}}\n"
    unicode_evidence = validate_document_symbols(
        [
            {
                "name": REPRESENTATIVE_UNICODE_SYMBOL,
                "range": {
                    "start": {"line": 0, "character": 0},
                    "end": {"line": 1, "character": 1},
                },
                "selectionRange": {
                    "start": {"line": 0, "character": 7},
                    "end": {"line": 0, "character": 11},
                },
            }
        ],
        unicode_source,
        context="self-check.documentSymbol",
        require_unicode_symbol=True,
    )
    representative = unicode_evidence.get("representative_unicode_symbol")
    if (
        not isinstance(representative, dict)
        or representative.get("selection_range")
        != canonical_lsp_range((0, 7), (0, 11))
    ):
        raise PrototypeError("exact Unicode selection evidence was not preserved")

    try:
        validate_document_symbols(
            [
                {
                    "name": "parent",
                    "range": {
                        "start": {"line": 0, "character": 0},
                        "end": {"line": 0, "character": 6},
                    },
                    "selectionRange": {
                        "start": {"line": 0, "character": 0},
                        "end": {"line": 0, "character": 6},
                    },
                    "children": [
                        {
                            "name": "child",
                            "range": {
                                "start": {"line": 1, "character": 0},
                                "end": {"line": 1, "character": 5},
                            },
                            "selectionRange": {
                                "start": {"line": 1, "character": 0},
                                "end": {"line": 1, "character": 5},
                            },
                        }
                    ],
                }
            ],
            "parent\nchild",
            context="self-check.out-of-parent",
            require_unicode_symbol=False,
        )
    except PrototypeError:
        pass
    else:
        raise PrototypeError("out-of-parent document symbol was accepted")

    if negotiated_utf16_position_encoding({}) != "utf-16":
        raise PrototypeError("the LSP UTF-16 default was not selected")
    for unsupported in ("utf-8", "utf-32", None):
        try:
            negotiated_utf16_position_encoding(
                {"positionEncoding": unsupported}
            )
        except PrototypeError:
            pass
        else:
            raise PrototypeError(
                f"unsupported position encoding {unsupported!r} was accepted"
            )


def validate_baseline_range_evidence(baseline: dict[str, Any]) -> None:
    lsp = baseline.get("lsp")
    if not isinstance(lsp, dict):
        raise PrototypeError("missing lsp result")
    capabilities = lsp.get("capabilities")
    if (
        not isinstance(capabilities, dict)
        or capabilities.get("position_encoding") != "utf-16"
    ):
        raise PrototypeError("negotiated position encoding is not utf-16")

    fixture_results = lsp.get("fixtures")
    if not isinstance(fixture_results, list):
        raise PrototypeError("missing fixture results")
    results_by_name = {
        result.get("name"): result
        for result in fixture_results
        if isinstance(result, dict) and isinstance(result.get("name"), str)
    }
    if (
        len(fixture_results) != 3
        or set(results_by_name) != {"valid", "malformed", "large"}
    ):
        raise PrototypeError("fixture result names are incomplete or duplicated")

    fixture_metadata = baseline.get("fixtures")
    if not isinstance(fixture_metadata, dict):
        raise PrototypeError("fixture identities are missing")
    metadata_names = {
        "valid": "valid.swift",
        "malformed": "malformed.swift",
        "large": "large.generated.swift",
    }
    for name, result in results_by_name.items():
        metadata = fixture_metadata.get(metadata_names[name])
        if (
            not isinstance(metadata, dict)
            or result.get("utf8_bytes") != metadata.get("utf8_bytes")
        ):
            raise PrototypeError(f"{name} result does not match its fixture identity")
        validation = result.get("range_validation")
        if (
            not isinstance(validation, dict)
            or validation.get("position_encoding") != "utf-16"
        ):
            raise PrototypeError(f"{name} omitted UTF-16 range validation")
        expected_counts = {
            "cold": (
                result.get("fold_count"),
                result.get("symbols", {}).get("count")
                if isinstance(result.get("symbols"), dict)
                else None,
            ),
            "incremental": (
                result.get("incremental_fold_count"),
                result.get("incremental_symbols", {}).get("count")
                if isinstance(result.get("incremental_symbols"), dict)
                else None,
            ),
        }
        for phase, (fold_count, symbol_count) in expected_counts.items():
            evidence = validation.get(phase)
            if not isinstance(evidence, dict):
                raise PrototypeError(f"{name}.{phase} evidence is missing")
            if evidence.get("folding_ranges") != fold_count:
                raise PrototypeError(f"{name}.{phase} folding count is inconsistent")
            if (
                evidence.get("document_symbol_ranges") != symbol_count
                or evidence.get("document_symbol_selection_ranges") != symbol_count
            ):
                raise PrototypeError(f"{name}.{phase} symbol counts are inconsistent")
            for digest_name in (
                "folding_ranges_sha256",
                "document_symbol_ranges_sha256",
            ):
                digest = evidence.get(digest_name)
                if (
                    not isinstance(digest, str)
                    or re.fullmatch(r"[0-9a-f]{64}", digest) is None
                ):
                    raise PrototypeError(
                        f"{name}.{phase}.{digest_name} is not a SHA-256 digest"
                    )

    valid_source = (FIXTURE_DIRECTORY / "valid.swift").read_text(encoding="utf-8")
    expected_selection = expected_unicode_selection_range(
        LSPTextSnapshot(valid_source)
    )
    for phase in ("cold", "incremental"):
        evidence = results_by_name["valid"]["range_validation"][phase].get(
            "representative_unicode_symbol"
        )
        if (
            not isinstance(evidence, dict)
            or evidence.get("name") != REPRESENTATIVE_UNICODE_SYMBOL
            or evidence.get("selection_range") != expected_selection
            or evidence.get("utf8_bytes")
            != len(REPRESENTATIVE_UNICODE_SYMBOL.encode("utf-8"))
            or evidence.get("utf16_units")
            != len(REPRESENTATIVE_UNICODE_SYMBOL.encode("utf-16-le")) // 2
        ):
            raise PrototypeError(
                f"valid.{phase} representative Unicode evidence is inconsistent"
            )


def symbol_metrics(symbols: Any) -> dict[str, Any]:
    if not isinstance(symbols, list):
        return {
            "count": 0,
            "maximum_depth": 0,
            "hierarchical": False,
        }

    count = 0
    maximum_depth = 0
    hierarchical = False

    def visit(items: list[Any], depth: int) -> None:
        nonlocal count, maximum_depth, hierarchical
        for item in items:
            if not isinstance(item, dict):
                continue
            count += 1
            maximum_depth = max(maximum_depth, depth)
            children = item.get("children")
            if isinstance(children, list) and children:
                hierarchical = True
                visit(children, depth + 1)

    visit(symbols, 1)
    return {
        "count": count,
        "maximum_depth": maximum_depth,
        "hierarchical": hierarchical,
    }


def lsp_fixture_measurement(
    client: JSONRPCProcess,
    *,
    name: str,
    path: Path,
    source: str,
    version: int,
    position_encoding: str,
) -> dict[str, Any]:
    if position_encoding != "utf-16":
        raise PrototypeError(
            f"{name} cannot validate unsupported position encoding "
            f"{position_encoding!r}"
        )
    uri = path.resolve().as_uri()
    client.notify(
        "textDocument/didOpen",
        {
            "textDocument": {
                "uri": uri,
                "languageId": "swift",
                "version": version,
                "text": source,
            }
        },
    )
    text_document = {"textDocument": {"uri": uri}}
    folding_ranges, folding_milliseconds = client.request(
        "textDocument/foldingRange",
        text_document,
    )
    symbols, symbol_milliseconds = client.request(
        "textDocument/documentSymbol",
        text_document,
    )
    cold_range_validation = {
        **validate_folding_ranges(
            folding_ranges,
            source,
            context=f"{name}.cold.foldingRange",
        ),
        **validate_document_symbols(
            symbols,
            source,
            context=f"{name}.cold.documentSymbol",
            require_unicode_symbol=name == "valid",
        ),
    }

    edited_source = source + "\n// incremental edit 🌲\n"
    version += 1
    client.notify(
        "textDocument/didChange",
        {
            "textDocument": {"uri": uri, "version": version},
            "contentChanges": [{"text": edited_source}],
        },
    )
    updated_folding, incremental_folding_milliseconds = client.request(
        "textDocument/foldingRange",
        text_document,
    )
    updated_symbols, incremental_symbol_milliseconds = client.request(
        "textDocument/documentSymbol",
        text_document,
    )
    incremental_range_validation = {
        **validate_folding_ranges(
            updated_folding,
            edited_source,
            context=f"{name}.incremental.foldingRange",
        ),
        **validate_document_symbols(
            updated_symbols,
            edited_source,
            context=f"{name}.incremental.documentSymbol",
            require_unicode_symbol=name == "valid",
        ),
    }
    client.notify(
        "textDocument/didClose",
        {"textDocument": {"uri": uri}},
    )

    return {
        "name": name,
        "utf8_bytes": len(source.encode("utf-8")),
        "utf16_units": len(source.encode("utf-16-le")) // 2,
        "lines": source.count("\n") + 1,
        "cold_folding_request_milliseconds": folding_milliseconds,
        "cold_symbol_request_milliseconds": symbol_milliseconds,
        "incremental_folding_request_milliseconds": incremental_folding_milliseconds,
        "incremental_symbol_request_milliseconds": incremental_symbol_milliseconds,
        "fold_count": len(folding_ranges) if isinstance(folding_ranges, list) else 0,
        "incremental_fold_count": (
            len(updated_folding) if isinstance(updated_folding, list) else 0
        ),
        "symbols": symbol_metrics(symbols),
        "incremental_symbols": symbol_metrics(updated_symbols),
        "range_validation": {
            "position_encoding": position_encoding,
            "cold": cold_range_validation,
            "incremental": incremental_range_validation,
        },
    }


def measure_lsp(
    sourcekit_lsp: Path,
    fixtures: dict[str, tuple[Path, str]],
    environment: dict[str, str],
    timeout_seconds: float,
) -> dict[str, Any]:
    client = JSONRPCProcess(sourcekit_lsp, environment, timeout_seconds)
    try:
        initialization_parameters = {
            "processId": os.getpid(),
            "rootUri": REPOSITORY_ROOT.as_uri(),
            "capabilities": {
                "general": {"positionEncodings": ["utf-16"]},
                "textDocument": {
                    "synchronization": {
                        "didOpen": True,
                        "didChange": True,
                        "didClose": True,
                    },
                    "foldingRange": {
                        "dynamicRegistration": False,
                        "lineFoldingOnly": False,
                    },
                    "documentSymbol": {
                        "dynamicRegistration": False,
                        "hierarchicalDocumentSymbolSupport": True,
                    },
                },
                "workspace": {"workspaceFolders": True},
            },
            "workspaceFolders": [
                {
                    "uri": REPOSITORY_ROOT.as_uri(),
                    "name": REPOSITORY_ROOT.name,
                }
            ],
        }
        initialize_result, initialize_milliseconds = client.request(
            "initialize",
            initialization_parameters,
        )
        client.notify("initialized", {})
        initialize_dictionary = (
            initialize_result if isinstance(initialize_result, dict) else {}
        )
        capabilities = initialize_dictionary.get("capabilities")
        position_encoding = negotiated_utf16_position_encoding(capabilities)

        results: list[dict[str, Any]] = []
        version = 1
        for name, (path, source) in fixtures.items():
            results.append(
                lsp_fixture_measurement(
                    client,
                    name=name,
                    path=path,
                    source=source,
                    version=version,
                    position_encoding=position_encoding,
                )
            )
            version += 2

        large_path, large_source = fixtures["large"]
        large_uri = large_path.resolve().as_uri()
        client.notify(
            "textDocument/didOpen",
            {
                "textDocument": {
                    "uri": large_uri,
                    "languageId": "swift",
                    "version": version,
                    "text": large_source,
                }
            },
        )
        cancellation_identifier = client.begin_request(
            "textDocument/documentSymbol",
            {"textDocument": {"uri": large_uri}},
        )
        client.notify("$/cancelRequest", {"id": cancellation_identifier})
        cancellation_response = client.wait_for_response(
            cancellation_identifier,
            timeout_seconds,
        )
        if "error" in cancellation_response:
            cancellation_status = {
                "outcome": "error",
                "code": cancellation_response["error"].get("code"),
                "message": cancellation_response["error"].get("message"),
            }
        else:
            cancellation_status = {
                "outcome": "completed_before_cancel",
                "symbol_count": symbol_metrics(
                    cancellation_response.get("result")
                )["count"],
            }
        client.notify(
            "textDocument/didClose",
            {"textDocument": {"uri": large_uri}},
        )

        return {
            "initialize_milliseconds": initialize_milliseconds,
            "server_info": initialize_dictionary.get("serverInfo"),
            "capabilities": {
                "position_encoding": capabilities.get(
                    "positionEncoding",
                    position_encoding,
                ),
                "folding_range_provider": capabilities.get(
                    "foldingRangeProvider",
                    False,
                ),
                "document_symbol_provider": capabilities.get(
                    "documentSymbolProvider",
                    False,
                ),
            },
            "fixtures": results,
            "cancellation": cancellation_status,
        }
    finally:
        client.close()


def directory_size(path: Path) -> int:
    return sum(
        item.stat().st_size
        for item in path.rglob("*")
        if item.is_file() and not item.is_symlink()
    )


def measure_tree_sitter(
    fixtures: dict[str, tuple[Path, str]],
    scratch_path: Path,
    environment: dict[str, str],
) -> dict[str, Any]:
    build_command = [
        "xcrun",
        "swift",
        "build",
        "--package-path",
        str(TREE_SITTER_PACKAGE),
        "--scratch-path",
        str(scratch_path),
        "--disable-automatic-resolution",
        "-c",
        "release",
    ]
    build_start = time.perf_counter()
    build = subprocess.run(
        build_command,
        capture_output=True,
        text=True,
        env=environment,
    )
    build_milliseconds = (time.perf_counter() - build_start) * 1_000
    if build.returncode != 0:
        raise PrototypeError(
            "Tree-sitter probe build failed:\n"
            + build.stdout
            + "\n"
            + build.stderr
        )

    binary_candidates = list(scratch_path.rglob("StructuralIntelligenceProbe"))
    binary_candidates = [
        candidate
        for candidate in binary_candidates
        if candidate.is_file() and os.access(candidate, os.X_OK)
    ]
    if not binary_candidates:
        raise PrototypeError("Tree-sitter probe executable was not produced")
    binary = max(binary_candidates, key=lambda path: path.stat().st_mtime_ns)

    arguments = [str(binary)]
    for name, (path, _) in fixtures.items():
        arguments.append(f"{name}={path}")
    probe = subprocess.run(
        arguments,
        check=True,
        capture_output=True,
        text=True,
        env=environment,
    )

    return {
        "fresh_scratch_resolution_and_release_build_milliseconds": build_milliseconds,
        "probe_binary_bytes": binary.stat().st_size,
        "scratch_tree_bytes": directory_size(scratch_path),
        "fixtures": json.loads(probe.stdout),
    }


def toolchain_metadata(
    sourcekit_lsp: Path,
    environment: dict[str, str],
    developer_directory: str | None,
) -> dict[str, Any]:
    def optional_output(command: list[str]) -> str | None:
        try:
            return command_output(command, environment=environment)
        except (OSError, subprocess.CalledProcessError):
            return None

    return {
        "developer_directory": developer_directory,
        "xcode": optional_output(["xcodebuild", "-version"]),
        "swift": optional_output(["xcrun", "swiftc", "--version"]),
        "sourcekit_lsp_path": str(sourcekit_lsp),
        "sourcekit_lsp_sha256": sha256_file(sourcekit_lsp),
        "sourcekit_lsp_binary_bytes": sourcekit_lsp.stat().st_size,
    }


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sourcekit-lsp",
        help="absolute sourcekit-lsp path; otherwise discovered with xcrun",
    )
    parser.add_argument(
        "--scratch-path",
        type=Path,
        help="Tree-sitter SwiftPM scratch directory (default: temporary)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="write JSON results here instead of stdout",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="per-LSP-request timeout in seconds",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="verify pinned revisions and fixture hashes without building",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        fixture_metadata = validate_inputs()
        if arguments.validate_only:
            print(json.dumps(fixture_metadata, indent=2, sort_keys=True))
            return 0

        environment, developer_directory = developer_environment()
        sourcekit_lsp = resolve_sourcekit_lsp(
            arguments.sourcekit_lsp,
            environment,
        )

        with tempfile.TemporaryDirectory(prefix="pine-structural-fixtures-") as fixture_tmp:
            large_path = Path(fixture_tmp) / "large.generated.swift"
            large_source = generate_large_fixture()
            large_path.write_text(large_source, encoding="utf-8")
            fixtures = {
                "valid": (
                    FIXTURE_DIRECTORY / "valid.swift",
                    (FIXTURE_DIRECTORY / "valid.swift").read_text(encoding="utf-8"),
                ),
                "malformed": (
                    FIXTURE_DIRECTORY / "malformed.swift",
                    (FIXTURE_DIRECTORY / "malformed.swift").read_text(
                        encoding="utf-8"
                    ),
                ),
                "large": (large_path, large_source),
            }

            temporary_scratch: tempfile.TemporaryDirectory[str] | None = None
            if arguments.scratch_path:
                scratch_path = arguments.scratch_path.resolve()
                scratch_path.mkdir(parents=True, exist_ok=True)
            else:
                temporary_scratch = tempfile.TemporaryDirectory(
                    prefix="pine-structural-tree-sitter-"
                )
                scratch_path = Path(temporary_scratch.name)

            try:
                result = {
                    "schema_version": 1,
                    "measured_at": datetime.now(timezone.utc).isoformat(),
                    "host": {
                        "platform": platform.platform(),
                        "machine": platform.machine(),
                    },
                    "repository_commit": optional_repository_commit(),
                    "fixtures": fixture_metadata,
                    "toolchain": toolchain_metadata(
                        sourcekit_lsp,
                        environment,
                        developer_directory,
                    ),
                    "lsp": measure_lsp(
                        sourcekit_lsp,
                        fixtures,
                        environment,
                        arguments.timeout,
                    ),
                    "tree_sitter": measure_tree_sitter(
                        fixtures,
                        scratch_path,
                        environment,
                    ),
                }
            finally:
                if temporary_scratch:
                    temporary_scratch.cleanup()

        output = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if arguments.output:
            arguments.output.write_text(output, encoding="utf-8")
        else:
            sys.stdout.write(output)
        return 0
    except (
        OSError,
        PrototypeError,
        subprocess.CalledProcessError,
        json.JSONDecodeError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


def optional_repository_commit() -> str | None:
    try:
        return command_output(
            ["git", "rev-parse", "HEAD"],
        )
    except (OSError, subprocess.CalledProcessError):
        return None


if __name__ == "__main__":
    raise SystemExit(main())
