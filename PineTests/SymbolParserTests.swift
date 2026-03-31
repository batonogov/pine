//
//  SymbolParserTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("SymbolParser Tests")
@MainActor
struct SymbolParserTests {

    // MARK: - Swift

    @Test("Swift: parses functions")
    func swiftFunctions() {
        let code = """
        func hello() {
        }
        public func world() {
        }
        private static func helper() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        let funcs = symbols.filter { $0.kind == .function }
        #expect(funcs.count == 3)
        #expect(funcs[0].name == "hello")
        #expect(funcs[1].name == "world")
        #expect(funcs[2].name == "helper")
    }

    @Test("Swift: parses classes")
    func swiftClasses() {
        let code = """
        class MyClass {
        }
        public final class AnotherClass {
        }
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        let classes = symbols.filter { $0.kind == .class }
        #expect(classes.count == 2)
        #expect(classes[0].name == "MyClass")
        #expect(classes[1].name == "AnotherClass")
    }

    @Test("Swift: parses structs")
    func swiftStructs() {
        let code = """
        struct Point {
            var x: Int
            var y: Int
        }
        public struct Size {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        let structs = symbols.filter { $0.kind == .struct }
        #expect(structs.count == 2)
        #expect(structs[0].name == "Point")
        #expect(structs[1].name == "Size")
    }

    @Test("Swift: parses enums")
    func swiftEnums() {
        let code = """
        enum Direction {
            case north, south
        }
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        let enums = symbols.filter { $0.kind == .enum }
        #expect(enums.count == 1)
        #expect(enums[0].name == "Direction")
    }

    @Test("Swift: parses protocols")
    func swiftProtocols() {
        let code = """
        protocol Drawable {
            func draw()
        }
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        let protocols = symbols.filter { $0.kind == .protocol }
        #expect(protocols.count == 1)
        #expect(protocols[0].name == "Drawable")
        // Also check the nested function
        let funcs = symbols.filter { $0.kind == .function }
        #expect(funcs.count == 1)
        #expect(funcs[0].name == "draw")
    }

    @Test("Swift: parses all symbol kinds together")
    func swiftAllKinds() {
        let code = """
        class Foo {}
        struct Bar {}
        enum Baz {}
        protocol Qux {}
        func doStuff() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        #expect(symbols.count == 5)
        #expect(symbols[0].kind == .class)
        #expect(symbols[1].kind == .struct)
        #expect(symbols[2].kind == .enum)
        #expect(symbols[3].kind == .protocol)
        #expect(symbols[4].kind == .function)
    }

    // MARK: - Python

