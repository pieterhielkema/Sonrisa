//
//  BrowserViewModel.swift
//  Sonrisa
//
//  Owns the set of tabs, the tab groups, and the active selection.
//

import Foundation
import Observation

@MainActor
@Observable
final class BrowserViewModel {
    private(set) var tabs: [Tab] = []
    var activeTabID: Tab.ID?

    /// Named tab groups, in bar order (pinned groups first). Ungrouped tabs
    /// form the implicit "Default" group, which always comes first and can't
    /// be removed. Only the active group's tabs show in the tab row.
    private(set) var groups: [TabGroup] = []
    /// nil means the implicit Default group is active.
    private(set) var activeGroupID: UUID?
    /// Each group's last selected tab, restored when switching back to it.
    private var lastActiveTab: [UUID?: Tab.ID] = [:]

    /// An incognito window: all its tabs share the in-memory incognito
    /// context, and visits are never recorded in history.
    let isIncognito: Bool

    /// Per-window ad blocking. On for every new window; flipping it applies
    /// to all the window's tabs and reloads the active one.
    var adblockEnabled = true {
        didSet {
            for tab in tabs { tab.controller.adblockEnabled = adblockEnabled }
            activeTab?.reload()
        }
    }

    let favorites = FavoritesStore()
    let history = HistoryStore.shared

    /// Hidden browser that exists for the whole session. Chrome-style CEF
    /// begins app shutdown the moment its live browser count reaches zero, and
    /// closing the last tab hits zero transiently (the replacement tab's
    /// browser is created asynchronously). This keeper pins the count above
    /// zero so CEF never self-terminates; it closes with the app. Static so
    /// multiple windows share a single keeper.
    private static let keeperBrowser = CEFBrowserController(url: "about:blank")

    /// Incremented whenever the address bar should take focus (new empty tab).
    private(set) var addressFocusRequest = 0
    /// Incremented when the find bar should open (⌘F).
    private(set) var findRequest = 0
    /// Incremented when the history sheet should open (⌘Y).
    private(set) var historyRequest = 0
    /// Incremented when the tab overview should open (⇧⌘\).
    private(set) var overviewRequest = 0

    /// URLs of recently closed tabs, newest last (⌘⇧T pops).
    private var closedTabURLs: [String] = []

    /// This window's slot in the persisted session; nil for incognito.
    private var sessionSlot: Int?

    private var started = false

    init(incognito: Bool = false) {
        // Deliberately light: SwiftUI evaluates the window content closure
        // (and therefore this init) several times and discards the extras.
        // Creating CEF browsers for a discarded model crashes CEF when they
        // dealloc mid-creation — so all real work waits for startIfNeeded(),
        // called once from the view that actually appears on screen.
        isIncognito = incognito
    }

    /// Closes every tab's CEF browser cleanly. Called when the window goes
    /// away — deallocating controllers with live browsers crashes CEF.
    /// The saved session is frozen first so the teardown doesn't erase it.
    func shutdown() {
        sessionSlot = nil
        let closing = tabs
        tabs.removeAll()
        activeTabID = nil
        for tab in closing { tab.close() }
    }

