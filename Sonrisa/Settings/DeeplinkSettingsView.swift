//
//  DeeplinkSettingsView.swift
//  Sonrisa
//
//  "Deeplinks" settings tab: per-app toggles for custom URL schemes that
//  open Mac apps (spotify:, zoommtg:, …). Enabled schemes are handed to the
//  OS when a page navigates to them; everything else is blocked.
//

import SwiftUI
import AppKit

struct DeeplinkApp: Identifiable {
    /// Stable key persisted in UserDefaults — never rename.
    let id: String
    let name: String
    /// Lowercase schemes, no colon.
    let schemes: [String]
    /// SF symbol shown when the app isn't installed.
    let fallbackSymbol: String
    /// Web domains that can also open in the app (suffix match) — visiting
    /// one prompts "Open in <app>?" like Safari does.
    var webHosts: [String] = []

    static let all: [DeeplinkApp] = [
        .init(id: "appstore", name: "App Store",
              schemes: ["itms-apps", "macappstore"], fallbackSymbol: "storefront",
              webHosts: ["apps.apple.com", "itunes.apple.com"]),
        .init(id: "music", name: "Apple Music",
              schemes: ["music", "itmss"], fallbackSymbol: "music.note",
              webHosts: ["music.apple.com"]),
        .init(id: "maps", name: "Apple Maps",
              schemes: ["maps"], fallbackSymbol: "map",
              webHosts: ["maps.apple.com"]),
        .init(id: "facetime", name: "FaceTime",
              schemes: ["facetime", "facetime-audio", "tel"], fallbackSymbol: "video"),
        .init(id: "mail", name: "Mail",
              schemes: ["mailto"], fallbackSymbol: "envelope"),
        .init(id: "spotify", name: "Spotify",
              schemes: ["spotify"], fallbackSymbol: "music.note.list",
              webHosts: ["open.spotify.com"]),
        .init(id: "zoom", name: "Zoom",
              schemes: ["zoommtg", "zoomus"], fallbackSymbol: "video.bubble",
              webHosts: ["zoom.us"]),
        .init(id: "slack", name: "Slack",
              schemes: ["slack"], fallbackSymbol: "number",
              webHosts: ["app.slack.com"]),
        .init(id: "discord", name: "Discord",
              schemes: ["discord"], fallbackSymbol: "bubble.left.and.bubble.right",
              webHosts: ["discord.gg", "discord.com"]),
        .init(id: "teams", name: "Microsoft Teams",
              schemes: ["msteams"], fallbackSymbol: "person.2",
              webHosts: ["teams.microsoft.com"]),
        .init(id: "whatsapp", name: "WhatsApp",
              schemes: ["whatsapp"], fallbackSymbol: "phone",
              webHosts: ["wa.me", "chat.whatsapp.com", "api.whatsapp.com"]),
        .init(id: "telegram", name: "Telegram",
              schemes: ["tg"], fallbackSymbol: "paperplane",
              webHosts: ["t.me"]),
        .init(id: "steam", name: "Steam",
              schemes: ["steam"], fallbackSymbol: "gamecontroller",
              webHosts: ["store.steampowered.com", "steamcommunity.com"]),
        .init(id: "vscode", name: "Visual Studio Code",
              schemes: ["vscode"], fallbackSymbol: "chevron.left.forwardslash.chevron.right"),
        .init(id: "figma", name: "Figma",
              schemes: ["figma"], fallbackSymbol: "paintpalette",
              webHosts: ["figma.com"]),
        .init(id: "notion", name: "Notion",
              schemes: ["notion"], fallbackSymbol: "note.text",
              webHosts: ["notion.so"]),
    ]

    /// Apple apps are on by default; third-party ones opt in.
    static let defaultEnabled: Set<String> =
        ["appstore", "music", "maps", "facetime", "mail"]

    /// The app registered for this deeplink's primary scheme, if any.
    var installedAppURL: URL? {
        guard let probe = URL(string: "\(schemes[0])://") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }
}

/// Drives the "Opening <app>…" card shown over the page after the user
/// confirms a redirect. Auto-hides; the card's close button hides it sooner.
@MainActor
@Observable
final class DeeplinkRedirect {
    static let shared = DeeplinkRedirect()

    private(set) var appName: String?
    private(set) var appIcon: NSImage?
    private var hideTask: Task<Void, Never>?

    func show(name: String, icon: NSImage) {
        appName = name
        appIcon = icon
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        appName = nil
        appIcon = nil
    }
}

/// Centered card over the page: app icon, "Opening <app>…", close button.
struct DeeplinkRedirectOverlay: View {
    private var redirect = DeeplinkRedirect.shared

