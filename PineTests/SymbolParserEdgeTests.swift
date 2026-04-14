//
//  SymbolParserEdgeTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("SymbolParser Edge Case Tests")
@MainActor
struct SymbolParserEdgeTests {

    // MARK: - Empty / unsupported inputs

    @Test("Empty file returns no symbols")
    func emptyFile() {
        let symbols = SymbolParser.parse(content: "", fileExtension: "swift")
        #expect(symbols.isEmpty)
    }

    @Test("Empty extension returns no symbols")
    func emptyExtension() {
        let code = "class Foo {}"
        let symbols = SymbolParser.parse(content: code, fileExtension: "")
        #expect(symbols.isEmpty)
    }

    @Test("C file returns no symbols (unsupported)")
    func cFileUnsupported() {
        let code = """
        void main() {}
        struct Point { int x; int y; };
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "c")
        #expect(symbols.isEmpty)
    }

    @Test("C++ file returns no symbols (unsupported)")
    func cppFileUnsupported() {
        let code = """
        class Widget {};
        void render() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "cpp")
        #expect(symbols.isEmpty)
    }

    @Test("Header file returns no symbols (unsupported)")
    func headerFileUnsupported() {
        let code = """
        @interface NSObject
        @end
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "h")
        #expect(symbols.isEmpty)
    }

    // MARK: - Ruby

    @Test("Ruby: parses modules")
    func rubyModules() {
        let code = """
        module MyModule
            def hello
            end
        end
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "rb")
        #expect(symbols.contains { $0.name == "MyModule" && $0.kind == .class })
        #expect(symbols.contains { $0.name == "hello" && $0.kind == .function })
    }

    @Test("Ruby: self.method")
    func rubySelfMethod() {
        let code = """
        class Foo
            def self.bar
            end
        end
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "rb")
        #expect(symbols.contains { $0.name == "bar" && $0.kind == .function })
    }

    @Test("Ruby: question mark and bang methods")
    func rubySpecialMethods() {
        let code = """
        def valid?
        end
        def save!
        end
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "rb")
        let funcs = symbols.filter { $0.kind == .function }
        #expect(funcs.count == 2)
        #expect(funcs[0].name == "valid?")
        #expect(funcs[1].name == "save!")
    }

    @Test("Ruby: comments exclude symbols")
    func rubyCommentExclusion() {
        let code = """
        # def not_a_function
        def real_function
        end
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "rb")
        #expect(symbols.count == 1)
        #expect(symbols[0].name == "real_function")
    }

    // MARK: - Java/Kotlin

    @Test("Java: parses classes, interfaces, enums")
    func javaSymbols() {
        let code = """
        public class MyService {
            public void handle() {}
        }
        public interface IHandler {
        }
        public enum Status {
        }
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "java")
        #expect(symbols.contains { $0.name == "MyService" && $0.kind == .class })
        #expect(symbols.contains { $0.name == "IHandler" && $0.kind == .interface })
        #expect(symbols.contains { $0.name == "Status" && $0.kind == .enum })
    }

    @Test("Kotlin: parses suspend fun")
    func kotlinSuspendFun() {
        let code = """
        suspend fun fetchData() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "kt")
        let funcs = symbols.filter { $0.kind == .function }
        #expect(funcs.count == 1)
        #expect(funcs[0].name == "fetchData")
    }

    @Test("Kotlin: parses via kts extension")
    func kotlinScriptExtension() {
        let code = """
        class BuildScript {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "kts")
        #expect(symbols.contains { $0.name == "BuildScript" && $0.kind == .class })
    }

    // MARK: - TypeScript edge cases

    @Test("TypeScript: abstract class")
    func typescriptAbstractClass() {
        let code = """
        export abstract class BaseService {
        }
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "ts")
        #expect(symbols.contains { $0.name == "BaseService" && $0.kind == .class })
    }

    @Test("TypeScript: arrow function export")
    func typescriptArrowFunctionExport() {
        let code = """
        export const processData = async (input) => {
        }
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "tsx")
        let funcs = symbols.filter { $0.kind == .function }
        #expect(funcs.count == 1)
        #expect(funcs[0].name == "processData")
    }

    // MARK: - Rust edge cases

    @Test("Rust: pub(crate) visibility")
    func rustPubCrate() {
        let code = """
        pub(crate) struct Internal {
        }
        pub(crate) fn helper() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "rs")
        #expect(symbols.contains { $0.name == "Internal" && $0.kind == .struct })
        #expect(symbols.contains { $0.name == "helper" && $0.kind == .function })
    }

    // MARK: - Go edge cases

    @Test("Go: method receiver")
    func goMethodReceiver() {
        let code = """
        func (s *Server) Start() {}
        func (s Server) Stop() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "go")
        #expect(symbols.contains { $0.name == "Start" && $0.kind == .function })
        #expect(symbols.contains { $0.name == "Stop" && $0.kind == .function })
    }

    // MARK: - Python edge cases

    @Test("Python: .pyw extension")
    func pythonPywExtension() {
        let code = """
        class GuiApp:
            pass
        def main():
            pass
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "pyw")
        #expect(symbols.contains { $0.name == "GuiApp" && $0.kind == .class })
        #expect(symbols.contains { $0.name == "main" && $0.kind == .function })
    }

    // MARK: - JavaScript edge cases

    @Test("JavaScript: generator function")
    func jsGeneratorFunction() {
        let code = """
        function* generate() {
            yield 1;
        }
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "js")
        let funcs = symbols.filter { $0.kind == .function }
        #expect(funcs.count == 1)
        #expect(funcs[0].name == "generate")
    }

    @Test("JavaScript: mjs extension")
    func jsMjsExtension() {
        let code = """
        function main() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "mjs")
        #expect(symbols.contains { $0.name == "main" && $0.kind == .function })
    }

    // MARK: - lineNumber edge cases

    @Test("lineNumber: offset beyond content returns last line")
    func lineNumberBeyondContent() {
        let content = "abc\ndef"
        // offset 100 is way beyond the text
        let line = SymbolParser.lineNumber(at: 100, in: content)
        #expect(line == 2)
    }

    @Test("lineNumber: multi-byte characters")
    func lineNumberMultiByte() {
        let content = "café\nbar"
        // "café" is 5 UTF-16 units (c, a, f, é is 1 unit, \n), bar starts at offset 5
        let line = SymbolParser.lineNumber(at: 5, in: content)
        #expect(line == 2)
    }

    // MARK: - PineSymbol Equatable

    @Test("PineSymbol equality by value, not id")
    func pineSymbolEquality() {
        let a = PineSymbol(name: "foo", kind: .function, line: 1)
        let b = PineSymbol(name: "foo", kind: .function, line: 1)
        #expect(a == b) // same values, different UUIDs
    }

    @Test("PineSymbol inequality when kind differs")
    func pineSymbolInequalityKind() {
        let a = PineSymbol(name: "Foo", kind: .class, line: 1)
        let b = PineSymbol(name: "Foo", kind: .struct, line: 1)
        #expect(a != b)
    }

    // MARK: - Swift: access modifiers

    @Test("Swift: open class")
    func swiftOpenClass() {
        let code = """
        open class BaseViewModel {
        }
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        #expect(symbols.contains { $0.name == "BaseViewModel" && $0.kind == .class })
    }

    @Test("Swift: fileprivate struct")
    func swiftFileprivateStruct() {
        let code = """
        fileprivate struct InternalModel {
        }
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        #expect(symbols.contains { $0.name == "InternalModel" && $0.kind == .struct })
    }

    @Test("Swift: mutating func")
    func swiftMutatingFunc() {
        let code = """
        mutating func update() {}
        """
        let symbols = SymbolParser.parse(content: code, fileExtension: "swift")
        #expect(symbols.contains { $0.name == "update" && $0.kind == .function })
    }
}
