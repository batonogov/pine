//
//  GitFileStatus+Indicator.swift
//  Pine
//
//  Non-colour presentation of GitFileStatus for the sidebar (#1532):
//  a letter badge for the visual row and the localized name VoiceOver
//  announces, both wired through a11y.gitStatus.*.
//

import Foundation

extension GitFileStatus {
    /// The letter shown next to the filename. Follows `git status
    /// --porcelain` where it can: "MM" is the porcelain pair for a staged
    /// edit with further unstaged edits, and the single letters are the
    /// conventional M/A/D. Two cases deviate from the porcelain letter on
    /// purpose so every status stays distinguishable without colour:
    /// `.staged` (an index-only edit, porcelain "M ") uses S, and
    /// `.untracked` (porcelain "?") uses U so it reads as a status rather
    /// than as a question mark.
    var statusLetter: String {
        switch self {
        case .modified:  return "M"
        case .mixed:     return "MM"
        case .staged:    return "S"
        case .added:     return "A"
        case .deleted:   return "D"
        case .untracked: return "U"
        case .conflict:  return "C"
        }
    }

    /// The localized name VoiceOver announces as the row's value.
    var accessibilityStatusName: String {
        switch self {
        case .modified:  return Strings.a11yGitStatusModified
        case .mixed:     return Strings.a11yGitStatusMixed
        case .staged:    return Strings.a11yGitStatusStaged
        case .added:     return Strings.a11yGitStatusAdded
        case .deleted:   return Strings.a11yGitStatusDeleted
        case .untracked: return Strings.a11yGitStatusUntracked
        case .conflict:  return Strings.a11yGitStatusConflict
        }
    }
}
