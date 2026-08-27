//
//  SonrisaApp.swift
//  Sonrisa
//
//  A minimal Chromium-based browser. CEF is initialized as early as possible in
//  the app lifecycle, before any browser tab is created.
//

import SwiftUI
import AppKit

// Note: no @main attribute — the entry point is main.swift, which handles CEF
// sub-process launches before starting the app.
struct SonrisaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Two plain groups instead of one value-based (for: Bool.self)
        // group: value-based openWindow(value: true) deduplicates against a
        // phantom scene SwiftUI instantiates at launch and silently refuses
        // to open the incognito window. Plain groups always open new windows.
        WindowGroup(id: "browser") {
            ContentView()
        }
        // Native unified toolbar (Liquid Glass islands); no window title text.
        .windowToolbarStyle(.unified(showsTitle: false))
        // Never claim external URL events: SwiftUI would open a NEW window
        // per clicked link. AppDelegate application(_:open:) routes them
        // into an existing window via URLRouter instead.
        .handlesExternalEvents(matching: [])
        .commands {
            NewWindowCommands()
            BrowserCommands()
            CommandMenu("History") {
                HistoryCommands()
            }
            CommandMenu("Developer") {
                DeveloperCommands()
            }
        }

        WindowGroup(id: "incognito") {
            ContentView(incognito: true)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        // Incognito windows never open on launch and never restore.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
        }
    }
}

/// File-menu additions: an incognito sibling to the standard New Window.
private struct NewWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Incognito Window") {
                openWindow(id: "incognito")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}

/// Menu commands that act on the focused window's browser model.
private struct BrowserCommands: Commands {
    @FocusedValue(\.browserModel) private var model

