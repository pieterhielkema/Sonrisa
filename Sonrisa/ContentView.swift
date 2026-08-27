//
//  ContentView.swift
//  Sonrisa
//
//  Top-level browser chrome: tab strip, navigation bar, favorites bar, and the
//  active tab's web content.
//

import AppKit
import SwiftUI

/// Actual process launch time, read from the kernel. Used to spot the phantom
/// duplicate window SwiftUI opens at launch. Must not be `Date()`: globals are
/// lazily initialized, and the launch path can short-circuit before touching
/// this — a plain `Date()` would then capture the user's first ⌘N instead,
/// making that window look like the launch phantom and killing its model.
private let processLaunchDate: Date = {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
    let tv = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
}()

struct ContentView: View {
    @State private var model: BrowserViewModel

    init(incognito: Bool = false) {
        NSLog("[SonrisaWindow] ContentView init incognito=%d", incognito ? 1 : 0)
        _model = State(initialValue: BrowserViewModel(incognito: incognito))
    }
    @State private var addressText: String = ""
    @State private var showsEngineChooser = !AppSettings.shared.hasChosenSearchEngine
    @State private var showsHistory = false
    @State private var suggestions: [HistorySuggestion] = []
    @State private var selectedSuggestionIndex: Int?
    /// The Spotlight-style address overlay, centered over the page. Opened
    /// by ⌘T/⌘L, the + button, or clicking the active tab chip.
    @State private var showsSpotlight = false
    /// Window content width; drives the toolbar tab island's computed ideal
    /// width (NSToolbar offers no flexible sizing for custom SwiftUI items).
    @State private var contentWidth: CGFloat = 0
    @State private var confirmRemoveFavorite = false
    @State private var showsDownloads = false
    @State private var showsFind = false
    @State private var showsOverview = false
    @State private var enteredFullscreenForVideo = false
    @State private var findText = ""
    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool

    private var downloadsStore = DownloadsStore.shared

