//
//  FileIconMapper.swift
//  Pine
//

import Foundation
import SwiftUI

enum FileIconMapper {

    /// Returns a tint color for the file type icon based on file extension.
    static func colorForFile(_ name: String) -> Color {
        let lowered = name.lowercased()

        // .env variants (hasPrefix covers .env, .env.local, .env.production, etc.)
        if lowered.hasPrefix(".env") {
            return .yellow
        }

        // Exact filename matches
        switch lowered {
        case "dockerfile", "containerfile":    return .blue
        case ".dockerignore":                  return .secondary
        case "makefile":                       return .green
        case "cmakelists.txt":                 return .green
        case ".gitignore", ".gitattributes":   return .orange
        case "license", "licence":             return .secondary
        case "package.json", "package-lock.json": return .green
        case "cargo.toml", "go.mod":           return .secondary
        case "podfile", "podfile.lock":        return .red
        case "gemfile":                        return .secondary
        case "yarn.lock":                      return .blue
        case "requirements.txt":               return .blue
        case "setup.py":                       return .blue
        default: break
        }

        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        // Apple / Swift
        case "swift":                          return .orange
        case "plist", "entitlements":          return .secondary
        case "storyboard", "xib":             return .blue

        // Web
        case "js", "mjs", "cjs":              return .yellow
        case "ts", "mts", "cts":              return .blue
        case "jsx", "tsx":                     return .cyan
        case "html", "htm":                    return .orange
        case "css", "scss", "sass", "less":   return .purple
        case "vue", "svelte":                  return .green

        // Data / Config
        case "json", "jsonc":                  return .yellow
        case "yaml", "yml":                    return .red
        case "toml", "ini", "cfg", "conf":    return .secondary
        case "xml", "svg":                     return .orange
        case "graphql", "gql":                 return .pink

        // Scripting / Systems
        case "py", "pyw":                      return .blue
        case "rb":                             return .red
        case "sh", "bash", "zsh", "fish":     return .green
        case "go":                             return .cyan
        case "rs":                             return .orange
        case "c", "h":                         return .blue
        case "cpp", "cc", "cxx", "hpp":       return .blue
        case "java", "kt", "kts":             return .red
        case "cs":                             return .purple
        case "lua":                            return .blue
        case "r":                              return .blue
        case "sql":                            return .yellow
        case "proto":                          return .secondary

        // Documentation
        case "md", "markdown", "rst":          return .blue
        case "txt", "text":                    return .secondary
        case "pdf":                            return .red
        case "rtf":                            return .secondary

        // Images
        case "png", "jpg", "jpeg", "gif",
             "bmp", "tiff", "webp", "ico",
             "heic":                           return .green

        // Audio / Video
        case "mp3", "wav", "aac", "flac",
             "ogg", "m4a":                     return .purple
        case "mp4", "mov", "avi", "mkv",
             "webm":                           return .pink

        // Archives
        case "zip", "tar", "gz", "bz2",
             "xz", "rar", "7z", "dmg":        return .brown

        // Fonts
        case "ttf", "otf", "woff", "woff2":  return .red

        default:                               return .secondary
        }
    }

    /// Returns a tint color for the folder icon.
    static func colorForFolder(_ name: String) -> Color {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "xcodeproj", "xcworkspace":       return .blue
        default: break
        }

        let lowered = name.lowercased()
        switch lowered {
        case "node_modules", "packages",
             ".build", "build", "dist",
             "output", "target":               return .secondary
        default:                               return .blue
        }
    }

    /// Returns an SF Symbol name for the given file name.
    static func iconForFile(_ name: String) -> String {
        let lowered = name.lowercased()

        // .env variants (hasPrefix covers .env, .env.local, .env.production, etc.)
        if lowered.hasPrefix(".env") {
            return "lock.shield"
        }

        // Exact filename matches
        switch lowered {
        case "dockerfile", "containerfile":    return "shippingbox"
        case ".dockerignore":                  return "shippingbox"
        case "makefile", "cmakelists.txt":     return "hammer"
        case ".gitignore", ".gitattributes":   return "arrow.triangle.branch"
        case "license", "licence":             return "doc.text.magnifyingglass"
        case "package.json", "package-lock.json",
             "cargo.toml", "go.mod",
             "podfile", "podfile.lock",
             "gemfile":                        return "shippingbox"
        case "yarn.lock":                      return "shippingbox"
        case "requirements.txt":               return "doc.plaintext"
        case "setup.py":                       return "terminal"
        default: break
        }

        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        // Apple / Swift
        case "swift":                          return "swift"
        case "plist", "entitlements":          return "list.bullet.rectangle"
        case "storyboard", "xib":             return "rectangle.on.rectangle"

        // Web
        case "js", "mjs", "cjs":              return "curlybraces.square"
        case "ts", "mts", "cts":              return "curlybraces.square"
        case "jsx", "tsx":                     return "curlybraces.square"
        case "html", "htm":                    return "globe"
        case "css", "scss", "sass", "less":   return "paintbrush"
        case "vue", "svelte":                  return "curlybraces.square"

        // Data / Config
        case "json", "jsonc":                  return "curlybraces"
        case "yaml", "yml":                    return "list.dash"
        case "toml", "ini", "cfg", "conf":    return "gearshape"
        case "xml", "svg":                     return "chevron.left.forwardslash.chevron.right"
        case "graphql", "gql":                 return "point.3.connected.trianglepath.dotted"

        // Scripting / Systems
        case "py", "pyw":                      return "terminal"
        case "rb":                             return "terminal"
        case "sh", "bash", "zsh", "fish":     return "terminal"
        case "go":                             return "chevron.left.forwardslash.chevron.right"
        case "rs":                             return "gearshape.2"
        case "c", "h":                         return "c.square"
        case "cpp", "cc", "cxx", "hpp":       return "c.square"
        case "java", "kt", "kts":             return "cup.and.saucer"
        case "cs":                             return "number.square"
        case "lua":                            return "moon"
        case "r":                              return "chart.bar"
        case "sql":                            return "tablecells"
        case "proto":                          return "arrow.left.arrow.right"

        // Documentation
        case "md", "markdown", "rst":          return "doc.richtext"
        case "txt", "text":                    return "doc.plaintext"
        case "pdf":                            return "doc.richtext"
        case "rtf":                            return "doc.richtext"

        // Images
        case "png", "jpg", "jpeg", "gif",
             "bmp", "tiff", "webp", "ico",
             "heic":                           return "photo"

        // Audio / Video
        case "mp3", "wav", "aac", "flac",
             "ogg", "m4a":                     return "waveform"
        case "mp4", "mov", "avi", "mkv",
             "webm":                           return "film"

        // Archives
        case "zip", "tar", "gz", "bz2",
             "xz", "rar", "7z", "dmg":        return "doc.zipper"

        // Fonts
        case "ttf", "otf", "woff", "woff2":  return "textformat"

        default:                               return "doc"
        }
    }

    /// Returns an SF Symbol name for the given folder name.
    static func iconForFolder(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "xcodeproj", "xcworkspace":       return "hammer"
        default: break
        }

        let lowered = name.lowercased()
        switch lowered {
        case "node_modules", "packages",
             ".build", "build", "dist",
             "output", "target":               return "folder.badge.gearshape"
        default:                               return "folder"
        }
    }
}
