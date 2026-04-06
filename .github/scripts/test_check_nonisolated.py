"""Unit tests for check_nonisolated.py."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from check_nonisolated import (
    BG_QUEUE_PATTERNS,
    TypeDecl,
    find_background_queues,
    find_type_declarations,
    is_explicitly_isolated,
    scan_file,
    scan_paths,
)


def _write(tmp: Path, name: str, body: str) -> Path:
    p = tmp / name
    p.write_text(body, encoding="utf-8")
    return p


class TestPatterns(unittest.TestCase):
    """Sanity checks for the background-queue regex set."""

    def test_global_async(self):
        self.assertTrue(any(p.search("DispatchQueue.global().async {") for p in BG_QUEUE_PATTERNS))

    def test_global_with_qos(self):
        self.assertTrue(
            any(p.search("DispatchQueue.global(qos: .userInitiated).async {") for p in BG_QUEUE_PATTERNS)
        )

    def test_labeled_queue(self):
        self.assertTrue(
            any(p.search('let q = DispatchQueue(label: "com.pine.foo")') for p in BG_QUEUE_PATTERNS)
        )

    def test_operation_queue(self):
        self.assertTrue(any(p.search("let q = OperationQueue()") for p in BG_QUEUE_PATTERNS))

    def test_main_queue_excluded(self):
        for p in BG_QUEUE_PATTERNS:
            self.assertIsNone(p.search("DispatchQueue.main.async { }"))


class TestFindTypeDeclarations(unittest.TestCase):
    """The parser must locate types and their body ranges."""

    def setUp(self):
        self._tmp_ctx = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp_ctx.name)

    def tearDown(self):
        self._tmp_ctx.cleanup()

    def test_simple_class(self):
        src = "final class Foo {\n    var x = 1\n}\n"
        decls = find_type_declarations(src, Path("Foo.swift"))
        self.assertEqual(len(decls), 1)
        self.assertEqual(decls[0].name, "Foo")
        self.assertEqual(decls[0].kind, "class")
        self.assertEqual(decls[0].line, 1)
        self.assertIn("final", decls[0].attrs)

    def test_main_actor_attribute_on_previous_line(self):
        src = "@MainActor\n@Observable\nfinal class Foo {\n}\n"
        decls = find_type_declarations(src, Path("Foo.swift"))
        self.assertEqual(len(decls), 1)
        self.assertIn("@MainActor", decls[0].attrs)
        self.assertIn("@Observable", decls[0].attrs)
        self.assertTrue(is_explicitly_isolated(decls[0]))

    def test_nonisolated_attribute_on_previous_line(self):
        src = "nonisolated\nfinal class Foo {\n}\n"
        decls = find_type_declarations(src, Path("Foo.swift"))
        self.assertEqual(len(decls), 1)
        self.assertTrue(is_explicitly_isolated(decls[0]))

    def test_attribute_with_args_on_previous_line(self):
        src = "@available(macOS 26, *)\n@MainActor\nfinal class Foo {\n}\n"
        decls = find_type_declarations(src, Path("Foo.swift"))
        self.assertEqual(len(decls), 1)
        self.assertTrue(is_explicitly_isolated(decls[0]))

    def test_doc_comment_between_attribute_and_decl(self):
        src = (
            "@MainActor\n"
            "/// Doc line\n"
            "final class Foo {\n"
            "}\n"
        )
        decls = find_type_declarations(src, Path("Foo.swift"))
        self.assertEqual(len(decls), 1)
        self.assertTrue(is_explicitly_isolated(decls[0]))

    def test_blank_line_separates_unrelated_attribute(self):
        src = (
            "@MainActor\n"
            "func unrelated() { }\n"
            "\n"
            "final class Foo {\n"
            "}\n"
        )
        decls = find_type_declarations(src, Path("Foo.swift"))
        self.assertEqual(len(decls), 1)
        self.assertFalse(is_explicitly_isolated(decls[0]))

    def test_inline_main_actor(self):
        src = "@MainActor final class Foo { }\n"
        decls = find_type_declarations(src, Path("Foo.swift"))
        self.assertEqual(len(decls), 1)
        self.assertIn("@MainActor", decls[0].attrs)
        self.assertTrue(is_explicitly_isolated(decls[0]))

    def test_inline_nonisolated(self):
        src = "nonisolated final class Foo { }\n"
        decls = find_type_declarations(src, Path("Foo.swift"))
        self.assertEqual(len(decls), 1)
        self.assertIn("nonisolated", decls[0].attrs)
        self.assertTrue(is_explicitly_isolated(decls[0]))

    def test_unmarked_class(self):
        src = "class Foo { }\n"
        decls = find_type_declarations(src, Path("Foo.swift"))
        self.assertEqual(len(decls), 1)
        self.assertFalse(is_explicitly_isolated(decls[0]))

    def test_nested_types(self):
        src = (
            "class Outer {\n"
            "    enum Inner {\n"
            "        case a\n"
            "    }\n"
            "}\n"
        )
        decls = find_type_declarations(src, Path("X.swift"))
        names = sorted(d.name for d in decls)
        self.assertEqual(names, ["Inner", "Outer"])

    def test_body_range_tracks_braces(self):
        src = (
            "class Foo {\n"
            "    func bar() {\n"
            "        if true { print(\"x\") }\n"
            "    }\n"
            "}\n"
        )
        decls = find_type_declarations(src, Path("Foo.swift"))
        self.assertEqual(len(decls), 1)
        self.assertEqual(decls[0].body_start, 0)
        self.assertEqual(decls[0].body_end, 4)

    def test_struct_and_actor(self):
        src = "struct A { }\nactor B { }\nenum C { }\n"
        decls = find_type_declarations(src, Path("X.swift"))
        kinds = sorted(d.kind for d in decls)
        self.assertEqual(kinds, ["actor", "enum", "struct"])

    def test_protocol_not_matched(self):
        src = "protocol P { }\n"
        decls = find_type_declarations(src, Path("X.swift"))
        self.assertEqual(decls, [])

    def test_extension_not_matched(self):
        src = "extension Foo { }\n"
        decls = find_type_declarations(src, Path("X.swift"))
        self.assertEqual(decls, [])

    def test_string_with_class_keyword_is_ignored(self):
        # `class` appears after the start of line, so the anchored regex won't
        # match — guaranteed by the leading-whitespace anchor.
        src = '    let s = "class Foo { }"\n'
        decls = find_type_declarations(src, Path("X.swift"))
        self.assertEqual(decls, [])


class TestFindBackgroundQueues(unittest.TestCase):
    def test_finds_global(self):
        lines = [
            "func a() {",
            "    DispatchQueue.global(qos: .userInitiated).async {",
            "    }",
            "}",
        ]
        hits = find_background_queues(lines, 0, len(lines) - 1)
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0][0], 2)

    def test_ignores_main(self):
        lines = ["DispatchQueue.main.async { }"]
        hits = find_background_queues(lines, 0, 0)
        self.assertEqual(hits, [])

    def test_finds_operation_queue(self):
        lines = ["    private let q = OperationQueue()"]
        hits = find_background_queues(lines, 0, 0)
        self.assertEqual(len(hits), 1)


class TestScanFile(unittest.TestCase):
    def setUp(self):
        self._tmp_ctx = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp_ctx.name)

    def tearDown(self):
        self._tmp_ctx.cleanup()

    def test_unmarked_class_with_global_queue_violates(self):
        body = (
            "import Foundation\n"
            "final class Foo {\n"
            "    func go() {\n"
            "        DispatchQueue.global().async { print(1) }\n"
            "    }\n"
            "}\n"
        )
        f = _write(self.tmp, "Foo.swift", body)
        v = scan_file(f)
        self.assertEqual(len(v), 1)
        self.assertEqual(v[0].type_name, "Foo")
        self.assertEqual(v[0].type_kind, "class")
        self.assertEqual(v[0].queue_line, 4)

    def test_nonisolated_class_passes(self):
        body = (
            "nonisolated final class Foo {\n"
            "    func go() {\n"
            "        DispatchQueue.global().async { print(1) }\n"
            "    }\n"
            "}\n"
        )
        f = _write(self.tmp, "Foo.swift", body)
        self.assertEqual(scan_file(f), [])

    def test_main_actor_class_passes(self):
        body = (
            "@MainActor final class Foo {\n"
            "    func go() {\n"
            "        DispatchQueue.global().async { print(1) }\n"
            "    }\n"
            "}\n"
        )
        f = _write(self.tmp, "Foo.swift", body)
        self.assertEqual(scan_file(f), [])

    def test_unmarked_enum_namespace_violates(self):
        body = (
            "enum Worker {\n"
            "    static func go() {\n"
            "        DispatchQueue.global().async { }\n"
            "    }\n"
            "}\n"
        )
        f = _write(self.tmp, "Worker.swift", body)
        v = scan_file(f)
        self.assertEqual(len(v), 1)
        self.assertEqual(v[0].type_kind, "enum")

    def test_nonisolated_enum_namespace_passes(self):
        body = (
            "nonisolated enum Worker {\n"
            "    static func go() {\n"
            "        DispatchQueue.global().async { }\n"
            "    }\n"
            "}\n"
        )
        f = _write(self.tmp, "Worker.swift", body)
        self.assertEqual(scan_file(f), [])

    def test_nested_unmarked_inside_main_actor_outer_violates(self):
        body = (
            "@MainActor class Outer {\n"
            "    enum Inner {\n"
            "        static func go() {\n"
            "            DispatchQueue.global().async { }\n"
            "        }\n"
            "    }\n"
            "}\n"
        )
        f = _write(self.tmp, "X.swift", body)
        v = scan_file(f)
        # The innermost owner is `Inner`, which is unmarked → violation.
        self.assertEqual(len(v), 1)
        self.assertEqual(v[0].type_name, "Inner")

    def test_nested_nonisolated_inside_main_actor_outer_passes(self):
        body = (
            "@MainActor class Outer {\n"
            "    nonisolated enum Inner {\n"
            "        static func go() {\n"
            "            DispatchQueue.global().async { }\n"
            "        }\n"
            "    }\n"
            "}\n"
        )
        f = _write(self.tmp, "X.swift", body)
        self.assertEqual(scan_file(f), [])

    def test_main_queue_only_passes_even_without_isolation(self):
        body = (
            "class Foo {\n"
            "    func go() { DispatchQueue.main.async { } }\n"
            "}\n"
        )
        f = _write(self.tmp, "Foo.swift", body)
        self.assertEqual(scan_file(f), [])

    def test_labeled_queue_in_unmarked_class_violates(self):
        body = (
            "final class Foo {\n"
            '    private let q = DispatchQueue(label: "com.pine.foo")\n'
            "}\n"
        )
        f = _write(self.tmp, "Foo.swift", body)
        v = scan_file(f)
        self.assertEqual(len(v), 1)

    def test_operation_queue_in_unmarked_class_violates(self):
        body = (
            "final class Foo {\n"
            "    private let q = OperationQueue()\n"
            "}\n"
        )
        f = _write(self.tmp, "Foo.swift", body)
        self.assertEqual(len(scan_file(f)), 1)

    def test_comment_with_dispatchqueue_does_not_violate(self):
        body = (
            "final class Foo {\n"
            "    // DispatchQueue.global().async — historical note\n"
            "}\n"
        )
        f = _write(self.tmp, "Foo.swift", body)
        self.assertEqual(scan_file(f), [])

    def test_top_level_free_function_is_out_of_scope(self):
        body = (
            "func go() {\n"
            "    DispatchQueue.global().async { }\n"
            "}\n"
        )
        f = _write(self.tmp, "Foo.swift", body)
        # No type owner — script does not flag free functions.
        self.assertEqual(scan_file(f), [])

    def test_multiple_violations_in_one_file(self):
        body = (
            "class A {\n"
            "    func go() { DispatchQueue.global().async { } }\n"
            "}\n"
            "class B {\n"
            "    func go() { DispatchQueue.global().async { } }\n"
            "}\n"
        )
        f = _write(self.tmp, "X.swift", body)
        v = scan_file(f)
        self.assertEqual(len(v), 2)
        self.assertEqual({x.type_name for x in v}, {"A", "B"})


class TestScanPaths(unittest.TestCase):
    def test_directory_scan(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            _write(tmp, "Good.swift", "nonisolated final class G {\n  func g() { DispatchQueue.global().async { } }\n}\n")
            _write(tmp, "Bad.swift", "final class B {\n  func b() { DispatchQueue.global().async { } }\n}\n")
            v = scan_paths([tmp])
            self.assertEqual(len(v), 1)
            self.assertEqual(v[0].type_name, "B")


if __name__ == "__main__":
    unittest.main()
