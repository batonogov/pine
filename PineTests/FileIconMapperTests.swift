//
//  FileIconMapperTests.swift
//  PineTests
//

import SwiftUI
import Testing
@testable import Pine

struct FileIconMapperTests {

    // MARK: - iconForFile — exact filename matches

    @Test(arguments: [
        ("Dockerfile", "shippingbox"),
        ("Containerfile", "shippingbox"),
        (".dockerignore", "shippingbox"),
        ("Makefile", "hammer"),
        ("CMakeLists.txt", "hammer"),
        (".gitignore", "arrow.triangle.branch"),
        (".gitattributes", "arrow.triangle.branch"),
        (".env", "lock.shield"),
        (".env.local", "lock.shield"),
        (".env.production", "lock.shield"),
        (".env.staging", "lock.shield"),
        ("LICENSE", "doc.text.magnifyingglass"),
        ("licence", "doc.text.magnifyingglass"),
        ("package.json", "shippingbox"),
        ("package-lock.json", "shippingbox"),
        ("Cargo.toml", "shippingbox"),
        ("go.mod", "shippingbox"),
        ("Podfile", "shippingbox"),
        ("Podfile.lock", "shippingbox"),
        ("Gemfile", "shippingbox"),
        ("yarn.lock", "shippingbox"),
        ("requirements.txt", "doc.plaintext"),
        ("setup.py", "terminal"),
    ])
    func fileExactName(name: String, expected: String) {
        #expect(FileIconMapper.iconForFile(name) == expected)
    }

    // MARK: - iconForFile — extension-based matches

