//
//  SupportedFileTypes.swift
//  Pine
//
//  Created by Claude on 24.03.2026.
//

import Foundation

/// Defines all file types Pine registers as an editor for in Finder's "Open With" menu.
/// Used to generate `CFBundleDocumentTypes` entries in Info.plist.
enum SupportedFileTypes {

    /// A document type registration for Info.plist.
    struct DocumentType: Equatable {
        let name: String
        let extensions: [String]
        let contentTypeIdentifiers: [String]
        let role: String

        init(name: String, extensions: [String], contentTypeIdentifiers: [String], role: String = "Editor") {
            self.name = name
            self.extensions = extensions
            self.contentTypeIdentifiers = contentTypeIdentifiers
            self.role = role
        }
    }

    /// All registered document types.
    static let documentTypes: [DocumentType] = [
        // Source code — system-defined UTIs
        DocumentType(
            name: "Swift Source",
            extensions: ["swift"],
            contentTypeIdentifiers: ["public.swift-source"]
        ),
        DocumentType(
            name: "C Source",
            extensions: ["c"],
            contentTypeIdentifiers: ["public.c-source"]
        ),
        DocumentType(
            name: "C++ Source",
            extensions: ["cpp", "cc", "cxx"],
            contentTypeIdentifiers: ["public.c-plus-plus-source"]
        ),
        DocumentType(
            name: "C Header",
            extensions: ["h", "hpp"],
            contentTypeIdentifiers: ["public.c-header"]
        ),
        DocumentType(
            name: "Objective-C Source",
            extensions: ["m", "mm"],
            contentTypeIdentifiers: ["public.objective-c-source"]
        ),
        DocumentType(
            name: "Python Script",
            extensions: ["py", "pyw"],
            contentTypeIdentifiers: ["public.python-script"]
        ),
        DocumentType(
            name: "Ruby Script",
            extensions: ["rb"],
            contentTypeIdentifiers: ["public.ruby-script"]
        ),
        DocumentType(
            name: "Shell Script",
            extensions: ["sh", "bash", "zsh"],
            contentTypeIdentifiers: ["public.shell-script"]
        ),
        DocumentType(
            name: "Java Source",
            extensions: ["java"],
            contentTypeIdentifiers: ["com.sun.java-source"]
        ),

        // Web — system-defined UTIs
        DocumentType(
            name: "JavaScript",
            extensions: ["js", "mjs", "cjs", "jsx"],
            contentTypeIdentifiers: ["com.netscape.javascript-source"]
        ),
        DocumentType(
            name: "TypeScript",
            extensions: ["ts", "tsx"],
            contentTypeIdentifiers: ["com.microsoft.typescript"]
        ),
        DocumentType(
            name: "HTML",
            extensions: ["html", "htm"],
            contentTypeIdentifiers: ["public.html"]
        ),
        DocumentType(
            name: "CSS",
            extensions: ["css"],
            contentTypeIdentifiers: ["com.apple.css"]
        ),

        // Data formats — system-defined UTIs
        DocumentType(
            name: "JSON",
            extensions: ["json"],
            contentTypeIdentifiers: ["public.json"]
        ),
        DocumentType(
            name: "XML",
            extensions: ["xml", "xsd", "xsl", "xslt"],
            contentTypeIdentifiers: ["public.xml"]
        ),
        DocumentType(
            name: "YAML",
            extensions: ["yaml", "yml"],
            contentTypeIdentifiers: ["public.yaml"]
        ),

        // Text — system-defined UTIs
        DocumentType(
            name: "Plain Text",
            extensions: ["txt", "text"],
            contentTypeIdentifiers: ["public.plain-text"]
        ),
        DocumentType(
            name: "Markdown",
            extensions: ["md", "markdown"],
            contentTypeIdentifiers: ["net.daringfireball.markdown"]
        ),

        // Languages without well-known system UTIs — use dyn UTI
        DocumentType(
            name: "Go Source",
            extensions: ["go"],
            contentTypeIdentifiers: ["dev.go.source"]
        ),
        DocumentType(
            name: "Rust Source",
            extensions: ["rs"],
            contentTypeIdentifiers: ["org.rust-lang.source"]
        ),
        DocumentType(
            name: "Kotlin Source",
            extensions: ["kt", "kts"],
            contentTypeIdentifiers: ["org.jetbrains.kotlin"]
        ),
        DocumentType(
            name: "TOML",
            extensions: ["toml"],
            contentTypeIdentifiers: ["public.toml"]
        ),
        DocumentType(
            name: "Dart Source",
            extensions: ["dart"],
            contentTypeIdentifiers: ["com.google.dart-source"]
        ),
        DocumentType(
            name: "SQL",
            extensions: ["sql"],
            contentTypeIdentifiers: ["com.apple.sql"]
        ),
        DocumentType(
            name: "Groovy Source",
            extensions: ["groovy"],
            contentTypeIdentifiers: ["org.codehaus.groovy-source"]
        ),
        DocumentType(
            name: "GraphQL",
            extensions: ["graphql", "gql"],
            contentTypeIdentifiers: ["com.graphql.source"]
        ),
        DocumentType(
            name: "Nix",
            extensions: ["nix"],
            contentTypeIdentifiers: ["org.nixos.nix-source"]
        ),
        DocumentType(
            name: "Protocol Buffers",
            extensions: ["proto"],
            contentTypeIdentifiers: ["com.google.protobuf-source"]
        ),
        DocumentType(
            name: "Prisma",
            extensions: ["prisma"],
            contentTypeIdentifiers: ["com.prisma.schema"]
        ),
        DocumentType(
            name: "INI Configuration",
            extensions: ["ini", "cfg", "conf"],
            contentTypeIdentifiers: ["public.ini"]
        ),
        DocumentType(
            name: "Log File",
            extensions: ["log"],
            contentTypeIdentifiers: ["public.log"]
        ),
        DocumentType(
            name: "Diff/Patch",
            extensions: ["diff", "patch"],
            contentTypeIdentifiers: ["public.patch-file"]
        ),
        DocumentType(
            name: "Dockerfile",
            extensions: ["dockerfile"],
            contentTypeIdentifiers: ["com.docker.dockerfile"]
        ),
        DocumentType(
            name: "Terraform",
            extensions: ["tf", "tfvars"],
            contentTypeIdentifiers: ["com.hashicorp.terraform"]
        ),
        DocumentType(
            name: "HCL",
            extensions: ["hcl"],
            contentTypeIdentifiers: ["com.hashicorp.hcl"]
        ),
        DocumentType(
            name: "Makefile",
            extensions: ["makefile", "mk"],
            contentTypeIdentifiers: ["public.make-source"]
        ),
        DocumentType(
            name: "Nginx Configuration",
            extensions: ["nginx"],
            contentTypeIdentifiers: ["com.nginx.config"]
        ),
        DocumentType(
            name: "SSH Configuration",
            extensions: ["sshconfig"],
            contentTypeIdentifiers: ["com.openssh.config"]
        ),
    ]

    /// All registered file extensions as a flat set.
    static var allExtensions: Set<String> {
        var result = Set<String>()
        for docType in documentTypes {
            for ext in docType.extensions {
                result.insert(ext)
            }
        }
        return result
    }

    /// Generates the array of dictionaries suitable for `CFBundleDocumentTypes` in Info.plist.
    static var documentTypesForPlist: [[String: Any]] {
        documentTypes.map { docType in
            [
                "CFBundleTypeName": docType.name,
                "CFBundleTypeRole": docType.role,
                "LSItemContentTypes": docType.contentTypeIdentifiers,
                "CFBundleTypeExtensions": docType.extensions,
                "LSHandlerRank": "Alternate"
            ]
        }
    }
}
