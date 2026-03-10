//
//  FileTreeViewModel.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

/// Одна вкладка терминала. Содержит ссылку на свою сессию.
/// class (не struct), чтобы session не копировалась при передаче.
@Observable
final class TerminalTab: Identifiable, Hashable {
    let id = UUID()
    var name: String
    let session = TerminalSession()

    init(name: String) {
        self.name = name
    }

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
