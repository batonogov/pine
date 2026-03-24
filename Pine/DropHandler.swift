//
//  DropHandler.swift
//  Pine
//
//  Created by Claude on 24.03.2026.
//

import Foundation
import UniformTypeIdentifiers

/// Pure-logic handler for drag & drop operations.
/// Classifies dropped URLs into files and directories and performs the appropriate action.
enum DropHandler {

    /// Result of classifying a set of URLs into files and directories.
    struct ClassifiedURLs {
        let files: [URL]
        let directories: [URL]
    }

    /// Classifies URLs into files and directories, ignoring nonexistent paths.
    static func classifyURLs(_ urls: [URL]) -> ClassifiedURLs {
        var files: [URL] = []
        var directories: [URL] = []
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                directories.append(url)
            } else {
                files.append(url)
            }
        }

        return ClassifiedURLs(files: files, directories: directories)
    }

    /// Returns true if the drop should open a new project window (i.e., contains directories).
    static func shouldOpenAsProject(_ classified: ClassifiedURLs) -> Bool {
        !classified.directories.isEmpty
    }

    /// Opens files as tabs in the given TabManager.
    static func openFilesAsTabs(_ files: [URL], in tabManager: TabManager) {
        for file in files {
            tabManager.openTab(url: file)
        }
    }
}
