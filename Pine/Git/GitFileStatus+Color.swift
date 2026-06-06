//
//  GitFileStatus+Color.swift
//  Pine
//
//  SwiftUI color mapping for GitFileStatus, separated from models
//  so that GitModels.swift depends only on Foundation.
//

import SwiftUI

extension GitFileStatus {
    var color: Color {
        switch self {
        case .modified, .mixed: return .orange
        case .staged:           return .green
        case .added:            return Color(.systemGreen)
        case .untracked:        return Color(.systemTeal)
        case .deleted:          return .red
        case .conflict:         return .red
        }
    }
}
