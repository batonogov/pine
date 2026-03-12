//
//  FocusedProjectKey.swift
//  Pine
//
//  Created by Claude on 13.03.2026.
//

import SwiftUI

/// FocusedValueKey for passing the active ProjectManager to menu commands.
struct FocusedProjectKey: FocusedValueKey {
    typealias Value = ProjectManager
}

extension FocusedValues {
    var projectManager: ProjectManager? {
        get { self[FocusedProjectKey.self] }
        set { self[FocusedProjectKey.self] = newValue }
    }
}
