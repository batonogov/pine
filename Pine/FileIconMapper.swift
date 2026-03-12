//
//  FileIconMapper.swift
//  Pine
//

import Foundation

enum FileIconMapper {

    /// Returns an SF Symbol name for the given file name.
    static func iconForFile(_ name: String) -> String {
        let lowered = name.lowercased()

        // Exact filename matches
        switch lowered {
        case "dockerfile", "containerfile":    return "shippingbox"
        case "makefile", "cmakelists.txt":     return "hammer"
        case ".gitignore", ".gitattributes":   return "arrow.triangle.branch"
        case ".env", ".env.local":             return "lock.shield"
        case "license", "licence":             return "doc.text.magnifyingglass"
        case "package.json", "package-lock.json",
             "cargo.toml", "go.mod",
             "podfile", "gemfile":             return "shippingbox"
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
