//
//  ProjectDisplayNames.swift
//  Pine
//
//  Telling apart project roots that share a folder name.
//

import Foundation

/// Names for a set of project roots, each shortened to the fewest trailing
/// path components that still tell it apart from every other root in the set.
///
/// A folder name alone stops identifying a project the moment one window holds
/// two of them: `project1/infra` and `project2/infra` both reach the switcher
/// as `infra`, and picking one becomes guesswork. Spelling out whole paths
/// fixes that and costs far more than it buys — the common prefix repeats on
/// every row, crowding out the one component that actually differs.
///
/// So each root grows only as far as it has to. A name nothing collides with
/// stays a bare folder name; colliding names take one parent at a time until
/// they read differently. In a window holding `pine`, `project1/infra`,
/// `project2/infra` and `project1/backend`, only the two `infra` roots carry a
/// parent — `pine` and `backend` are already unambiguous and stay short.
///
/// A root that runs out of components without separating — it is the ancestor
/// of another entry, so every component it has is shared — falls back to its
/// absolute path, which is both unambiguous and visibly different in kind.
nonisolated enum ProjectDisplayNames {
    /// Separator between path components. Not localized: it is filesystem
    /// syntax, and the strings it joins are literal directory names.
    private static let separator = "/"

    /// Shown when a URL has no nameable component — the filesystem root.
    private static let rootName = "/"

    /// Display names keyed by the standardized form of each input URL.
    ///
    /// Look results up with ``URL/standardizedFileURL``; callers holding
    /// already-standardized URLs — the window session stores them that way —
    /// can subscript directly.
    static func resolve(for urls: [URL]) -> [URL: String] {
        var components: [URL: [String]] = [:]
        var depths: [URL: Int] = [:]
        for url in urls {
            let standardized = url.standardizedFileURL
            components[standardized] = nameableComponents(of: standardized)
            depths[standardized] = 1
        }

        // Grow every colliding root by one parent, then re-check: a parent can
        // itself be shared, so `a/x/infra` versus `b/x/infra` only separates at
        // the third component. Depth rises monotonically and is capped at the
        // component count, so this terminates even for two identical entries,
        // which can never separate.
        var didGrow = true
        while didGrow {
            didGrow = false
            var buckets: [String: [URL]] = [:]
            for (url, depth) in depths {
                // Bucketing on the rendered label, not on the components, is
                // what makes canonically equivalent names collide: `String`
                // equality is canonical, so a folder stored decomposed and one
                // stored precomposed land in the same bucket — which is right,
                // because they draw identically and are exactly the pair a
                // reader could not tell apart.
                buckets[label(components[url] ?? [], depth: depth), default: []]
                    .append(url)
            }
            for bucket in buckets.values where bucket.count > 1 {
                for url in bucket
                where depths[url, default: 0] < (components[url]?.count ?? 0) {
                    depths[url, default: 0] += 1
                    didGrow = true
                }
            }
        }

        return depths.reduce(into: [:]) { result, entry in
            result[entry.key] = label(
                components[entry.key] ?? [],
                depth: entry.value
            )
        }
    }

    /// Display name for one root among its peers. `url` need not appear in
    /// `peers` — a root that is absent simply has nothing to collide with.
    static func name(for url: URL, among peers: [URL]) -> String {
        let standardized = url.standardizedFileURL
        return resolve(for: peers + [standardized])[standardized]
            ?? label(nameableComponents(of: standardized), depth: 1)
    }

    /// Path components that can carry a name. The leading `/` that
    /// `pathComponents` reports for an absolute URL is punctuation rather than
    /// a folder, and joining it back in would produce a doubled `//Users`.
    private static func nameableComponents(of url: URL) -> [String] {
        url.pathComponents.filter { $0 != separator }
    }

    private static func label(_ components: [String], depth: Int) -> String {
        guard !components.isEmpty else { return rootName }
        let clamped = min(max(depth, 1), components.count)
        let joined = components.suffix(clamped).joined(separator: separator)
        // At full depth the name *is* the path, so lead with the root slash: it
        // reads as absolute rather than as a suspiciously long relative name,
        // and it separates an ancestor from the descendant that shares every
        // component it has.
        return clamped == components.count ? separator + joined : joined
    }
}
