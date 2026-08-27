//
//  TabStripView.swift
//  Sonrisa
//
//  Two stacked rows: group chips on top (Default first, then named groups),
//  and below it the tabs of the active group plus the pinned tabs.
//

import SwiftUI

/// True while the pointer is over a chip or button — the window-drag gesture
/// must yield there or it swallows chip drags and clicks.
struct StripInteractiveHoverKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Strip drag-and-drop payload: a tab chip or a group chip, encoded as a
/// string for Transferable.
private enum DragPayload {
    case tab(Tab.ID)
    case group(UUID)

    var string: String {
        switch self {
        case .tab(let id): return "tab:\(id.uuidString)"
        case .group(let id): return "group:\(id.uuidString)"
        }
    }

    init?(_ raw: String?) {
        guard let raw else { return nil }
        if raw.hasPrefix("tab:"),
           let id = UUID(uuidString: String(raw.dropFirst("tab:".count))) {
            self = .tab(id)
        } else if raw.hasPrefix("group:"),
                  let id = UUID(uuidString: String(raw.dropFirst("group:".count))) {
            self = .group(id)
        } else {
            return nil
        }
    }
}

/// The group chips plus the scrollable tab chips. `singleRow` lays both out
/// in one horizontal scroll — the layout used inside the native toolbar.
/// Clicking the already-active tab reports via `onActiveTabTap` (opens the
/// address overlay) instead of re-selecting.
struct TabChipsScroll: View {
    @Bindable var model: BrowserViewModel
    var singleRow = false
    var onActiveTabTap: (() -> Void)?
    @State private var groupPlusHovering = false
    /// Actual width granted to the toolbar row; drives the chip-width math.
    @State private var measuredWidth: CGFloat = 0