    @Test(arguments: [
        // Apple / Swift
        ("main.swift", "swift"),
        ("Info.plist", "list.bullet.rectangle"),
        ("App.entitlements", "list.bullet.rectangle"),
        ("Main.storyboard", "rectangle.on.rectangle"),
        ("View.xib", "rectangle.on.rectangle"),

        // Web
        ("app.js", "curlybraces.square"),
        ("index.mjs", "curlybraces.square"),
        ("worker.cjs", "curlybraces.square"),
        ("index.ts", "curlybraces.square"),
        ("types.mts", "curlybraces.square"),
        ("lib.cts", "curlybraces.square"),
        ("App.jsx", "curlybraces.square"),
        ("App.tsx", "curlybraces.square"),
        ("index.html", "globe"),
        ("page.htm", "globe"),
        ("style.css", "paintbrush"),
        ("style.scss", "paintbrush"),
        ("style.sass", "paintbrush"),
        ("style.less", "paintbrush"),
        ("App.vue", "curlybraces.square"),
        ("App.svelte", "curlybraces.square"),

        // Data / Config
        ("data.json", "curlybraces"),
        ("tsconfig.jsonc", "curlybraces"),
        ("config.yaml", "list.dash"),
        ("settings.yml", "list.dash"),
        ("config.toml", "gearshape"),
        ("config.ini", "gearshape"),
        ("app.cfg", "gearshape"),
        ("nginx.conf", "gearshape"),
        ("layout.xml", "chevron.left.forwardslash.chevron.right"),
        ("icon.svg", "chevron.left.forwardslash.chevron.right"),
        ("schema.graphql", "point.3.connected.trianglepath.dotted"),
        ("query.gql", "point.3.connected.trianglepath.dotted"),

        // Scripting / Systems
        ("main.py", "terminal"),
        ("script.pyw", "terminal"),
        ("script.rb", "terminal"),
        ("run.sh", "terminal"),
        ("run.bash", "terminal"),
        ("init.zsh", "terminal"),
        ("config.fish", "terminal"),
        ("main.go", "chevron.left.forwardslash.chevron.right"),
        ("main.rs", "gearshape.2"),
        ("main.c", "c.square"),
        ("header.h", "c.square"),
        ("main.cpp", "c.square"),
        ("lib.cc", "c.square"),
        ("impl.cxx", "c.square"),
        ("types.hpp", "c.square"),
        ("App.java", "cup.and.saucer"),
        ("App.kt", "cup.and.saucer"),
        ("build.kts", "cup.and.saucer"),
        ("Program.cs", "number.square"),
        ("init.lua", "moon"),
        ("analysis.r", "chart.bar"),
        ("query.sql", "tablecells"),
        ("msg.proto", "arrow.left.arrow.right"),

        // Documentation
        ("README.md", "doc.richtext"),
        ("guide.markdown", "doc.richtext"),
        ("index.rst", "doc.richtext"),
        ("notes.txt", "doc.plaintext"),
        ("readme.text", "doc.plaintext"),
        ("manual.pdf", "doc.richtext"),
        ("doc.rtf", "doc.richtext"),

        // Images
        ("photo.png", "photo"),
        ("photo.jpg", "photo"),
        ("photo.jpeg", "photo"),
        ("anim.gif", "photo"),
        ("scan.bmp", "photo"),
        ("scan.tiff", "photo"),
        ("photo.webp", "photo"),
        ("favicon.ico", "photo"),
        ("photo.heic", "photo"),

        // Audio / Video
        ("song.mp3", "waveform"),
        ("audio.wav", "waveform"),
        ("track.aac", "waveform"),
        ("album.flac", "waveform"),
        ("sound.ogg", "waveform"),
        ("ring.m4a", "waveform"),
        ("clip.mp4", "film"),
        ("video.mov", "film"),
        ("movie.avi", "film"),
        ("show.mkv", "film"),
        ("stream.webm", "film"),

        // Archives
        ("archive.zip", "doc.zipper"),
        ("backup.tar", "doc.zipper"),
        ("data.gz", "doc.zipper"),
        ("data.bz2", "doc.zipper"),
        ("data.xz", "doc.zipper"),
        ("files.rar", "doc.zipper"),
        ("files.7z", "doc.zipper"),
        ("image.dmg", "doc.zipper"),

        // Fonts
        ("font.ttf", "textformat"),
        ("font.otf", "textformat"),
        ("font.woff", "textformat"),
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

    // MARK: - colorForFile — exact filename matches

    @Test func fileColorDockerfiles() {
        #expect(FileIconMapper.colorForFile("Dockerfile") == .blue)
        #expect(FileIconMapper.colorForFile("Containerfile") == .blue)
        #expect(FileIconMapper.colorForFile(".dockerignore") == .secondary)
    }

    @Test func fileColorBuildTools() {
        #expect(FileIconMapper.colorForFile("Makefile") == .green)
        #expect(FileIconMapper.colorForFile("CMakeLists.txt") == .green)
    }

    @Test func fileColorGitFiles() {
        #expect(FileIconMapper.colorForFile(".gitignore") == .orange)
        #expect(FileIconMapper.colorForFile(".gitattributes") == .orange)
    }

    @Test func fileColorEnvFiles() {
        #expect(FileIconMapper.colorForFile(".env") == .yellow)
        #expect(FileIconMapper.colorForFile(".env.local") == .yellow)
        #expect(FileIconMapper.colorForFile(".env.production") == .yellow)
        #expect(FileIconMapper.colorForFile(".env.staging") == .yellow)
    }

    @Test func fileColorLicense() {
        #expect(FileIconMapper.colorForFile("LICENSE") == .secondary)
        #expect(FileIconMapper.colorForFile("licence") == .secondary)
    }

    @Test func fileColorPackageManagers() {
        #expect(FileIconMapper.colorForFile("package.json") == .green)
        #expect(FileIconMapper.colorForFile("package-lock.json") == .green)
        #expect(FileIconMapper.colorForFile("Podfile") == .red)
        #expect(FileIconMapper.colorForFile("Podfile.lock") == .red)
        #expect(FileIconMapper.colorForFile("yarn.lock") == .blue)
        #expect(FileIconMapper.colorForFile("requirements.txt") == .blue)
        #expect(FileIconMapper.colorForFile("setup.py") == .blue)
        #expect(FileIconMapper.colorForFile("Cargo.toml") == .secondary)
        #expect(FileIconMapper.colorForFile("go.mod") == .secondary)
        #expect(FileIconMapper.colorForFile("Gemfile") == .secondary)
    }

    // MARK: - colorForFile — Swift / Apple

    @Test func fileColorSwift() {
        #expect(FileIconMapper.colorForFile("main.swift") == .orange)
    }

    // MARK: - colorForFile — Web languages

    @Test func fileColorWeb() {
        #expect(FileIconMapper.colorForFile("app.js") == .yellow)
        #expect(FileIconMapper.colorForFile("index.ts") == .blue)
        #expect(FileIconMapper.colorForFile("App.jsx") == .cyan)
        #expect(FileIconMapper.colorForFile("index.html") == .orange)
        #expect(FileIconMapper.colorForFile("style.css") == .purple)
        #expect(FileIconMapper.colorForFile("App.vue") == .green)
    }

    // MARK: - colorForFile — Data / Config

    @Test func fileColorDataConfig() {
        #expect(FileIconMapper.colorForFile("data.json") == .yellow)
        #expect(FileIconMapper.colorForFile("config.yaml") == .red)
    }

    // MARK: - colorForFile — Scripting / Systems

    @Test func fileColorScripting() {
        #expect(FileIconMapper.colorForFile("main.py") == .blue)
        #expect(FileIconMapper.colorForFile("script.rb") == .red)
        #expect(FileIconMapper.colorForFile("run.sh") == .green)
        #expect(FileIconMapper.colorForFile("main.go") == .cyan)
        #expect(FileIconMapper.colorForFile("main.rs") == .orange)
        #expect(FileIconMapper.colorForFile("main.c") == .blue)
        #expect(FileIconMapper.colorForFile("App.java") == .red)
        #expect(FileIconMapper.colorForFile("Program.cs") == .purple)
    }

    // MARK: - colorForFile — Documentation / Media / Archives

    @Test func fileColorDocMediaArchive() {
        #expect(FileIconMapper.colorForFile("README.md") == .blue)
        #expect(FileIconMapper.colorForFile("photo.png") == .green)
        #expect(FileIconMapper.colorForFile("song.mp3") == .purple)
        #expect(FileIconMapper.colorForFile("clip.mp4") == .pink)
        #expect(FileIconMapper.colorForFile("archive.zip") == .brown)
        #expect(FileIconMapper.colorForFile("font.ttf") == .red)
    }

    // MARK: - colorForFile — unknown extension falls back to .secondary

    @Test func fileColorUnknownExtension() {
        #expect(FileIconMapper.colorForFile("data.xyz") == .secondary)
        #expect(FileIconMapper.colorForFile("noext") == .secondary)
    }

    // MARK: - colorForFolder

    @Test func folderColorXcodeProject() {
        #expect(FileIconMapper.colorForFolder("App.xcodeproj") == .blue)
        #expect(FileIconMapper.colorForFolder("App.xcworkspace") == .blue)
    }

    @Test func folderColorBuildDirs() {
        #expect(FileIconMapper.colorForFolder("node_modules") == .secondary)
        #expect(FileIconMapper.colorForFolder("build") == .secondary)
        #expect(FileIconMapper.colorForFolder("dist") == .secondary)
    }

    @Test func folderColorDefault() {
        #expect(FileIconMapper.colorForFolder("Sources") == .blue)
        #expect(FileIconMapper.colorForFolder("Tests") == .blue)
    }
}