    /// Builds the initial tabs. Idempotent; call from the view's .task.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        _ = Self.keeperBrowser  // ensure the shared keeper exists
        if isIncognito {
            // Incognito windows open on an empty tab, address bar focused.
            newTab()
            return
        }
        let (slot, saved) = SessionStore.shared.claim()
        sessionSlot = slot
        let keep = { (urls: [String]) in
            urls.filter { !$0.isEmpty && $0 != "about:blank" }
        }
        let restore = AppSettings.shared.restoreSession
        let pinned = restore ? keep(saved.pinned) : []
        let plain = restore ? keep(saved.urls) : []
        for url in pinned { newTab(url: url).isPinned = true }
        for url in plain { newTab(url: url) }
        // Pinned groups always come back; the rest only with session restore.
        for savedGroup in saved.groups ?? [] where savedGroup.pinned ?? false || restore {
            let urls = keep(savedGroup.urls)
            guard !urls.isEmpty else { continue }
            let group = TabGroup(name: savedGroup.name)
            group.isPinned = savedGroup.pinned ?? false
            groups.append(group)
            for url in urls { newTab(url: url).groupID = group.id }
        }
        normalizeGroups()
        normalizeOrder()
        if tabs.isEmpty {
            newTab(url: AppSettings.shared.resolvedStartPage)
        }
        if let first = tabs.first(where: { !$0.isPinned }) {
            activeGroupID = first.groupID
            activeTabID = first.id
        } else {
            activeTabID = tabs.first?.id
        }
        // After the session is rebuilt: regular windows receive URLs opened
        // from other apps (default-browser link clicks); incognito never does.
        URLRouter.shared.register(self)
    }

    func requestAddressFocus() { addressFocusRequest += 1 }
    func requestFind() { findRequest += 1 }
    func requestHistory() { historyRequest += 1 }
    func requestOverview() { overviewRequest += 1 }

    var activeTab: Tab? {
        guard let activeTabID else { return tabs.first }
        return tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    // MARK: Tab groups

    /// Tabs in the tab row: pinned tabs plus the active group's own tabs.
    var visibleTabs: [Tab] {
        tabs.filter { $0.isPinned || $0.groupID == activeGroupID }
    }

    var activeGroup: TabGroup? {
        groups.first { $0.id == activeGroupID }
    }

    /// Switches the tab row to `group` (nil = Default) and restores its last
    /// selected tab, falling back to its first tab or a fresh blank one.
    func selectGroup(_ group: TabGroup?) {
        activeGroupID = group?.id
        let members = tabs.filter { !$0.isPinned && $0.groupID == group?.id }
        if let remembered = lastActiveTab[group?.id],
           let tab = members.first(where: { $0.id == remembered }) {
            activeTabID = tab.id
        } else if let first = members.first {
            activeTabID = first.id
        } else {
            newTab()
        }
    }

    /// Creates a group with a fresh empty tab in it and switches to it.
    func newGroup() {
        let group = TabGroup(name: "New Group")
        groups.append(group)
        activeGroupID = group.id
        newTab()
    }

    /// Opens a tab in `group`, switching the strip to it.
    @discardableResult
    func newTab(url: String? = nil, inGroup group: TabGroup) -> Tab {
        activeGroupID = group.id
        return newTab(url: url)
    }

    func renameGroup(_ group: TabGroup, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        group.name = trimmed
        syncSession()
    }

    /// Pinned groups sort first and are restored on every launch, even with
    /// session restore off.
    func togglePinGroup(_ group: TabGroup) {
        group.isPinned.toggle()
        normalizeGroups()
        normalizeOrder()
        syncSession()
    }

    /// Dissolves the group; its tabs move to Default.
    func ungroup(_ group: TabGroup) {
        for tab in tabs where tab.groupID == group.id { tab.groupID = nil }
        groups.removeAll { $0.id == group.id }
        if activeGroupID == group.id { activeGroupID = nil }
        normalizeOrder()
        syncSession()
    }

    func closeGroup(_ group: TabGroup) {
        for tab in tabs.filter({ $0.groupID == group.id }) { close(tab) }
    }

    /// Moves a tab into `group` (nil = Default), at the end of that group.
    func moveTab(_ id: Tab.ID, intoGroup group: TabGroup?) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isPinned = false
        tab.groupID = group?.id
        // Put it last within its new group: move to the array's end and let
        // normalization slot the groups back into order.
        tabs.removeAll { $0.id == id }
        tabs.append(tab)
        pruneEmptyGroups()
        normalizeOrder()
        // The active tab may have just left the visible row.
        if activeTabID == id, group?.id != activeGroupID {
            selectFallbackInActiveGroup()
        }
        syncSession()
    }

    /// Reorders `id` just before group `targetID` (or last when nil). Pinned
    /// groups stay in front regardless.
    func moveGroup(_ id: UUID, before targetID: UUID?) {
        guard id != targetID,
              let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups.remove(at: from)
        if let targetID, let to = groups.firstIndex(where: { $0.id == targetID }) {
            groups.insert(group, at: to)
        } else {
            groups.append(group)
        }
        normalizeGroups()
        normalizeOrder()
        syncSession()
    }

    func group(for tab: Tab) -> TabGroup? {
        guard let id = tab.groupID else { return nil }
        return groups.first { $0.id == id }
    }

    /// Selects some tab of the active group; opens a blank one if empty.
    private func selectFallbackInActiveGroup() {
        let members = tabs.filter { !$0.isPinned && $0.groupID == activeGroupID }
        if let first = members.first {
            activeTabID = first.id
        } else {
            newTab()
        }
    }

    /// Groups never outlive their last tab. Clears the active group if it
    /// vanished.
    private func pruneEmptyGroups() {
        groups.removeAll { group in !tabs.contains { $0.groupID == group.id } }
        if let id = activeGroupID, !groups.contains(where: { $0.id == id }) {
            activeGroupID = nil
        }
    }

    /// Pinned groups sit at the front of the group row.
    private func normalizeGroups() {
        groups = groups.filter(\.isPinned) + groups.filter { !$0.isPinned }
    }

    /// Restores the tab-array invariant: pinned tabs first, then Default's
    /// tabs, then each group's tabs contiguously in group order. Tabs
    /// pointing at a deleted group fall back to Default.
    private func normalizeOrder() {
        let known = Set(groups.map(\.id))
        for tab in tabs {
            if let id = tab.groupID, !known.contains(id) { tab.groupID = nil }
        }
        let pinned = tabs.filter(\.isPinned)
        let ungrouped = tabs.filter { !$0.isPinned && $0.groupID == nil }
        let grouped = groups.flatMap { group in
            tabs.filter { $0.groupID == group.id }
        }
        tabs = pinned + ungrouped + grouped
    }

    // MARK: Tab management

    /// Opens an empty tab in the active group: no page loads, the address bar
    /// takes focus.
    @discardableResult
    func newTab(url: String? = nil) -> Tab {
        let tab = Tab(url: url, incognito: isIncognito)
        tab.groupID = activeGroupID
        tab.controller.adblockEnabled = adblockEnabled
        // Popups (middle-click, window.open, target=_blank) become tabs.
        tab.controller.onPopupRequested = { [weak self] url in
            MainActor.assumeIsolated {
                self?.openInNewTab(url)
            }
        }
        // JS window.close(): close the tab, never the app window (CEF's
        // default would performClose: the whole window).
        tab.controller.onPageRequestedClose = { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                self.close(tab)
            }
        }
        // "Inspect Element" from the page context menu. DevTools open where
        // the placement setting says: docked in this window's sidebar, or in
        // a separate window. (No inspect-at-point: chrome-style ShowDevTools
        // crashes on a non-empty inspect point.)
        tab.controller.onInspectElementRequested = { [weak tab] _, _ in
            MainActor.assumeIsolated {
                guard let tab else { return }
                if AppSettings.shared.devToolsPlacement.effective == .sidebar {
                    tab.devToolsInSidebar = true
                } else if !tab.controller.hasDevTools() {
                    tab.controller.showDevToolsInWindow()
                }
            }
        }
        if !isIncognito {
            tab.onVisit = { [weak self] url, title in
                self?.history.record(url: url, title: title)
                self?.syncSession()
            }
            tab.onTitleUpdated = { [weak self] url, title in
                self?.history.updateTitle(for: url, title: title)
            }
        }
        let previous = activeTab
        tabs.append(tab)
        activeTabID = tab.id
        lastActiveTab[activeGroupID] = tab.id
        if url == nil {
            addressFocusRequest += 1
        }
        closeIfAbandonedBlank(previous)
        syncSession()
        return tab
    }

    func select(_ tab: Tab) {
        let previous = activeTab
        activeTabID = tab.id
        if !tab.isPinned {
            activeGroupID = tab.groupID
            lastActiveTab[tab.groupID] = tab.id
        }
        closeIfAbandonedBlank(previous)
    }

    /// Moving away from an untouched empty tab closes it — a blank tab left
    /// behind is just clutter.
    private func closeIfAbandonedBlank(_ previous: Tab?) {
        guard let previous, previous.isBlank,
              previous.id != activeTabID,
              tabs.contains(where: { $0.id == previous.id }) else { return }
        close(previous)
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if !tab.url.isEmpty, tab.url != "about:blank" {
            closedTabURLs.append(tab.url)
            if closedTabURLs.count > 20 { closedTabURLs.removeFirst() }
        }
        let visibleIndex = visibleTabs.firstIndex { $0.id == tab.id }
        tab.close()
        tabs.remove(at: index)
        pruneEmptyGroups()

        if activeTabID == tab.id {
            let remaining = visibleTabs
            if let visibleIndex, !remaining.isEmpty {
                // Select a sensible neighbor in the row.
                activeTabID = remaining[min(visibleIndex, remaining.count - 1)].id
            } else if let other = tabs.first(where: { !$0.isPinned }) {
                // The active group vanished; fall back to one that has tabs.
                selectGroup(group(for: other))
            } else {
                newTab()
            }
        }
        syncSession()
    }

    /// Pins/unpins a tab; pinned tabs show in every group, at the front of
    /// the strip. Pinning removes the tab from its group.
    func togglePin(_ tab: Tab) {
        tab.isPinned.toggle()
        if tab.isPinned { tab.groupID = nil }
        pruneEmptyGroups()
        normalizeOrder()
        syncSession()
    }

    /// Drag-reorder within the row: moves `id` just before `targetID` (or to
    /// the end of the active group when nil). The tab joins the target's
    /// group.
    func moveTab(_ id: Tab.ID, before targetID: Tab.ID?) {
        guard id != targetID,
              let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        if let targetID, let to = tabs.firstIndex(where: { $0.id == targetID }) {
            let target = tabs[to]
            if !tab.isPinned {
                tab.groupID = target.isPinned ? activeGroupID : target.groupID
            }
            tabs.insert(tab, at: to)
        } else {
            tab.groupID = tab.isPinned ? nil : activeGroupID
            tabs.append(tab)
        }
        pruneEmptyGroups()
        normalizeOrder()
        syncSession()
    }

    func reopenClosedTab() {
        guard let url = closedTabURLs.popLast() else { return }
        newTab(url: url)
    }

    /// Selects the visible tab at 1-based `number`; 9 always means the last.
    func selectTab(number: Int) {
        let visible = visibleTabs
        guard !visible.isEmpty else { return }
        let index = number == 9 ? visible.count - 1 : number - 1
        guard visible.indices.contains(index) else { return }
        select(visible[index])
    }

    func selectAdjacentTab(offset: Int) {
        let visible = visibleTabs
        guard visible.count > 1,
              let current = visible.firstIndex(where: { $0.id == activeTab?.id })
        else { return }
        select(visible[(current + offset + visible.count) % visible.count])
    }

    private func syncSession() {
        guard let slot = sessionSlot else { return }
        let keep = { (list: [Tab]) in
            list.map(\.url).filter { !$0.isEmpty && $0 != "about:blank" }
        }
        SessionStore.shared.update(slot: slot, session: WindowSession(
            pinned: keep(tabs.filter(\.isPinned)),
            urls: keep(tabs.filter { !$0.isPinned && $0.groupID == nil }),
            groups: groups.compactMap { group in
                let urls = keep(tabs.filter { $0.groupID == group.id })
                return urls.isEmpty ? nil : SavedTabGroup(
                    name: group.name, urls: urls, pinned: group.isPinned)
            }))
    }

    // MARK: Navigation helpers (operate on the active tab)

    func navigateActive(to input: String) {
        (activeTab ?? newTab()).load(input)
    }

    func openInNewTab(_ url: String) {
        newTab(url: url)
    }
}