    var body: some View {
        if singleRow {
            // Toolbar layout. Up to three (unpinned) tabs: fixed-width chips,
            // island hugs them (the toolbar centers it). More: the island
            // fills the toolbar and chips share the width evenly, the active
            // one never below its minimum. Chip widths come from the measured
            // width (onGeometryChange — a GeometryReader here would report a
            // near-zero ideal to the toolbar and collapse the island); only
            // when inactive chips hit their floor does the row scroll.
            let expands = model.visibleTabs.filter { !$0.isPinned }.count > 3
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        if !model.groups.isEmpty {
                            groupChips
                            Divider().frame(height: 16)
                        }
                        toolbarTabChips(available: measuredWidth)
                    }
                    .padding(.horizontal, 8)
                    // Tight: the row must match the height of the
                    // neighboring native toolbar controls.
                    .padding(.vertical, 1)
                    // Only the >3 layout spans the whole island width.
                    .frame(minWidth: expands ? max(measuredWidth, 0) : nil,
                           alignment: .leading)
                }
            }
            // Glass shadows draw outside the scroll bounds.
            .scrollClipDisabled()
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) {
                measuredWidth = $0
            }
            // Dropping past the last chip moves the tab to the row's end.
            .dropDestination(for: String.self) { items, _ in
                guard case .tab(let id)? = DragPayload(items.first) else { return false }
                model.moveTab(id, before: nil)
                return true
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // With no named groups there's nothing to switch — hide the
                // row. New Group stays reachable from the + button's menu.
                if !model.groups.isEmpty {
                    groupRow
                }
                tabRow
            }
        }
    }

    // MARK: Group row

    private var groupRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 4) {
            groupChips
            .padding(.horizontal, 8)
            // Room for the glass shadow, which the scroll view clips.
            .padding(.vertical, 4)
            }
        }
        // Dropping a group past the last chip moves it to the end.
        .dropDestination(for: String.self) { items, _ in
            guard case .group(let id)? = DragPayload(items.first) else { return false }
            model.moveGroup(id, before: nil)
            return true
        }
    }

    private var groupChips: some View {
            HStack(spacing: 4) {
                GroupChip(name: "Default",
                          isActive: model.activeGroupID == nil,
                          compact: singleRow,
                          onSelect: { model.selectGroup(nil) })
                    .contextMenu {
                        Button("New Tab") {
                            model.selectGroup(nil)
                            model.newTab()
                        }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard case .tab(let id)? = DragPayload(items.first) else { return false }
                        model.moveTab(id, intoGroup: nil)
                        return true
                    }

                ForEach(model.groups) { group in
                    GroupChip(name: group.name,
                              isActive: model.activeGroupID == group.id,
                              isPinned: group.isPinned,
                              compact: singleRow,
                              onSelect: { model.selectGroup(group) },
                              onRename: { model.renameGroup(group, to: $0) })
                        .contextMenu {
                            Button("New Tab in Group") { model.newTab(inGroup: group) }
                            Button(group.isPinned ? "Unpin Group" : "Pin Group") {
                                model.togglePinGroup(group)
                            }
                            Button("Ungroup") { model.ungroup(group) }
                            Divider()
                            Button("Close Group") { model.closeGroup(group) }
                        }
                        .draggable(DragPayload.group(group.id).string)
                        .dropDestination(for: String.self) { items, _ in
                            switch DragPayload(items.first) {
                            case .tab(let id): model.moveTab(id, intoGroup: group)
                            case .group(let id): model.moveGroup(id, before: group.id)
                            case nil: return false
                            }
                            return true
                        }
                }

                Button {
                    model.newGroup()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.hover)
                .onHover { groupPlusHovering = $0 }
                .preference(key: StripInteractiveHoverKey.self, value: groupPlusHovering)
                .help("New Group")
            }
    }

    // MARK: Tab row

    private var tabRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 6) {
                tabChips
                .padding(.horizontal, 8)
                // Room for the glass shadow, which the scroll view clips.
                .padding(.vertical, 4)
                }
            }
            // Dropping past the last chip moves the tab to the row's end.
            .dropDestination(for: String.self) { items, _ in
                guard case .tab(let id)? = DragPayload(items.first) else { return false }
                model.moveTab(id, before: nil)
                return true
            }

        }
    }

    /// Fixed chip width while chips are still counted (≤3), and the active
    /// chip's minimum width once there are more.
    private let fixedChipWidth: CGFloat = 200
    /// Smallest an inactive chip may get before the row starts scrolling.
    private let minChipWidth: CGFloat = 36
    /// Approximate width of a pinned (favicon-only) chip, for layout math.
    private let pinnedChipWidth: CGFloat = 36

    /// Toolbar sizing model: with up to three (unpinned) tabs every chip has
    /// the same fixed width. Beyond that chips share the island width evenly;
    /// the active chip never drops below `fixedChipWidth`, the rest split
    /// what remains, down to a floor. Pinned chips always hug their content.
    private func toolbarTabChips(available: CGFloat) -> some View {
        let tabs = model.visibleTabs
        let unpinnedCount = tabs.filter { !$0.isPinned }.count
        let pinnedTotal = CGFloat(tabs.count - unpinnedCount) * pinnedChipWidth
        let chrome = CGFloat(max(0, tabs.count - 1)) * 6 + 16
        let avail = available - chrome - pinnedTotal
        let even = avail / CGFloat(max(1, unpinnedCount))
        let activeWidth = max(even, fixedChipWidth)
        let inactiveWidth = unpinnedCount > 1
            ? max(minChipWidth, (avail - activeWidth) / CGFloat(unpinnedCount - 1))
            : activeWidth
        return HStack(spacing: 6) {
            ForEach(tabs) { tab in
                let isActive = tab.id == model.activeTab?.id
                if tab.isPinned {
                    tabChip(tab)
                } else if unpinnedCount <= 3 {
                    tabChip(tab).frame(width: fixedChipWidth)
                } else {
                    tabChip(tab).frame(width: isActive ? activeWidth
                                                       : inactiveWidth)
                }
            }
        }
    }

    private var tabChips: some View {
        HStack(spacing: 6) {
            ForEach(model.visibleTabs) { tab in
                tabChip(tab)
            }
        }
    }

    @ViewBuilder
    private func tabChip(_ tab: Tab) -> some View {
        let isActive = tab.id == model.activeTab?.id
        TabChip(tab: tab,
                isActive: isActive,
                compact: singleRow,
                // Clicking the active tab opens the address overlay instead
                // of a no-op re-select.
                onSelect: {
                    if isActive, let onActiveTabTap {
                        onActiveTabTap()
                    } else {
                        model.select(tab)
                    }
                },
                onClose: { model.close(tab) })
            .contextMenu {
                Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
                    model.togglePin(tab)
                }
                Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") {
                    tab.toggleMute()
                }
                if model.group(for: tab) != nil {
                    Button("Remove from Group") {
                        model.moveTab(tab.id, intoGroup: nil)
                    }
                }
                Divider()
                Button("Close Tab") { model.close(tab) }
            }
            .draggable(DragPayload.tab(tab.id).string)
            .dropDestination(for: String.self) { items, _ in
                guard case .tab(let dragged)? = DragPayload(items.first) else { return false }
                model.moveTab(dragged, before: tab.id)
                return true
            }
    }
}