    private var settings = AppSettings.shared
    private let browserSpace = "browser"

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Split into chunks — one expression with every modifier makes the
        // type checker give up.
        withEventHandlers(chromeAndContent)
    }

    private var chromeAndContent: some View {
        VStack(spacing: 0) {
            if model.activeTab?.isHTMLFullscreen != true {
                Group {
                    // Navigation and the tab chips live in the native
                    // toolbar; only the favorites bar sits below it.
                    if settings.showFavoritesBar {
                        FavoritesBarView(model: model)
                    }
                }
                // Incognito windows get a dark header so they're unmistakable.
                .environment(\.colorScheme, model.isIncognito ? .dark : colorScheme)
                Divider()
            }
            content
                .overlay(alignment: .topTrailing) {
                    if let tab = model.activeTab, let pending = tab.pendingPasswordSave {
                        PasswordSaveBanner(pending: pending) {
                            tab.pendingPasswordSave = nil
                        }
                        .padding(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .top) {
                    if showsFind { findBar }
                }
                .overlay {
                    if showsOverview { tabOverview }
                }
                .overlay {
                    if showsSpotlight { spotlightOverlay }
                }
                .overlay {
                    DeeplinkRedirectOverlay()
                }
        }
        .toolbar { browserToolbar }
        // Theme wash over the native toolbar, matching the strip below;
        // incognito gets its darker variant.
        .toolbarBackground(model.isIncognito ? Color.black.opacity(0.2)
                           : (settings.chromeTint ?? .clear).opacity(0.05),
                           for: .windowToolbar)
        .focusedSceneValue(\.browserModel, model)
        // Real model setup happens only for the view instance that appears —
        // SwiftUI creates and discards extra ContentView/model pairs, and
        // those must never own CEF browsers (dealloc mid-creation crashes).
        .task {
            // Relaunch-handoff instance: exiting shortly; starting the model
            // would race the owning instance on the shared session file.
            guard !CEFRuntime.isRelaunchHandoff() else { return }
            // SwiftUI opens the browser WindowGroup TWICE at launch (the
            // "phantom scene", perfectly stacked so it looks like one
            // window). The second regular window appearing right after
            // launch while another is already live is that phantom — close
            // it before it starts a model. Windows the user opens later
            // (⌘N) are outside the launch window and unaffected.
            if !model.isIncognito,
               URLRouter.shared.hasLiveRegularModel,
               abs(processLaunchDate.timeIntervalSinceNow) < 5 {
                NSLog("[SonrisaWindow] dismissing phantom duplicate launch window")
                dismiss()
                return
            }
            NSLog("[SonrisaWindow] task startIfNeeded incognito=%d",
                  model.isIncognito ? 1 : 0)
            model.startIfNeeded()
            // Lets the router open a regular window when external URLs
            // arrive while only incognito windows exist.
            URLRouter.shared.openRegularWindow = { openWindow(id: "browser") }
        }
        // Window closing: close every CEF browser before the model deallocs.
        .onDisappear {
            NSLog("[SonrisaWindow] onDisappear incognito=%d",
                  model.isIncognito ? 1 : 0)
            model.shutdown()
        }
        // Size new windows to the user's smallest screen.
        .background(SmallestScreenSizer())
        .coordinateSpace(name: browserSpace)
        // Automated tab-close smoke test: SONRISA_AUTOTEST=1 closes a fresh
        // tab mid-creation, a settled fresh tab, and the initial loaded tab.
        .task { await runAutotestIfRequested() }
        .task { await runInspectAutotestIfRequested() }
        .task { await runSpotlightAutotestIfRequested() }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) {
            contentWidth = $0
        }
        .frame(minWidth: 760, minHeight: 480)
        .tint(settings.accent.color)
        .sheet(isPresented: $showsEngineChooser) {
            SearchEngineChooserView {
                showsEngineChooser = false
                // Reflect the chosen engine's home page in the initial tab.
                model.activeTab?.load(AppSettings.shared.resolvedStartPage)
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showsHistory) {
            HistoryView { url, inNewTab in
                showsHistory = false
                if inNewTab {
                    model.openInNewTab(url)
                } else {
                    model.navigateActive(to: url)
                }
            }
        }
    }

    private func withEventHandlers(_ base: some View) -> some View {
        base
        .onAppear { addressText = model.activeTab?.url ?? "" }
        .onChange(of: model.activeTab?.id) { _, _ in
            addressText = model.activeTab?.url ?? ""
        }
        .onChange(of: model.activeTab?.url) { _, newValue in
            if !addressFocused { addressText = newValue ?? "" }
        }
        .onChange(of: model.addressFocusRequest) { _, _ in
            // A blank tab embeds its own address bar in the start page —
            // NewTabView watches the same counter and focuses its field.
            if model.activeTab?.isBlank != true {
                openSpotlight()
            }
        }
        .onChange(of: model.findRequest) { _, _ in
            showsFind = true
            findFocused = true
        }
        .onChange(of: model.historyRequest) { _, _ in
            showsHistory = true
        }
        .onChange(of: model.overviewRequest) { _, _ in
            showsOverview.toggle()
        }
        .onChange(of: model.activeTab?.isHTMLFullscreen) { _, isFullscreen in
            // Mirror HTML5 fullscreen into native window fullscreen, and undo
            // it on exit — but only if we entered it for the video.
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            let windowIsFullscreen = window.styleMask.contains(.fullScreen)
            if isFullscreen == true, !windowIsFullscreen {
                enteredFullscreenForVideo = true
                window.toggleFullScreen(nil)
            } else if isFullscreen != true, windowIsFullscreen, enteredFullscreenForVideo {
                enteredFullscreenForVideo = false
                window.toggleFullScreen(nil)
            }
        }
        .onChange(of: model.activeTab?.id) { _, _ in
            if showsFind { closeFindBar() }
        }
        .onChange(of: addressText) { _, newValue in
            selectedSuggestionIndex = nil
            suggestions = addressFocused ? model.history.suggestions(for: newValue) : []
        }
        .onChange(of: addressFocused) { _, focused in
            if focused {
                // Select the whole address on focus, like other browsers.
                // The field editor installs a beat after focus changes, so
                // the helper retries across run-loop turns.
                RunLoop.main.perform(inModes: [.default]) {
                    guard addressFocused else { return }
                    selectAllInAddressField()
                }
            } else {
                // Focus left the field (click on the page, Esc, commit) —
                // the overlay has no reason to stay up without it.
                closeSpotlight()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .SonrisaNavigateBack)) { note in
            guard isNavigationTarget(note) else { return }
            if model.activeTab?.canGoBack == true { model.activeTab?.goBack() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .SonrisaNavigateForward)) { note in
            guard isNavigationTarget(note) else { return }
            if model.activeTab?.canGoForward == true { model.activeTab?.goForward() }
        }
    }

    /// Navigation notifications carry the window the event landed in; only the
    /// browser hosted by that window should react.
    private func isNavigationTarget(_ note: Notification) -> Bool {
        guard let ownWindow = model.activeTab?.controller.containerView.window else {
            return false
        }
        guard let target = note.object as? NSWindow else {
            return ownWindow.isKeyWindow
        }
        return target == ownWindow
    }

    // MARK: Spotlight address overlay

    private func openSpotlight() {
        addressText = model.activeTab?.url ?? ""
        showsSpotlight = true
        addressFocused = true
    }

    private func closeSpotlight() {
        showsSpotlight = false
        addressFocused = false
        suggestions = []
        selectedSuggestionIndex = nil
    }

    /// Spotlight-style address bar: a centered card over the page. Lives in
    /// the content hierarchy (not the toolbar), where programmatic FocusState
    /// actually works.
    private var spotlightOverlay: some View {
        ZStack(alignment: .top) {
            // Dim + click-away. Solid-ish color, not material: materials
            // can't sample the CEF surface below.
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { closeSpotlight() }
            spotlightCard
                .padding(.top, 90)
        }
        .transition(.opacity)
    }

    private var spotlightCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search or enter website", text: $addressText,
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    // Long URLs wrap instead of scrolling out of view.
                    .lineLimit(1...10)
                    .focused($addressFocused)
                    .onSubmit {
                        // Enter navigates to the highlighted suggestion, if any.
                        if let index = selectedSuggestionIndex,
                           suggestions.indices.contains(index) {
                            navigate(to: suggestions[index].url)
                        } else {
                            navigate(to: addressText)
                        }
                    }
                    .onKeyPress(.downArrow) { moveSuggestionSelection(by: 1) }
                    .onKeyPress(.upArrow) { moveSuggestionSelection(by: -1) }
                    .onKeyPress(.escape) {
                        closeSpotlight()
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            if !suggestions.isEmpty {
                Divider()
                suggestionList
            } else if !spotlightFavorites.isEmpty {
                Divider()
                spotlightFavoritesGrid
            }
        }
        .frame(width: 600)
        // Solid, not material: floats over the CEF surface.
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.35), radius: 28, y: 10)
        .onKeyPress(.escape) {
            closeSpotlight()
            return .handled
        }
    }

    /// Favorites shown under the spotlight input while it has no suggestions.
    /// Folders are flattened in place so everything is one click away.
    private var spotlightFavorites: [Favorite] {
        model.favorites.favorites.flatMap { fav in
            fav.isFolder ? fav.children.filter { !$0.isFolder } : [fav]
        }
    }

    private var spotlightFavoritesGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90, maximum: 116),
                                         spacing: 4)],
                      spacing: 4) {
                ForEach(spotlightFavorites) { favorite in
                    Button {
                        navigate(to: favorite.url)
                    } label: {
                        VStack(spacing: 6) {
                            FaviconView(host: favorite.host, size: 24)
                            Text(favorite.title)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(SpotlightTileStyle())
                    .help(favorite.url)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 240)
    }

    /// SONRISA_AUTOTEST_SPOTLIGHT=1 opens the spotlight address overlay a few
    /// seconds after launch so tooling can verify it appears and takes focus.
    private func runSpotlightAutotestIfRequested() async {
        guard ProcessInfo.processInfo.environment["SONRISA_AUTOTEST_SPOTLIGHT"] == "1" else { return }
        try? await Task.sleep(for: .seconds(3))
        NSLog("[autotest] opening spotlight overlay")
        openSpotlight()
    }

    private func runAutotestIfRequested() async {
        guard ProcessInfo.processInfo.environment["SONRISA_AUTOTEST"] == "1" else { return }
        try? await Task.sleep(for: .seconds(2))
        NSLog("[autotest] closing fresh tab immediately (creation in flight)")
        let instant = model.newTab()
        model.close(instant)
        try? await Task.sleep(for: .seconds(2))
        NSLog("[autotest] closing fresh tab after creation settled")
        let settled = model.newTab()
        try? await Task.sleep(for: .seconds(1))
        model.close(settled)
        try? await Task.sleep(for: .seconds(2))
        NSLog("[autotest] closing initial tab (page loaded)")
        if let first = model.tabs.first { model.close(first) }
        try? await Task.sleep(for: .seconds(2))
        NSLog("[autotest] done, still alive")
    }

    /// SONRISA_AUTOTEST_INSPECT=1: DevTools smoke test. Covers the windowed
    /// native path, the docked frontend-browser path (including CDP target
    /// resolution), Inspect Element in both placements, and closing a tab
    /// with the docked pane open. Every step that used to crash chrome-style
    /// ShowDevTools is exercised.
    private func runInspectAutotestIfRequested() async {
        guard ProcessInfo.processInfo.environment["SONRISA_AUTOTEST_INSPECT"] == "1" else { return }
        try? await Task.sleep(for: .seconds(4))
        guard let tab = model.activeTab else {
            NSLog("[autotest-inspect] FAIL no active tab")
            return
        }

        NSLog("[autotest-inspect] windowed: toggle native DevTools window")
        AppSettings.shared.devToolsPlacement = .window
        tab.controller.showDevToolsInWindow()
        try? await Task.sleep(for: .seconds(3))
        NSLog("[autotest-inspect] windowed open devtools=%d",
              tab.controller.hasDevTools() ? 1 : 0)
        tab.controller.closeDevTools()
        try? await Task.sleep(for: .seconds(2))

        NSLog("[autotest-inspect] windowed: inspect element opens window")
        tab.controller.onInspectElementRequested?(200, 200)
        try? await Task.sleep(for: .seconds(3))
        NSLog("[autotest-inspect] windowed inspect devtools=%d",
              tab.controller.hasDevTools() ? 1 : 0)
        tab.controller.closeDevTools()
        try? await Task.sleep(for: .seconds(2))

        NSLog("[autotest-inspect] sidebar: inspect element opens docked pane")
        AppSettings.shared.devToolsPlacement = .sidebar
        tab.controller.onInspectElementRequested?(200, 200)
        try? await Task.sleep(for: .seconds(5))
        NSLog("[autotest-inspect] sidebar=%d frontend=%d",
              tab.devToolsInSidebar ? 1 : 0, tab.devToolsController != nil ? 1 : 0)

        NSLog("[autotest-inspect] sidebar: re-inspect while open")
        tab.controller.onInspectElementRequested?(50, 50)
        try? await Task.sleep(for: .seconds(2))

        NSLog("[autotest-inspect] sidebar: toggle closed")
        tab.devToolsInSidebar = false
        tab.closeDevToolsPane()
        try? await Task.sleep(for: .seconds(2))
        NSLog("[autotest-inspect] pane closed frontend=%d",
              tab.devToolsController != nil ? 1 : 0)

        NSLog("[autotest-inspect] sidebar: reopen, then close tab with pane open")
        tab.controller.onInspectElementRequested?(120, 120)
        try? await Task.sleep(for: .seconds(4))
        model.close(tab)
        try? await Task.sleep(for: .seconds(2))
        NSLog("[autotest-inspect] done, still alive")
    }

    // MARK: Native toolbar

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            navButton("Back", "chevron.backward",
                      enabled: model.activeTab?.canGoBack ?? false,
                      help: "Back (⌘[)", shortcut: "[") {
                model.activeTab?.goBack()
            }
            navButton("Forward", "chevron.forward",
                      enabled: model.activeTab?.canGoForward ?? false,
                      help: "Forward (⌘])", shortcut: "]") {
                model.activeTab?.goForward()
            }
            if model.activeTab?.isLoading == true {
                navButton("Stop", "xmark", enabled: true, help: "Stop") { model.activeTab?.stop() }
            } else {
                navButton("Reload", "arrow.clockwise", enabled: true, help: "Reload") { model.activeTab?.reload() }
            }
        }
        ToolbarItem(placement: .principal) {
            TabChipsScroll(model: model, singleRow: true,
                           // Route through the model so a blank tab focuses
                           // its embedded start-page field instead.
                           onActiveTabTap: { model.requestAddressFocus() })
                // ≤3 tabs: natural width, the toolbar centers the island.
                // More: fill the center slot. NSToolbar sizes custom items
                // by their IDEAL width and has no public "flexible item" API
                // for SwiftUI content (a lone Spacer maps to FlexibleSpace,
                // composite content does not — verified empirically), so the
                // ideal is computed: window width minus a reserve for the
                // nav/action clusters (~380pt measured, padded to 470 for
                // the conditional downloads/incognito items). Overshooting
                // instead pushes every item into the overflow menu.
                .frame(minWidth: model.visibleTabs.filter({ !$0.isPinned }).count > 3
                           ? 280 : nil,
                       idealWidth: model.visibleTabs.filter({ !$0.isPinned }).count > 3
                           ? max(280, contentWidth - 470) : nil,
                       maxWidth: .infinity)
                // The incognito toolbar gets a dark wash; the chips must
                // render in dark scheme too or they turn dark-on-dark.
                .environment(\.colorScheme,
                             model.isIncognito ? .dark : colorScheme)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // Menus and plain images don't pick up the incognito toolbar's
            // dark wash on their own — force the scheme like the tab island.
            let scheme: ColorScheme = model.isIncognito ? .dark : colorScheme
            favoriteToggle
                .environment(\.colorScheme, scheme)
            if settings.blockAds {
                adblockToggle
                    .environment(\.colorScheme, scheme)
            }
            if !downloadsStore.downloads.isEmpty {
                downloadsButton
                    .environment(\.colorScheme, scheme)
            }
            if model.isIncognito {
                Label {
                    Text("Incognito")
                } icon: {
                    Image(systemName: "eyeglasses")
                        // Wide symbol overflows the toolbar item wrapper at
                        // its natural size — scale it into the same 24×24
                        // slot as the neighboring buttons.
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .frame(width: 17, height: 17)
                        .frame(width: 24, height: 24)
                }
                .help("Incognito window — browsing isn't saved")
                .environment(\.colorScheme, scheme)
            }
            newTabButton
                .environment(\.colorScheme, scheme)
        }
    }

    private func navButton(_ title: String, _ symbol: String,
                           enabled: Bool, help: String,
                           shortcut: KeyEquivalent? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Label (not bare Image) so the toolbar's "Icon and Text" display
            // mode has a title to show; icon-only mode ignores it.
            Label(title, systemImage: symbol)
        }
        .modifier(OptionalShortcut(key: shortcut))
        .disabled(!enabled)
        .foregroundStyle(enabled ? Color.primary : Color.secondary)
        .help(help)
    }

    /// New-tab button; hold for the New Tab / New Group menu. Disabled while
    /// the active tab is already a fresh empty one — another would be a no-op
    /// (and the blank-tab auto-close would just swallow it).
    private var newTabButton: some View {
        let onBlankTab = model.activeTab?.isBlank == true
        return Menu {
            Button("New Tab") { model.newTab() }
            Button("New Group") { model.newGroup() }
        } label: {
            Label("New Tab", systemImage: "plus")
        } primaryAction: {
            model.newTab()
        }
        .menuIndicator(.hidden)
        .disabled(onBlankTab)
        .help("New Tab (⌘T) — hold for menu")
        // Menu's primaryAction can't carry a shortcut; a hidden button does.
        .background {
            Button("") { model.newTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(onBlankTab)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    private var favoriteToggle: some View {
        let url = model.activeTab?.url ?? ""
        let isFavorite = model.favorites.contains(url: url)
        return Button {
            if isFavorite {
                confirmRemoveFavorite = true
            } else if let tab = model.activeTab {
                model.favorites.add(title: tab.title, url: tab.url)
            }
        } label: {
            Label {
                Text("Favorite")
            } icon: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? (settings.detailTint ?? .yellow) : Color.secondary)
            }
        }
        .disabled(url.isEmpty)
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        .confirmationDialog("Remove from Favorites?", isPresented: $confirmRemoveFavorite) {
            Button("Remove", role: .destructive) {
                if let fav = model.favorites.favorites.first(where: { $0.url == url }) {
                    model.favorites.remove(fav)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var adblockToggle: some View {
        Button {
            model.adblockEnabled.toggle()
        } label: {
            Label("Ad Blocking",
                  systemImage: model.adblockEnabled ? "shield.fill" : "shield.slash")
        }
        .foregroundStyle(model.adblockEnabled ? Color.primary : Color.secondary)
        .help(model.adblockEnabled
              ? "Ad blocking on — click to disable for this window"
              : "Ad blocking off — click to enable for this window")
    }

    // MARK: Downloads

    private var downloadsButton: some View {
        Button {
            showsDownloads.toggle()
            if showsDownloads { downloadsStore.markSeen() }
        } label: {
            Label { Text("Downloads") } icon: { downloadsIcon }
        }
        .help("Downloads")
        .popover(isPresented: $showsDownloads, arrowEdge: .bottom) {
            DownloadsPopoverView(store: downloadsStore,
                                 isPresented: $showsDownloads)
        }
    }

    /// Toolbar glyph: a progress ring while transferring, the plain arrow
    /// otherwise.
    private var downloadsIcon: some View {
        ZStack {
            if let progress = downloadsStore.activeProgress {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1.8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(settings.detailTint ?? .accentColor,
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: progress)
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
            } else {
                Image(systemName: downloadsStore.hasActive
                      ? "arrow.down.circle.dotted" : "arrow.down.circle")
            }
        }
        .frame(width: 16, height: 16)
    }

    // MARK: Find in page

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in page", text: $findText)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .frame(width: 180)
                .onSubmit {
                    model.activeTab?.controller.find(inPage: findText,
                                                     forward: true, findNext: true)
                }
                .onKeyPress(.escape) {
                    closeFindBar()
                    return .handled
                }
            Button {
                model.activeTab?.controller.find(inPage: findText,
                                                 forward: false, findNext: true)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            Button {
                model.activeTab?.controller.find(inPage: findText,
                                                 forward: true, findNext: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            Button {
                closeFindBar()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Solid, not material: overlays float over the CEF surface, which
        // SwiftUI materials cannot sample — blur renders as murky gray.
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .padding(.top, 8)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onChange(of: findText) { _, text in
            if text.isEmpty {
                model.activeTab?.controller.stopFinding()
            } else {
                model.activeTab?.controller.find(inPage: text,
                                                 forward: true, findNext: false)
            }
        }
    }

    private func closeFindBar() {
        model.activeTab?.controller.stopFinding()
        showsFind = false
        findText = ""
    }

    // MARK: Tab overview

    private var tabOverview: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12)],
                      spacing: 12) {
                ForEach(model.tabs) { tab in
                    Button {
                        model.select(tab)
                        showsOverview = false
                    } label: {
                        HStack(spacing: 8) {
                            FaviconView(host: tab.host, size: 20,
                                        fetchOnMiss: !tab.isIncognito)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title)
                                    .lineLimit(1)
                                Text(tab.host ?? "New Tab")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button {
                                model.close(tab)
                                if model.tabs.isEmpty { showsOverview = false }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(tab.id == model.activeTab?.id
                                              ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Solid backdrop: material blur can't sample the CEF surface below.
        .background(Color(nsColor: .windowBackgroundColor))
        .onTapGesture { showsOverview = false }
        .onKeyPress(.escape) {
            showsOverview = false
            return .handled
        }
    }

    // MARK: Address field focus

    /// The field editor installs a beat after focus changes, so retry across
    /// a few run-loop turns until it's up.
    private func selectAllInAddressField(retries: Int = 8) {
        guard addressFocused else { return }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.selectAll(nil)
        } else if retries > 0 {
            // Default mode only — the main queue also drains during click
            // tracking, where the pending mouse-up would collapse the
            // selection to a caret again.
            RunLoop.main.perform(inModes: [.default]) {
                selectAllInAddressField(retries: retries - 1)
            }
        }
    }

    // MARK: History suggestions

    private func navigate(to destination: String) {
        closeSpotlight()
        model.navigateActive(to: destination)
        addressText = model.activeTab?.url ?? destination
    }

    private func moveSuggestionSelection(by delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let count = suggestions.count
        // Down from the field starts at the top; up starts at the bottom.
        let current = selectedSuggestionIndex ?? (delta > 0 ? -1 : count)
        selectedSuggestionIndex = (current + delta + count) % count
        return .handled
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                suggestionRow(suggestion, isSelected: index == selectedSuggestionIndex)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionRow(_ suggestion: HistorySuggestion, isSelected: Bool) -> some View {
        Button {
            navigate(to: suggestion.url)
        } label: {
            HStack(spacing: 8) {
                FaviconView(host: suggestion.host,
                            fallbackSymbol: suggestion.isRootDomain ? "globe" : "clock",
                            size: 14)
                Text(suggestion.title)
                    .lineLimit(1)
                Text(displayURL(suggestion.url))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(isSelected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// Compact URL for suggestion rows: no scheme, no trailing slash.
    private func displayURL(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ZStack {
            // Every tab's web view stays attached; switching flips hidden
            // flags — instant, no CEF reattach. Overlays cover it for the
            // blank/crashed/devtools states.
            BrowserStackView(
                tabs: model.tabs,
                activeID: model.activeTab?.id,
                excludedID: model.activeTab?.devToolsInSidebar == true
                    ? model.activeTab?.id : nil)

            if let tab = model.activeTab {
                if tab.isBlank {
                    NewTabView(favorites: model.favorites.favorites,
                               topSites: model.isIncognito ? [] : model.history.topSites(),
                               focusRequest: model.addressFocusRequest,
                               suggest: { model.history.suggestions(for: $0) }) { url in
                        model.navigateActive(to: url)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                } else if tab.isCrashed {
                    crashedView(for: tab)
                        .background(Color(nsColor: .textBackgroundColor))
                } else if tab.devToolsInSidebar {
                    HSplitView {
                        BrowserView(controller: tab.controller)
                            .frame(minWidth: 300)
                        DevToolsPane(tab: tab)
                            .frame(minWidth: 280, idealWidth: 420)
                    }
                    .id(tab.id)
                }
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
    }
}

/// Sizes a freshly created window to the smallest attached screen's visible
/// area, centered on the screen the window opened on. Runs once per window.
private struct SmallestScreenSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let smallest = NSScreen.screens.min {
                $0.visibleFrame.width * $0.visibleFrame.height <
                $1.visibleFrame.width * $1.visibleFrame.height
            }
            guard let target = smallest?.visibleFrame.size else { return }
            let screen = window.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: target)
            let size = NSSize(width: min(target.width, visible.width),
                              height: min(target.height, visible.height))
            let origin = NSPoint(x: visible.midX - size.width / 2,
                                 y: visible.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Exposes the focused window's browser model to app-level menu commands.
private struct BrowserModelFocusedKey: FocusedValueKey {
    typealias Value = BrowserViewModel
}

extension FocusedValues {
    var browserModel: BrowserViewModel? {
        get { self[BrowserModelFocusedKey.self] }
        set { self[BrowserModelFocusedKey.self] = newValue }
    }
}

/// Applies a ⌘-modified keyboard shortcut when a key is provided.
private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}

extension ContentView {
    fileprivate func crashedView(for tab: Tab) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("This page crashed")
                .font(.title3)
            Button("Reload") {
                tab.reload()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Subtle hover highlight for spotlight favorite tiles (rounded-rect variant
/// of the start-page tile style).
private struct SpotlightTileStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12)
                          : hovering ? Color.primary.opacity(0.06)
                          : Color.clear)
            )
            .onHover { hovering = $0 }
    }
}

#Preview {
    ContentView()
}