    var body: some Commands {
        // File: tab lifecycle. Replaces the standard Close (⌘W) so it closes
        // the tab, with Close Window on ⌘⇧W.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if let model, let tab = model.activeTab { model.close(tab) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model == nil)

            Button("Close Window") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])

            Button("Reopen Closed Tab") {
                model?.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model == nil)

            Divider()

            Button("Open Location…") {
                model?.requestAddressFocus()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model == nil)

            Button("Print…") {
                model?.activeTab?.controller.printPage()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(model == nil)

            Button("Translate Page") {
                guard let model, let tab = model.activeTab,
                      tab.url.hasPrefix("http"),
                      let encoded = tab.url.addingPercentEncoding(
                          withAllowedCharacters: .urlQueryAllowed) else { return }
                let target = Locale.current.language.languageCode?.identifier ?? "en"
                model.openInNewTab(
                    "https://translate.google.com/translate?sl=auto&tl=\(target)&u=\(encoded)")
            }
            .disabled(model?.activeTab?.url.hasPrefix("http") != true)
        }

        // Edit: find.
        CommandGroup(after: .undoRedo) {
            Button("Find in Page…") {
                model?.requestFind()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model == nil)
        }

        // View: reload / stop, then zoom.
        CommandGroup(after: .toolbar) {
            Button("Reload Page") {
                model?.activeTab?.reload()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model == nil)

            Button("Reload Ignoring Cache") {
                model?.activeTab?.isCrashed = false
                model?.activeTab?.controller.reloadIgnoringCache()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button("Stop Loading") {
                model?.activeTab?.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(model?.activeTab?.isLoading != true)

            Divider()

            Button("Zoom In") {
                model?.activeTab?.controller.zoom(by: 0.5)
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(model == nil)

            Button("Zoom Out") {
                model?.activeTab?.controller.zoom(by: -0.5)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(model == nil)

            Button("Actual Size") {
                model?.activeTab?.controller.zoomReset()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(model == nil)
        }

        // Window: tab switching.
        CommandGroup(before: .windowArrangement) {
            Button("Show All Tabs") {
                model?.requestOverview()
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button("Show Next Tab") {
                model?.selectAdjacentTab(offset: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(model == nil)

            Button("Show Previous Tab") {
                model?.selectAdjacentTab(offset: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(model == nil)

            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") {
                    model?.selectTab(number: number)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                .disabled(model == nil)
            }

            Divider()
        }
    }
}

/// Developer-menu contents, acting on the focused window's active tab.
private struct DeveloperCommands: View {
    @FocusedValue(\.browserModel) private var model
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Button("Toggle Developer Tools") {
            guard let tab = model?.activeTab else { return }
            if settings.devToolsPlacement.effective == .sidebar {
                if tab.devToolsInSidebar {
                    tab.devToolsInSidebar = false
                    tab.closeDevToolsPane()
                } else {
                    tab.devToolsInSidebar = true
                }
            } else {
                if tab.controller.hasDevTools() {
                    tab.controller.closeDevTools()
                } else {
                    tab.controller.showDevToolsInWindow()
                }
            }
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(model?.activeTab == nil)

        Button("View Page Source") {
            guard let model, let tab = model.activeTab,
                  !tab.url.isEmpty, tab.url != "about:blank",
                  !tab.url.hasPrefix("view-source:") else { return }
            model.openInNewTab("view-source:\(tab.url)")
        }
        .keyboardShortcut("u", modifiers: [.command, .option])
        .disabled(model?.activeTab == nil)

        if DevToolsPlacement.sidebarAvailable {
            Picker("Developer Tools Location", selection: $settings.devToolsPlacement) {
                ForEach(DevToolsPlacement.allCases) { placement in
                    Text(placement.displayName).tag(placement)
                }
            }
            .pickerStyle(.inline)
        }

        Divider()

        Button("Reload Ignoring Cache") {
            model?.activeTab?.controller.reloadIgnoringCache()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(model?.activeTab == nil)
    }
}

/// History-menu contents, acting on the focused window.
private struct HistoryCommands: View {
    @FocusedValue(\.browserModel) private var model

    var body: some View {
        Button("Show History") {
            model?.requestHistory()
        }
        .keyboardShortcut("y", modifiers: .command)
        .disabled(model == nil)

        // ⌘[ / ⌘] live on the toolbar buttons; menu items are click-only so
        // the shortcuts aren't registered twice.
        Button("Back") {
            model?.activeTab?.goBack()
        }
        .disabled(model?.activeTab?.canGoBack != true)

        Button("Forward") {
            model?.activeTab?.goForward()
        }
        .disabled(model?.activeTab?.canGoForward != true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Sonrisa has its own tab strip — disable macOS window tabbing and its
        // menu items (Show Tab Bar, Merge All Windows, …).
        NSWindow.allowsAutomaticWindowTabbing = false

        // "Open in <app>?" prompts for enabled deeplink schemes.
        DeeplinkPrompter.shared.start()

        // URLs handed over by a second app instance that launched against the
        // same profile (link clicks resolving to another copy of the bundle);
        // CEFRuntime's OnAlreadyRunningAppRelaunch posts them.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("SonrisaOpenURLsFromRelaunch"),
            object: nil, queue: .main
        ) { note in
            guard let strings = note.userInfo?["urls"] as? [String] else { return }
            let urls = strings.compactMap(URL.init(string:))
            guard !urls.isEmpty else { return }
            MainActor.assumeIsolated {
                URLRouter.shared.open(urls)
            }
        }
        // Same handoff, but for URLs that reached the second instance as a
        // GetURL Apple Event (real link clicks) — forwarded cross-process
        // just before that instance exits.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("nl.pieterhielkema.Sonrisa.relaunch-urls"),
            object: nil, queue: .main
        ) { note in
            guard let joined = note.object as? String else { return }
            let urls = joined.split(separator: "\n").compactMap { URL(string: String($0)) }
            guard !urls.isEmpty else { return }
            MainActor.assumeIsolated {
                URLRouter.shared.open(urls)
            }
        }

        AppSettings.apply(AppSettings.shared.appearance)
        AdBlocker.bootstrap()

        // Must run before the first tab creates a browser.
        if !CEFRuntime.initializeBrowserProcess() {
            NSLog("[Sonrisa] Chromium runtime failed to initialize.")
            if CEFRuntime.isRelaunchHandoff() {
                // Another instance owns the profile. Stay headless just long
                // enough for the GetURL Apple Event (the clicked link) to
                // arrive in application:openURLs:, which forwards it; the
                // timeout covers launches with no URL at all.
                NSApp.setActivationPolicy(.prohibited)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    exit(0)
                }
            }
        }
    }

    // Note: quit/CEF teardown is handled in SonrisaApplication.terminate(_:) —
    // the SwiftUI delegate adaptor does not reliably forward
    // applicationShouldTerminate:, so don't add lifecycle logic here.

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// URLs from other apps (Sonrisa as default browser, or `open -a Sonrisa
    /// <url>`). Fires on cold launch too — the router queues until a window's
    /// model has started.
    func application(_ application: NSApplication, open urls: [URL]) {
        if CEFRuntime.isRelaunchHandoff() {
            // Hand the clicked link to the running instance and bow out.
            let joined = urls.map(\.absoluteString)
                .filter {
                    $0.hasPrefix("http://") || $0.hasPrefix("https://")
                        || $0.hasPrefix("file://")
                }
                .joined(separator: "\n")
            if !joined.isEmpty {
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("nl.pieterhielkema.Sonrisa.relaunch-urls"),
                    object: joined, userInfo: nil, deliverImmediately: true)
            }
            DispatchQueue.main.async { exit(0) }
            return
        }
        URLRouter.shared.open(urls)
    }
}
