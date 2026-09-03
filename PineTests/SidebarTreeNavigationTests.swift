//
//  SidebarTreeNavigationTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Sidebar Finder-style keyboard navigation")
@MainActor
struct SidebarTreeNavigationTests {
    @Test("Visible rows respect expansion and carry outline depth")
    func visibleRowsRespectExpansion() throws {
        let root = try makeTree(
            files: [
                "alpha/child/nested.swift": "",
                "alpha/first.swift": "",
                "root.swift": "",
            ]
        )
        defer { removeTree(root) }

        let nodes = loadedRootNodes(root)
        let alpha = try requireNode("alpha", in: nodes)
        let child = try requireNode("child", in: alpha.children ?? [])
        let expansion = SidebarExpansionState()
        expansion.setExpanded(alpha.url, true)
        expansion.setExpanded(child.url, true)

        let rows = SidebarTreeFlattener.visibleRows(
            rootNodes: nodes,
            expansion: expansion
        )

        #expect(rows.map(\.node.name) == [
            "alpha", "child", "nested.swift", "first.swift", "root.swift",
        ])
        #expect(rows.map(\.depth) == [0, 1, 2, 1, 0])

        expansion.setExpanded(alpha.url, false)
        let collapsed = SidebarTreeFlattener.visibleRows(
            rootNodes: nodes,
            expansion: expansion
        )
        #expect(collapsed.map(\.node.name) == ["alpha", "root.swift"])
    }

    @Test("Up, Down, Home, and End clamp predictably")
    func linearNavigation() throws {
        let fixture = try flatFixture(names: ["a.swift", "b.swift", "c.swift"])
        defer { removeTree(fixture.root) }
        let navigation = SidebarTreeNavigation()

        #expect(navigation.moveDown(current: nil, rows: fixture.rows)?.name == "a.swift")
        #expect(navigation.moveUp(current: nil, rows: fixture.rows)?.name == "c.swift")
        #expect(navigation.moveDown(
            current: fixture.rows[2].node,
            rows: fixture.rows
        )?.name == "c.swift")
        #expect(navigation.moveUp(
            current: fixture.rows[0].node,
            rows: fixture.rows
        )?.name == "a.swift")
        #expect(navigation.firstRow(rows: fixture.rows)?.name == "a.swift")
        #expect(navigation.lastRow(rows: fixture.rows)?.name == "c.swift")
    }

    @Test("Page movement derives from viewport and clamps at both ends")
    func pageMovement() throws {
        let names = (0..<12).map { String(format: "%02d.swift", $0) }
        let fixture = try flatFixture(names: names)
        defer { removeTree(fixture.root) }
        let navigation = SidebarTreeNavigation()
        navigation.viewportHeight = Double(SidebarRowMetrics.minRowHeight * 4)

        #expect(navigation.estimatedPageSize == 4)
        #expect(navigation.pageDown(
            current: fixture.rows[1].node,
            rows: fixture.rows
        )?.name == "05.swift")
        #expect(navigation.pageUp(
            current: fixture.rows[5].node,
            rows: fixture.rows
        )?.name == "01.swift")
        #expect(navigation.pageDown(
            current: fixture.rows[10].node,
            rows: fixture.rows
        )?.name == "11.swift")
        #expect(navigation.pageUp(
            current: fixture.rows[1].node,
            rows: fixture.rows
        )?.name == "00.swift")
    }

    @Test("Left collapses or selects parent; Right expands or enters child")
    func disclosureAndParentNavigation() throws {
        let root = try makeTree(files: ["folder/child.swift": ""])
        defer { removeTree(root) }
        let nodes = loadedRootNodes(root)
        let folder = try requireNode("folder", in: nodes)
        let child = try requireNode("child.swift", in: folder.children ?? [])
        let expansion = SidebarExpansionState()
        let navigation = SidebarTreeNavigation()

        var rows = SidebarTreeFlattener.visibleRows(
            rootNodes: nodes,
            expansion: expansion
        )
        #expect(navigation.handleRightArrow(
            current: folder,
            rows: rows,
            expansion: expansion
        ) === folder)
        #expect(expansion.isExpanded(folder.url))

        rows = SidebarTreeFlattener.visibleRows(
            rootNodes: nodes,
            expansion: expansion
        )
        #expect(navigation.handleRightArrow(
            current: folder,
            rows: rows,
            expansion: expansion
        ) === child)
        #expect(navigation.handleLeftArrow(
            current: child,
            rows: rows,
            expansion: expansion
        ) === folder)
        #expect(navigation.handleLeftArrow(
            current: folder,
            rows: rows,
            expansion: expansion
        ) === folder)
        #expect(!expansion.isExpanded(folder.url))
        #expect(navigation.handleLeftArrow(
            current: folder,
            rows: rows,
            expansion: expansion
        ) == nil)
    }

    @Test("Pointer, keyboard, and accessibility disclosure share one transition")
    func sharedDisclosureTransition() throws {
        let root = try makeTree(files: [
            "file.swift": "",
            "folder/child.swift": "",
        ])
        defer { removeTree(root) }
        let nodes = loadedRootNodes(root)
        let folder = try requireNode("folder", in: nodes)
        let file = try requireNode("file.swift", in: nodes)
        let expansion = SidebarExpansionState()
        let navigation = SidebarTreeNavigation()

        #expect(navigation.setDisclosure(
            folder,
            expanded: true,
            expansion: expansion
        ))
        #expect(expansion.isExpanded(folder.url))
        #expect(navigation.toggleDisclosure(
            folder,
            expansion: expansion,
            debounced: false
        ) == false)
        #expect(!expansion.isExpanded(folder.url))
        #expect(!navigation.setDisclosure(
            file,
            expanded: true,
            expansion: expansion
        ))
        #expect(navigation.toggleDisclosure(
            file,
            expansion: expansion,
            debounced: false
        ) == nil)
        #expect(navigation.handleRightArrow(
            current: file,
            rows: visibleRows(nodes),
            expansion: expansion
        ) == nil)
        #expect(!expansion.isExpanded(file.url))
    }

    @Test("Type-select accepts punctuation, localized names, emoji, and diacritics")
    func localizedTypeSelection() throws {
        let fixture = try flatFixture(names: [
            "-flags", ".env", "_config", "Éclair.swift", "Бета.swift",
            "π-config", "東京.txt", "😀notes.md",
        ])
        defer { removeTree(fixture.root) }

        #expect(typeMatch(".", rows: fixture.rows) == ".env")
        #expect(typeMatch("_", rows: fixture.rows) == "_config")
        #expect(typeMatch("-", rows: fixture.rows) == "-flags")
        #expect(typeMatch("e", rows: fixture.rows) == "Éclair.swift")
        #expect(typeMatch("б", rows: fixture.rows) == "Бета.swift")
        #expect(typeMatch("π", rows: fixture.rows) == "π-config")
        #expect(typeMatch("東", rows: fixture.rows) == "東京.txt")
        #expect(typeMatch("😀", rows: fixture.rows) == "😀notes.md")
    }

    @Test("Repeated grapheme cycles and timeout starts a fresh prefix")
    func repeatedCharacterCyclingAndTimeout() throws {
        let fixture = try flatFixture(names: [
            "apple.swift", "apricot.swift", "banana.swift",
        ])
        defer { removeTree(fixture.root) }
        var typeAhead = SidebarTypeAhead()

        let firstResult = typeAhead.handle(
            character: "a",
            rows: fixture.rows,
            currentIndex: nil,
            now: 1
        )
        let first = try #require(firstResult)
        #expect(fixture.rows[first].node.name == "apple.swift")

        let secondResult = typeAhead.handle(
            character: "a",
            rows: fixture.rows,
            currentIndex: first,
            now: 1.1
        )
        let second = try #require(secondResult)
        #expect(fixture.rows[second].node.name == "apricot.swift")

        let bananaResult = typeAhead.handle(
            character: "b",
            rows: fixture.rows,
            currentIndex: second,
            now: 2
        )
        let banana = try #require(bananaResult)
        #expect(fixture.rows[banana].node.name == "banana.swift")
        #expect(typeAhead.buffer == "b")
    }

    @Test("Case-fold expansions still use repeated-grapheme cycling")
    func normalizationExpansionCycling() throws {
        let fixture = try flatFixture(names: ["ßeta-one.swift", "ßeta-two.swift"])
        defer { removeTree(fixture.root) }
        var typeAhead = SidebarTypeAhead()

        let firstResult = typeAhead.handle(
            character: "ß",
            rows: fixture.rows,
            currentIndex: nil,
            now: 1,
            locale: Locale(identifier: "de_DE")
        )
        let first = try #require(firstResult)
        let secondResult = typeAhead.handle(
            character: "ß",
            rows: fixture.rows,
            currentIndex: first,
            now: 1.1,
            locale: Locale(identifier: "de_DE")
        )
        let second = try #require(secondResult)

        #expect(first != second)
        #expect(fixture.rows[first].node.name.hasPrefix("ß"))
        #expect(fixture.rows[second].node.name.hasPrefix("ß"))
    }

    @Test("Clock rollback starts a fresh type-select sequence")
    func clockRollbackResetsTypeAhead() throws {
        let fixture = try flatFixture(names: ["abacus.swift", "beta.swift"])
        defer { removeTree(fixture.root) }
        var typeAhead = SidebarTypeAhead()

        let firstResult = typeAhead.handle(
            character: "a",
            rows: fixture.rows,
            currentIndex: nil,
            now: 2
        )
        let first = try #require(firstResult)
        let rollbackResult = typeAhead.handle(
            character: "b",
            rows: fixture.rows,
            currentIndex: first,
            now: 1
        )
        let rollback = try #require(rollbackResult)

        #expect(fixture.rows[rollback].node.name == "beta.swift")
        #expect(typeAhead.buffer == "b")
    }

    @Test("Empty trees keep selection and type-ahead empty")
    func emptyTreeNoOps() throws {
        let fixture = try flatFixture(names: ["alpha.swift"])
        defer { removeTree(fixture.root) }
        var typeAhead = SidebarTypeAhead()
        let navigation = SidebarTreeNavigation()

        #expect(typeAhead.handle(
            character: "a",
            rows: fixture.rows,
            currentIndex: nil,
            now: 0
        ) != nil)
        #expect(typeAhead.buffer == "a")
        #expect(typeAhead.handle(
            character: "a",
            rows: [],
            currentIndex: nil,
            now: 1
        ) == nil)
        #expect(typeAhead.buffer.isEmpty)
        #expect(navigation.moveDown(current: nil, rows: []) == nil)
        #expect(navigation.moveUp(current: nil, rows: []) == nil)
        #expect(navigation.firstRow(rows: []) == nil)
        #expect(navigation.lastRow(rows: []) == nil)
    }

    @Test("Prefix mismatch falls back to the newest printable grapheme")
    func prefixFallback() throws {
        let fixture = try flatFixture(names: ["alpha.swift", "zebra.swift"])
        defer { removeTree(fixture.root) }
        var typeAhead = SidebarTypeAhead()

        let alphaResult = typeAhead.handle(
            character: "a",
            rows: fixture.rows,
            currentIndex: nil,
            now: 1
        )
        let alpha = try #require(alphaResult)
        let zebraResult = typeAhead.handle(
            character: "z",
            rows: fixture.rows,
            currentIndex: alpha,
            now: 1.1
        )
        let zebra = try #require(zebraResult)

        #expect(fixture.rows[zebra].node.name == "zebra.swift")
        #expect(typeAhead.buffer == "z")
    }

    @Test("Reload rebinds equal paths to fresh FileNode identity")
    func reloadRestoresFreshIdentity() throws {
        let root = try makeTree(files: ["same.swift": "v1"])
        defer { removeTree(root) }
        let oldNode = try requireNode("same.swift", in: loadedRootNodes(root))
        let freshNodes = loadedRootNodes(root)
        let freshRows = visibleRows(freshNodes)
        let freshNode = try #require(freshRows.first?.node)
        let navigation = SidebarTreeNavigation()

        let restored = try #require(navigation.reconciledSelection(
            current: oldNode,
            rootNodes: freshNodes,
            rows: freshRows
        ))
        #expect(restored === freshNode)
        #expect(restored !== oldNode)
    }

    @Test("Shallow then full reload preserves the exact deep selection")
    func progressiveReloadPreservesDesiredSelection() throws {
        let root = try makeTree(files: [
            "folder/deep/selected.swift": "v1",
            "root.swift": "",
        ])
        defer { removeTree(root) }
        let oldNodes = loadedRootNodes(root)
        let oldFolder = try requireNode("folder", in: oldNodes)
        let oldDeep = try requireNode(
            "deep",
            in: oldFolder.children ?? []
        )
        let oldSelection = try requireNode(
            "selected.swift",
            in: oldDeep.children ?? []
        )
        let navigation = SidebarTreeNavigation()

        let shallow = FileNode.loadTree(
            url: root,
            projectRoot: root,
            ignoredPaths: [],
            maxDepth: 0
        )
        let shallowNodes = shallow.root.children ?? []
        let shallowSelection = try #require(
            navigation.reconciledSelection(
                current: oldSelection,
                rootNodes: shallowNodes,
                rows: visibleRows(shallowNodes)
            )
        )
        #expect(shallowSelection === oldSelection)

        let fullNodes = loadedRootNodes(root)
        let freshFolder = try requireNode("folder", in: fullNodes)
        let freshDeep = try requireNode(
            "deep",
            in: freshFolder.children ?? []
        )
        let freshSelection = try requireNode(
            "selected.swift",
            in: freshDeep.children ?? []
        )
        let restored = try #require(navigation.reconciledSelection(
            current: shallowSelection,
            rootNodes: fullNodes,
            rows: visibleRows(fullNodes)
        ))

        #expect(restored === freshSelection)
        #expect(restored !== oldSelection)
        #expect(restored.name == "selected.swift")
    }

    @Test("Disclosure navigation never returns stale pre-reload identity")
    func disclosureNavigationUsesVisibleIdentity() throws {
        let root = try makeTree(files: ["folder/child.swift": ""])
        defer { removeTree(root) }
        let staleNodes = loadedRootNodes(root)
        let staleFolder = try requireNode("folder", in: staleNodes)
        let freshNodes = loadedRootNodes(root)
        let freshFolder = try requireNode("folder", in: freshNodes)
        let freshChild = try requireNode(
            "child.swift",
            in: freshFolder.children ?? []
        )
        let expansion = SidebarExpansionState()
        let navigation = SidebarTreeNavigation()
        var rows = visibleRows(freshNodes)

        let expanded = try #require(navigation.handleRightArrow(
            current: staleFolder,
            rows: rows,
            expansion: expansion
        ))
        #expect(expanded === freshFolder)
        #expect(expanded !== staleFolder)

        rows = SidebarTreeFlattener.visibleRows(
            rootNodes: freshNodes,
            expansion: expansion
        )
        #expect(navigation.handleRightArrow(
            current: staleFolder,
            rows: rows,
            expansion: expansion
        ) === freshChild)
        #expect(navigation.handleLeftArrow(
            current: staleFolder,
            rows: rows,
            expansion: expansion
        ) === freshFolder)
    }

    @Test("Removal selects nearest visible ancestor or clears root selection")
    func removalReconciliation() throws {
        let root = try makeTree(files: [
            "folder/removed.swift": "",
            "root.swift": "",
        ])
        defer { removeTree(root) }
        let oldNodes = loadedRootNodes(root)
        let oldFolder = try requireNode("folder", in: oldNodes)
        let oldChild = try requireNode(
            "removed.swift",
            in: oldFolder.children ?? []
        )
        let oldRootFile = try requireNode("root.swift", in: oldNodes)

        try FileManager.default.removeItem(at: oldChild.url)
        try FileManager.default.removeItem(at: oldRootFile.url)
        let freshNodes = loadedRootNodes(root)
        let freshFolder = try requireNode("folder", in: freshNodes)
        let expansion = SidebarExpansionState()
        expansion.setExpanded(freshFolder.url, true)
        let freshRows = SidebarTreeFlattener.visibleRows(
            rootNodes: freshNodes,
            expansion: expansion
        )
        let navigation = SidebarTreeNavigation()

        #expect(navigation.reconciledSelection(
            current: oldChild,
            rootNodes: freshNodes,
            rows: freshRows
        ) === freshFolder)
        #expect(navigation.reconciledSelection(
            current: oldRootFile,
            rootNodes: freshNodes,
            rows: freshRows
        ) == nil)
    }

    @Test("Tree membership includes loaded descendants hidden by collapse")
    func membershipIncludesCollapsedDescendants() throws {
        let root = try makeTree(files: ["folder/child.swift": ""])
        defer { removeTree(root) }
        let nodes = loadedRootNodes(root)
        let folder = try requireNode("folder", in: nodes)
        let child = try requireNode("child.swift", in: folder.children ?? [])

        #expect(SidebarTreeFlattener.contains(child.url, rootNodes: nodes))
        #expect(!SidebarTreeFlattener.contains(
            root.appendingPathComponent("missing.swift"),
            rootNodes: nodes
        ))
    }

    @Test("Lexical identity normalizes trailing slashes without resolving links")
    func lexicalPathIdentityPreservesSymlinkSpelling() throws {
        let root = try makeTree(files: ["target/file.swift": ""])
        defer { removeTree(root) }
        let target = root.appendingPathComponent(
            "target",
            isDirectory: true
        )
        let link = root.appendingPathComponent(
            "linked-target",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        let linkWithTrailingSlash = URL(
            fileURLWithPath: link.path + "/",
            isDirectory: true
        )
        #expect(
            SidebarPathIdentity(link)
                == SidebarPathIdentity(linkWithTrailingSlash)
        )
        // A lexical key deliberately does not resolve the link on every
        // keyboard event; fresh nodes loaded through the same spelling remain
        // stable, while the physical target stays a distinct identity.
        #expect(SidebarPathIdentity(link) != SidebarPathIdentity(target))
    }

    @Test("Lexical identity canonicalizes Darwin root compatibility aliases")
    func lexicalIdentityCanonicalizesDarwinRootAliases() {
        for alias in ["var", "tmp", "etc"] {
            let compatibilityPath = URL(
                fileURLWithPath: "/\(alias)/pine/project"
            )
            let privatePath = URL(
                fileURLWithPath: "/private/\(alias)/pine/project"
            )
            #expect(
                SidebarPathIdentity(compatibilityPath)
                    == SidebarPathIdentity(privatePath)
            )
        }

        #expect(
            SidebarPathIdentity(URL(fileURLWithPath: "/variant/project"))
                != SidebarPathIdentity(
                    URL(fileURLWithPath: "/private/variant/project")
                )
        )
    }

    @Test("Deferred subtrees keep pending edits alive until the full reload")
    func membershipTreatsDeferredDescendantsAsIndeterminate() throws {
        let root = try makeTree(files: [
            "folder/deep/existing.swift": "",
            "root.swift": "",
        ])
        defer { removeTree(root) }
        let shallow = FileNode.loadTree(
            url: root,
            projectRoot: root,
            ignoredPaths: [],
            maxDepth: 0
        )
        let nodes = shallow.root.children ?? []
        let folder = try requireNode("folder", in: nodes)
        let pendingURL = folder.url
            .appendingPathComponent("deep")
            .appendingPathComponent("pending.swift")

        #expect(folder.hasDeferredChildren)
        #expect(folder.url.absoluteString.hasSuffix("/"))
        #expect(SidebarTreeFlattener.contains(
            pendingURL,
            rootNodes: nodes
        ))
        let siblingURL = folder.url
            .deletingLastPathComponent()
            .appendingPathComponent("folder2")
            .appendingPathComponent("pending.swift")
        #expect(!SidebarTreeFlattener.contains(
            siblingURL,
            rootNodes: [folder]
        ))

        let fullNodes = loadedRootNodes(root)
        #expect(!SidebarTreeFlattener.contains(
            pendingURL,
            rootNodes: fullNodes
        ))
    }

    @Test("Scroll callback receives the selected row identity")
    func scrollCallback() throws {
        let fixture = try flatFixture(names: ["target.swift"])
        defer { removeTree(fixture.root) }
        let node = try #require(fixture.rows.first?.node)
        let navigation = SidebarTreeNavigation()
        var request: SidebarScrollRequest?
        navigation.scrollToNode = { request = $0 }

        navigation.scroll(to: node)

        #expect(request == SidebarScrollRequest(
            id: node.url,
            alignment: .nearestEdge,
            motion: .immediate
        ))
    }

    @Test("Intentional centered reveal honors Reduce Motion")
    func centeredRevealMotionPolicy() {
        #expect(
            SidebarScrollRequest.intentionalReveal(
                URL(fileURLWithPath: "/tmp/new.swift"),
                reduceMotion: false
            ) == SidebarScrollRequest(
                id: URL(fileURLWithPath: "/tmp/new.swift"),
                alignment: .center,
                motion: .animated
            )
        )
        #expect(
            SidebarScrollRequest.intentionalReveal(
                URL(fileURLWithPath: "/tmp/new.swift"),
                reduceMotion: true
            ) == SidebarScrollRequest(
                id: URL(fileURLWithPath: "/tmp/new.swift"),
                alignment: .center,
                motion: .immediate
            )
        )
    }

    @Test("Return and Tab accept only their exact modifier contracts")
    func exactModifierPolicies() {
        #expect(SidebarReturnAction.accepts(modifiers: []))
        #expect(SidebarReturnAction.accepts(modifiers: [.command]))
        #expect(!SidebarReturnAction.accepts(
            modifiers: [.command, .option]
        ))
        #expect(SidebarReturnAction.resolve(
            modifiers: [],
            isRenaming: false,
            selectedIsDirectory: false
        ) == .rename)
        #expect(SidebarReturnAction.resolve(
            modifiers: [.command],
            isRenaming: false,
            selectedIsDirectory: false
        ) == .open)
        #expect(SidebarReturnAction.resolve(
            modifiers: [.command],
            isRenaming: false,
            selectedIsDirectory: true
        ) == nil)
        for modifiers: SidebarKeyboardModifiers in [
            [.option],
            [.control],
            [.shift],
            [.command, .option],
            [.command, .control],
            [.command, .shift],
        ] {
            #expect(SidebarReturnAction.resolve(
                modifiers: modifiers,
                isRenaming: false,
                selectedIsDirectory: false
            ) == nil)
        }
        #expect(SidebarReturnAction.resolve(
            modifiers: [],
            isRenaming: true,
            selectedIsDirectory: false
        ) == nil)
        #expect(SidebarReturnAction.resolve(
            modifiers: [.command],
            isRenaming: true,
            selectedIsDirectory: false
        ) == nil)

        #expect(SidebarSpaceAction.accepts(modifiers: []))
        for modifiers: SidebarKeyboardModifiers in [
            [.command],
            [.control],
            [.option],
            [.shift],
        ] {
            #expect(!SidebarSpaceAction.accepts(
                modifiers: modifiers
            ))
        }

        #expect(
            SidebarTabTraversalDirection.resolve(modifiers: []) == .next
        )
        #expect(
            SidebarTabTraversalDirection.resolve(modifiers: [.shift])
                == .previous
        )
        for modifiers: SidebarKeyboardModifiers in [
            [.command],
            [.control],
            [.option],
            [.command, .shift],
            [.control, .shift],
            [.option, .shift],
        ] {
            #expect(
                SidebarTabTraversalDirection.resolve(modifiers: modifiers)
                    == nil
            )
        }
    }

    @Test("Printable classifier preserves shortcuts and special keys")
    func printableInputClassification() {
        for accepted in ["a", "É", ".", "_", "-", "東", "😀", "👨‍👩‍👧‍👦"] {
            #expect(SidebarTypeSelectInput.printableCharacter(
                from: accepted,
                modifiers: []
            ) == accepted)
        }
        #expect(SidebarTypeSelectInput.printableCharacter(
            from: "A",
            modifiers: [.shift]
        ) == "A")

        let rejected = [
            " ", "\t", "\n", "\r", "\u{1B}", "\u{7F}", "\u{0301}",
            "\u{200B}", "\u{200D}", "\u{F700}", "\u{FE0F}",
        ]
        for input in rejected {
            #expect(SidebarTypeSelectInput.printableCharacter(
                from: input,
                modifiers: []
            ) == nil)
        }
        #expect(SidebarTypeSelectInput.printableCharacter(
            from: "p",
            modifiers: [.command]
        ) == nil)
        #expect(SidebarTypeSelectInput.printableCharacter(
            from: "r",
            modifiers: [.control]
        ) == nil)
        #expect(SidebarTypeSelectInput.printableCharacter(
            from: "π",
            modifiers: [.option]
        ) == "π")
        #expect(SidebarTypeSelectInput.printableCharacter(
            from: "ab",
            modifiers: []
        ) == nil)
        #expect(SidebarTypeSelectInput.printableCharacter(
            from: "",
            modifiers: []
        ) == nil)
        #expect(SidebarTypeSelectInput.printableCharacter(
            from: nil,
            modifiers: []
        ) == nil)
        #expect(SidebarTypeSelectInput.printableCharacter(
            from: "P",
            modifiers: [.command, .shift]
        ) == nil)
    }

    // MARK: - Live keyboard selection (#1544)

    @Test("Left collapses the live mirrored selection, not a stale snapshot")
    func leftArrowCollapsesLiveSelectionMirror() throws {
        let root = try makeTree(files: [
            "alpha/inside-alpha.swift": "",
            "root-file.swift": "",
        ])
        defer { removeTree(root) }

        let nodes = loadedRootNodes(root)
        let alpha = try requireNode("alpha", in: nodes)
        let expansion = SidebarExpansionState()
        expansion.setExpanded(alpha.url, true)
        let rows = SidebarTreeFlattener.visibleRows(
            rootNodes: nodes,
            expansion: expansion
        )
        let navigation = SidebarTreeNavigation()

        // A pointer click on the folder expands it and writes the live
        // mirror synchronously — this is what `SidebarView.mirroredSelection`
        // does inside the row binding's setter.
        navigation.currentSelection = alpha

        // The stale-epoch failure mode of #1544: the key handler read its
        // captured binding snapshot, which was still nil at dispatch time,
        // and the collapse silently vanished. (`rows` is a snapshot taken
        // before any collapse below, so both calls flatten the same tree.)
        #expect(
            navigation.handleLeftArrow(
                current: nil,
                rows: rows,
                expansion: expansion
            ) == nil,
            "A stale nil snapshot cannot collapse anything"
        )

        // The keyboard path now reads the live model, so the collapse lands
        // and the selection stays on the folder.
        let target = navigation.handleLeftArrow(
            current: navigation.currentSelection,
            rows: rows,
            expansion: expansion
        )
        #expect(target === alpha)
        #expect(!expansion.isExpanded(alpha.url))
    }

    @Test("The live selection mirror starts empty and tracks writes verbatim")
    func currentSelectionMirrorLifecycle() throws {
        let navigation = SidebarTreeNavigation()
        #expect(navigation.currentSelection == nil)

        let root = try makeTree(files: ["a.swift": ""])
        defer { removeTree(root) }
        let node = try requireNode("a.swift", in: loadedRootNodes(root))

        navigation.currentSelection = node
        #expect(navigation.currentSelection === node)

        navigation.currentSelection = nil
        #expect(navigation.currentSelection == nil)
    }

    // MARK: - Fixtures

    private func typeMatch(
        _ character: String,
        rows: [SidebarVisibleRow]
    ) -> String? {
        var typeAhead = SidebarTypeAhead()
        guard let index = typeAhead.handle(
            character: character,
            rows: rows,
            currentIndex: nil,
            now: 1
        ) else {
            return nil
        }
        return rows[index].node.name
    }

    private func flatFixture(names: [String]) throws -> (
        root: URL,
        rows: [SidebarVisibleRow]
    ) {
        let files = Dictionary(uniqueKeysWithValues: names.map { ($0, "") })
        let root = try makeTree(files: files)
        return (root, visibleRows(loadedRootNodes(root)))
    }

    private func visibleRows(_ nodes: [FileNode]) -> [SidebarVisibleRow] {
        SidebarTreeFlattener.visibleRows(
            rootNodes: nodes,
            expansion: SidebarExpansionState()
        )
    }

    private func loadedRootNodes(_ root: URL) -> [FileNode] {
        FileNode(url: root).children ?? []
    }

    private func requireNode(
        _ name: String,
        in nodes: [FileNode]
    ) throws -> FileNode {
        try #require(nodes.first { $0.name == name })
    }

    private func makeTree(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-sidebar-navigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func removeTree(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }
}