struct TabStripView: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        TabChipsScroll(model: model)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        // Subtle wash of the user's accent color over the chrome (colorful
        // chrome setting; clear when the simple look is on). Incognito
        // windows get a darker wash instead. The native toolbar above owns
        // window dragging and the traffic lights now.
        .background(model.isIncognito ? Color.black.opacity(0.2)
                    : (AppSettings.shared.chromeTint ?? .clear).opacity(0.05))
        .background(.bar)
    }
}

/// A chip in the group row. Click activates the group; double-click renames
/// (real groups only — Default has no rename handler).
private struct GroupChip: View {
    let name: String
    let isActive: Bool
    var isPinned = false
    /// Toolbar layout: tighter padding, matching TabChip.
    var compact = false
    let onSelect: () -> Void
    var onRename: ((String) -> Void)?

    @State private var isHovering = false
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 5) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Text(name)
                .lineLimit(1)
                .font(.callout.weight(isActive ? .semibold : .regular))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 3 : 6)
        .chipGlass(active: isActive, hovering: isHovering)
        .contentShape(Capsule())
        .onTapGesture(count: 2) {
            guard onRename != nil else { return }
            draft = name
            renaming = true
        }
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .preference(key: StripInteractiveHoverKey.self, value: isHovering)
        .popover(isPresented: $renaming) {
            TextField("Group name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .padding(8)
                .onSubmit {
                    onRename?(draft)
                    renaming = false
                }
        }
    }
}

private struct TabChip: View {
    let tab: Tab
    let isActive: Bool
    /// Toolbar layout: tighter padding so the chip row matches the height of
    /// the neighboring native toolbar controls.
    var compact = false
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                FaviconView(host: tab.host, fetchOnMiss: !tab.isIncognito)
            }

            if tab.isMuted {
                Image(systemName: "speaker.slash.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            // Pinned tabs are compact: favicon only, no close button.
            if !tab.isPinned {
                Text(tab.title)
                    .lineLimit(1)
                    .font(.callout)
                    // In the toolbar the chip's width is imposed from outside
                    // (fixed or fill) — the title stretches into it and
                    // truncates when squeezed.
                    .frame(maxWidth: compact ? .infinity : 160,
                           alignment: .leading)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hover)
                .opacity(isHovering || isActive ? 1 : 0)
                .help("Close Tab")
            }
        }
        .padding(.leading, 8)
        // The close button's own hit-area padding supplies the visual gap.
        .padding(.trailing, tab.isPinned ? 8 : 5)
        .padding(.vertical, compact ? 3 : 6)
        .chipGlass(active: isActive, hovering: isHovering)
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .preference(key: StripInteractiveHoverKey.self, value: isHovering)
    }
}

private extension View {
    /// Liquid Glass chip background, Safari-style: the active chip is a
    /// floating untinted glass island, hover gets a subtle one, idle chips
    /// are flat text like Safari's inactive tabs.
    @ViewBuilder
    func chipGlass(active: Bool, hovering: Bool) -> some View {
        if active {
            glassEffect(.regular.interactive(), in: .capsule)
        } else if hovering {
            glassEffect(.regular, in: .capsule)
        } else {
            self
        }
    }
}
