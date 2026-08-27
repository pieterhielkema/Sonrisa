//
//  TabGroup.swift
//  Sonrisa
//
//  A named tab group. Groups render as chips in their own row above the tab
//  strip; only the active group's tabs are visible. Ungrouped tabs form the
//  implicit "Default" group, which always exists and can't be removed.
//

import Foundation
import Observation

@MainActor
@Observable
final class TabGroup: Identifiable {
    let id = UUID()
    var name: String
    /// Pinned groups sort first in the group row and are restored on every
    /// launch, even when session restore is off.
    var isPinned = false

    init(name: String) {
        self.name = name
    }
}
