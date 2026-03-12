//
//  FileIconMapperTests.swift
//  PineTests
//

import Testing
@testable import Pine

struct FileIconMapperTests {

    // MARK: - iconForFile — exact filename matches

    @Test(arguments: [
        ("Dockerfile", "shippingbox"),
        ("Containerfile", "shippingbox"),
        ("Makefile", "hammer"),
        ("CMakeLists.txt", "hammer"),
        (".gitignore", "arrow.triangle.branch"),
        (".gitattributes", "arrow.triangle.branch"),
        (".env", "lock.shield"),
        (".env.local", "lock.shield"),
        ("LICENSE", "doc.text.magnifyingglass"),
        ("licence", "doc.text.magnifyingglass"),
        ("package.json", "shippingbox"),
        ("Cargo.toml", "shippingbox"),
        ("go.mod", "shippingbox"),
        ("Podfile", "shippingbox"),
        ("Gemfile", "shippingbox"),
    ])
    func fileExactName(name: String, expected: String) {
        #expect(FileIconMapper.iconForFile(name) == expected)
    }

    // MARK: - iconForFile — extension-based matches

    @Test(arguments: [
        // Apple / Swift
        ("main.swift", "swift"),
        ("Info.plist", "list.bullet.rectangle"),
        ("Main.storyboard", "rectangle.on.rectangle"),

        // Web
        ("app.js", "curlybraces.square"),
        ("index.mjs", "curlybraces.square"),
        ("index.ts", "curlybraces.square"),
        ("App.tsx", "curlybraces.square"),
        ("index.html", "globe"),
        ("style.css", "paintbrush"),
        ("style.scss", "paintbrush"),
        ("App.vue", "curlybraces.square"),
        ("App.svelte", "curlybraces.square"),

        // Data / Config
        ("data.json", "curlybraces"),
        ("config.yaml", "list.dash"),
        ("settings.yml", "list.dash"),
        ("config.toml", "gearshape"),
        ("config.ini", "gearshape"),
        ("layout.xml", "chevron.left.forwardslash.chevron.right"),
        ("icon.svg", "chevron.left.forwardslash.chevron.right"),
        ("schema.graphql", "point.3.connected.trianglepath.dotted"),

        // Scripting / Systems
        ("main.py", "terminal"),
        ("script.rb", "terminal"),
        ("run.sh", "terminal"),
        ("init.zsh", "terminal"),
        ("main.go", "chevron.left.forwardslash.chevron.right"),
        ("main.rs", "gearshape.2"),
        ("main.c", "c.square"),
        ("main.cpp", "c.square"),
        ("App.java", "cup.and.saucer"),
        ("App.kt", "cup.and.saucer"),
        ("Program.cs", "number.square"),
        ("init.lua", "moon"),
        ("analysis.r", "chart.bar"),
        ("query.sql", "tablecells"),
        ("msg.proto", "arrow.left.arrow.right"),

        // Documentation
        ("README.md", "doc.richtext"),
        ("notes.txt", "doc.plaintext"),
        ("manual.pdf", "doc.richtext"),
        ("doc.rtf", "doc.richtext"),

        // Images
        ("photo.png", "photo"),
        ("photo.jpg", "photo"),
        ("photo.webp", "photo"),

        // Audio / Video
        ("song.mp3", "waveform"),
        ("clip.mp4", "film"),

        // Archives
        ("archive.zip", "doc.zipper"),
        ("backup.tar", "doc.zipper"),
        ("image.dmg", "doc.zipper"),

        // Fonts
        ("font.ttf", "textformat"),
        ("font.woff2", "textformat"),
    ])
    func fileExtension(name: String, expected: String) {
        #expect(FileIconMapper.iconForFile(name) == expected)
    }

    // MARK: - iconForFile — unknown extension falls back to "doc"

    @Test func fileUnknownExtension() {
        #expect(FileIconMapper.iconForFile("data.xyz") == "doc")
        #expect(FileIconMapper.iconForFile("noext") == "doc")
    }

    // MARK: - iconForFolder — project bundles

    @Test(arguments: [
        ("MyApp.xcodeproj", "hammer"),
        ("MyApp.xcworkspace", "hammer"),
    ])
    func folderProjectBundle(name: String, expected: String) {
        #expect(FileIconMapper.iconForFolder(name) == expected)
    }

    // MARK: - iconForFolder — build/dependency directories

    @Test(arguments: [
        ("node_modules", "folder.badge.gearshape"),
        ("packages", "folder.badge.gearshape"),
        (".build", "folder.badge.gearshape"),
        ("build", "folder.badge.gearshape"),
        ("dist", "folder.badge.gearshape"),
        ("output", "folder.badge.gearshape"),
        ("target", "folder.badge.gearshape"),
    ])
    func folderBuildDirs(name: String, expected: String) {
        #expect(FileIconMapper.iconForFolder(name) == expected)
    }

    // MARK: - iconForFolder — regular directories fall back to "folder"

    @Test func folderDefault() {
        #expect(FileIconMapper.iconForFolder("Sources") == "folder")
        #expect(FileIconMapper.iconForFolder("Tests") == "folder")
        #expect(FileIconMapper.iconForFolder("docs") == "folder")
        #expect(FileIconMapper.iconForFolder("my-feature") == "folder")
    }
}