    var body: some View {
        ZStack {
            if let name = redirect.appName {
                VStack(spacing: 12) {
                    if let icon = redirect.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    Text("Opening \(name)…")
                        .font(.title3.weight(.semibold))
                    Text("You're being redirected to the \(name) app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                // Solid, not material: overlays float over the CEF surface,
                // which materials can't blur.
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
                )
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.quaternary))
                .overlay(alignment: .topTrailing) {
                    Button {
                        redirect.hide()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help("Dismiss")
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: redirect.appName)
        .allowsHitTesting(redirect.appName != nil)
    }
}

/// Shows the "Open in <app>?" prompt when a page navigates to an enabled
/// deeplink scheme (posted from CEF's OnProtocolExecution).
@MainActor
final class DeeplinkPrompter {
    static let shared = DeeplinkPrompter()
    private var isPrompting = false

    func start() {
        NotificationCenter.default.addObserver(
            forName: Notification.Name("SonrisaDeeplinkRequested"),
            object: nil, queue: .main
        ) { note in
            guard let urlString = note.object as? String else { return }
            MainActor.assumeIsolated {
                DeeplinkPrompter.shared.promptScheme(urlString)
            }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("SonrisaAppLinkRequested"),
            object: nil, queue: .main
        ) { note in
            guard let urlString = note.object as? String else { return }
            MainActor.assumeIsolated {
                DeeplinkPrompter.shared.promptAppLink(urlString)
            }
        }
    }

    /// Custom-scheme navigation (spotify:, zoommtg:, …).
    private func promptScheme(_ urlString: String) {
        guard let url = URL(string: urlString),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url)
        else { return }
        ask(appURL: appURL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Regular web link on a host that can also open in an app
    /// (open.spotify.com, apps.apple.com, …). The page loads normally;
    /// picking the app closes the web version again (back where it came
    /// from, or the tab entirely when there's nothing to go back to).
    private func promptAppLink(_ urlString: String) {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased()
        else { return }
        let enabled = AppSettings.shared.enabledDeeplinks
        guard let app = DeeplinkApp.all.first(where: { app in
            enabled.contains(app.id) && app.webHosts.contains {
                host == $0 || host.hasSuffix("." + $0)
            }
        }), let appURL = app.installedAppURL else { return }
        ask(appURL: appURL, stayTitle: "Stay in Browser") {
            NSWorkspace.shared.open(
                [url], withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration())
            self.closeWebTab(host: host, retriesLeft: 2)
        }
    }

    /// Leaves the web copy of the page: back if the tab has history, close
    /// otherwise. The navigation may not have committed when the user
    /// confirms — retry briefly until the tab shows the host.
    private func closeWebTab(host: String, retriesLeft: Int) {
        for model in URLRouter.shared.liveModels.reversed() {
            let candidates = [model.activeTab].compactMap { $0 } + model.tabs
            if let tab = candidates.first(where: {
                URL(string: $0.url)?.host?.lowercased() == host
            }) {
                if tab.canGoBack {
                    tab.goBack()
                } else {
                    model.close(tab)
                }
                return
            }
        }
        guard retriesLeft > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.closeWebTab(host: host, retriesLeft: retriesLeft - 1)
        }
    }

    /// Pages can fire the same target several times (retry timers) —
    /// one sheet at a time.
    private func ask(appURL: URL, stayTitle: String = "Cancel",
                     onOpen: @escaping () -> Void,
                     onDecline: (() -> Void)? = nil) {
        guard !isPrompting,
              let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let appName = (FileManager.default.displayName(atPath: appURL.path)
                       as NSString).deletingPathExtension
        isPrompting = true
        let alert = NSAlert()
        alert.messageText = "Open in \(appName)?"
        alert.informativeText = "This link can open in the \(appName) app."
        alert.icon = NSWorkspace.shared.icon(forFile: appURL.path)
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: stayTitle)
        alert.beginSheetModal(for: window) { response in
            self.isPrompting = false
            if response == .alertFirstButtonReturn {
                DeeplinkRedirect.shared.show(
                    name: appName,
                    icon: NSWorkspace.shared.icon(forFile: appURL.path))
                onOpen()
            } else {
                onDecline?()
            }
        }
    }
}

struct DeeplinkSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(DeeplinkApp.all) { app in
                    DeeplinkRow(app: app, settings: settings)
                }
            } header: {
                Text("Allow links to open these apps")
            } footer: {
                Text("Pages can link straight into a Mac app (spotify:, zoommtg:, …). Only enabled apps open; other app links are blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DeeplinkRow: View {
    let app: DeeplinkApp
    let settings: AppSettings

    @State private var appURL: URL?

    private var isEnabled: Binding<Bool> {
        Binding {
            settings.enabledDeeplinks.contains(app.id)
        } set: { enabled in
            if enabled {
                settings.enabledDeeplinks.insert(app.id)
            } else {
                settings.enabledDeeplinks.remove(app.id)
            }
        }
    }

    var body: some View {
        Toggle(isOn: isEnabled) {
            HStack(spacing: 10) {
                if let appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: app.fallbackSymbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                    Text(app.schemes.map { "\($0):" }.joined(separator: "  ")
                         + (appURL == nil ? "  — not installed" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { appURL = app.installedAppURL }
    }
}