    @Test("Python: parses classes and functions")
    func pythonSymbols() {
        let code = """
        class MyClass:
            def method(self):
                pass

        def standalone():
            pass

        async def async_func():
            pass
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "py")
        let classes = symbols.filter { $0.kind == .class }
        let funcs = symbols.filter { $0.kind == .function }
        #expect(classes.count == 1)
        #expect(classes[0].name == "MyClass")
        #expect(funcs.count == 3)
        #expect(funcs[0].name == "method")
        #expect(funcs[1].name == "standalone")
        #expect(funcs[2].name == "async_func")
    }

    @Test("Python: nested function")
    func pythonNestedFunction() {
        let code = """
        def outer():
            def inner():
                pass
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "py")
        let funcs = symbols.filter { $0.kind == .function }
        #expect(funcs.count == 2)
        #expect(funcs[0].name == "outer")
        #expect(funcs[1].name == "inner")
    }

    // MARK: - JavaScript

    @Test("JavaScript: parses functions and classes")
    func javascriptSymbols() {
        let code = """
        class App {
        }

        function render() {}

        const handler = () => {}

        export const fetchData = async (url) => {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "js")
        let classes = symbols.filter { $0.kind == .class }
        let funcs = symbols.filter { $0.kind == .function }
        #expect(classes.count == 1)
        #expect(classes[0].name == "App")
        #expect(funcs.count == 3)
        #expect(funcs[0].name == "render")
        #expect(funcs[1].name == "handler")
        #expect(funcs[2].name == "fetchData")
    }

    // MARK: - TypeScript

    @Test("TypeScript: parses interfaces and enums")
    func typescriptSymbols() {
        let code = """
        export interface User {
            name: string;
        }

        export enum Status {
            Active,
            Inactive,
        }

        export class Service {}

        export function init() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "ts")
        #expect(symbols.contains { $0.name == "User" && $0.kind == .interface })
        #expect(symbols.contains { $0.name == "Status" && $0.kind == .enum })
        #expect(symbols.contains { $0.name == "Service" && $0.kind == .class })
        #expect(symbols.contains { $0.name == "init" && $0.kind == .function })
    }

    // MARK: - Comment Exclusion

    @Test("Skips symbols inside single-line comments")
    func skipsSingleLineComments() {
        let code = """
        // func commentedOut() {}
        func realFunction() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        #expect(symbols.count == 1)
        #expect(symbols[0].name == "realFunction")
    }

    @Test("Skips symbols inside block comments")
    func skipsBlockComments() {
        let code = """
        /* class CommentedClass {} */
        class RealClass {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        let classes = symbols.filter { $0.kind == .class }
        #expect(classes.count == 1)
        #expect(classes[0].name == "RealClass")
    }

    @Test("Skips symbols inside Python comments")
    func skipsPythonComments() {
        let code = """
        # def commented():
        #     pass
        def real():
            pass
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "py")
        #expect(symbols.count == 1)
        #expect(symbols[0].name == "real")
    }

    // MARK: - String Exclusion

    @Test("Skips symbols inside strings")
    func skipsStrings() {
        let code = """
        let msg = "func fakeFunction() {}"
        func realFunction() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        let funcs = symbols.filter { $0.kind == .function }
        #expect(funcs.count == 1)
        #expect(funcs[0].name == "realFunction")
    }

    @Test("Skips symbols inside Python triple-quoted strings")
    func skipsPythonTripleQuotedStrings() {
        let code = "\"\"\"def fake():\n    pass\"\"\"\ndef real():\n    pass"
        let symbols = SymbolParser.parse(content: code, fileExtension: "py")
        #expect(symbols.count == 1)
        #expect(symbols[0].name == "real")
    }

    // MARK: - Fuzzy Matching

    @Test("Fuzzy filter: exact match")
    func fuzzyExact() {
        let symbols = [
            PineSymbol(name: "viewDidLoad", kind: .function, line: 1),
            PineSymbol(name: "viewWillAppear", kind: .function, line: 5),
        ]
        let filtered = SymbolParser.filter(symbols, query: "viewDidLoad")
        #expect(filtered.count == 1)
        #expect(filtered[0].name == "viewDidLoad")
    }

    @Test("Fuzzy filter: subsequence match")
    func fuzzySubsequence() {
        let symbols = [
            PineSymbol(name: "viewDidLoad", kind: .function, line: 1),
            PineSymbol(name: "viewWillAppear", kind: .function, line: 5),
            PineSymbol(name: "setupConstraints", kind: .function, line: 10),
        ]
        let filtered = SymbolParser.filter(symbols, query: "vdl")
        #expect(filtered.count == 1)
        #expect(filtered[0].name == "viewDidLoad")
    }

    @Test("Fuzzy filter: empty query returns all")
    func fuzzyEmptyQuery() {
        let symbols = [
            PineSymbol(name: "foo", kind: .function, line: 1),
            PineSymbol(name: "bar", kind: .function, line: 2),
        ]
        let filtered = SymbolParser.filter(symbols, query: "")
        #expect(filtered.count == 2)
    }

    @Test("Fuzzy filter: case insensitive")
    func fuzzyCaseInsensitive() {
        let symbols = [
            PineSymbol(name: "MyClass", kind: .class, line: 1),
        ]
        let filtered = SymbolParser.filter(symbols, query: "myclass")
        #expect(filtered.count == 1)
    }

    // MARK: - Empty File

    @Test("Empty file returns no symbols")
    func emptyFile() {
        let symbols = SymbolParser.parse(content: "", fileExtension: "swift")
        #expect(symbols.isEmpty)
    }

    @Test("Whitespace-only file returns no symbols")
    func whitespaceOnlyFile() {
        let symbols = SymbolParser.parse(content: "   \n\n   \n", fileExtension: "swift")
        #expect(symbols.isEmpty)
    }

    // MARK: - Unsupported Extension

    @Test("Unsupported extension returns no symbols")
    func unsupportedExtension() {
        let code = "func foo() {}"
        let symbols = SymbolParser.parse(content: code, fileExtension: "txt")
        #expect(symbols.isEmpty)
    }

    // MARK: - Nested Functions

    @Test("Swift: nested functions are both extracted")
    func swiftNestedFunctions() {
        let code = """
        func outer() {
            func inner() {
                func deeplyNested() {}
            }
        }
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        let funcs = symbols.filter { $0.kind == .function }
        #expect(funcs.count == 3)
        #expect(funcs[0].name == "outer")
        #expect(funcs[1].name == "inner")
        #expect(funcs[2].name == "deeplyNested")
    }

    // MARK: - Line Numbers

    @Test("Line numbers are correct")
    func lineNumbers() {
        let code = """
        class Foo {
            func bar() {}
        }

        func baz() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        #expect(symbols[0].line == 1) // class Foo
        #expect(symbols[1].line == 2) // func bar
        #expect(symbols[2].line == 5) // func baz
    }

    // MARK: - Go

    @Test("Go: parses structs, interfaces, and functions")
    func goSymbols() {
        let code = """
        type Server struct {
            Port int
        }

        type Handler interface {
            Handle()
        }

        func main() {}

        func (s *Server) Start() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "go")
        #expect(symbols.contains { $0.name == "Server" && $0.kind == .struct })
        #expect(symbols.contains { $0.name == "Handler" && $0.kind == .interface })
        #expect(symbols.contains { $0.name == "main" && $0.kind == .function })
        #expect(symbols.contains { $0.name == "Start" && $0.kind == .function })
    }

    // MARK: - Rust

    @Test("Rust: parses structs, enums, traits, and functions")
    func rustSymbols() {
        let code = """
        pub struct Config {
            pub name: String,
        }

        enum Color {
            Red,
            Green,
        }

        pub trait Display {
            fn fmt(&self);
        }

        pub async fn serve() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "rs")
        #expect(symbols.contains { $0.name == "Config" && $0.kind == .struct })
        #expect(symbols.contains { $0.name == "Color" && $0.kind == .enum })
        #expect(symbols.contains { $0.name == "Display" && $0.kind == .protocol })
        #expect(symbols.contains { $0.name == "serve" && $0.kind == .function })
        #expect(symbols.contains { $0.name == "fmt" && $0.kind == .function })
    }

    // MARK: - PineSymbolKind

    @Test("PineSymbolKind: sort order is stable")
    func symbolKindSorting() {
        let kinds: [PineSymbolKind] = [.function, .class, .enum, .struct, .protocol]
        let sorted = kinds.sorted()
        #expect(sorted == [.class, .struct, .enum, .protocol, .function])
    }

    @Test("PineSymbolKind: displayName is non-empty")
    func symbolKindDisplayName() {
        for kind in PineSymbolKind.allCases {
            #expect(!kind.displayName.isEmpty)
        }
    }

    @Test("PineSymbolKind: iconName is non-empty")
    func symbolKindIconName() {
        for kind in PineSymbolKind.allCases {
            #expect(!kind.iconName.isEmpty)
        }
    }

    // MARK: - lineNumber helper

    @Test("lineNumber: first character is line 1")
    func lineNumberFirstChar() {
        let content = "hello\nworld"
        #expect(SymbolParser.lineNumber(at: 0, in: content) == 1)
    }

    @Test("lineNumber: second line")
    func lineNumberSecondLine() {
        let content = "hello\nworld"
        // offset 6 = 'w' on line 2
        #expect(SymbolParser.lineNumber(at: 6, in: content) == 2)
    }

    @Test("lineNumber: empty content")
    func lineNumberEmptyContent() {
        #expect(SymbolParser.lineNumber(at: 0, in: "") == 1)
    }
}
