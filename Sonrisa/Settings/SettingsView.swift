//
//  SettingsView.swift
//  Sonrisa
//
//  The app's Settings window (⌘,) — standard macOS toolbar-style tabs.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            PasswordsSettingsView()
                .tabItem { Label("Passwords", systemImage: "key") }
            DeeplinkSettingsView()
                .tabItem { Label("Deeplinks", systemImage: "arrow.up.forward.app") }
        }
        .frame(width: 440)
    }
}

private struct GeneralSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var showsClearHistoryConfirmation = false
    /// Bumped after a set-default attempt so `isDefaultBrowser` re-evaluates.
    @State private var defaultCheck = 0

    private var history = HistoryStore.shared

    private var isDefaultBrowser: Bool {
        _ = defaultCheck
        guard let handler = NSWorkspace.shared.urlForApplication(
            toOpen: URL(string: "http://example.com")!) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    var body: some View {
        Form {
            Picker("Search engine:", selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }

            TextField("Start page:", text: $settings.startPage,
                      prompt: Text(settings.searchEngine.homepage))
            Text("New tabs open this page. Leave empty to use the search engine's home page.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section {
                LabeledContent("Default browser:") {
                    if isDefaultBrowser {
                        Text("Sonrisa is the default browser")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Set as Default…") {
                            // macOS shows its own confirmation dialog.
                            NSWorkspace.shared.setDefaultApplication(
                                at: Bundle.main.bundleURL,
                                toOpenURLsWithScheme: "http") { _ in
                                DispatchQueue.main.async { defaultCheck += 1 }
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent("History:") {
                    Button("Clear History…") {
                        showsClearHistoryConfirmation = true
                    }
                    .disabled(history.entries.isEmpty)
                }
                Text("History powers the address bar's suggestions. \(history.entries.count) pages remembered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .confirmationDialog("Clear browsing history?",
                            isPresented: $showsClearHistoryConfirmation) {
            Button("Clear History", role: .destructive) {
                history.clear()
            }
        } message: {
            Text("This removes all remembered pages and address bar suggestions.")
        }
    }
}

private struct AppearanceSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var confirmClearData = false

    var body: some View {
        Form {
            Picker("Appearance:", selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Accent color:") {
                HStack(spacing: 8) {
                    ForEach(AccentChoice.allCases) { accent in
                        accentSwatch(accent)
                    }
                }
            }

            Toggle("Colorful toolbars", isOn: $settings.colorfulChrome)
                .help("Tint the toolbars and start page with the accent color")

            Toggle("Show favorites bar", isOn: $settings.showFavoritesBar)
                .help("Show the favorites bar below the toolbar")

            Toggle("Restore tabs from last session", isOn: $settings.restoreSession)
                .help("Reopen the tabs you had open when the app last quit")

            Toggle("Block ads and trackers", isOn: $settings.blockAds)
                .help("Blocks requests to known advertising and tracking hosts")

            LabeledContent("Privacy:") {
                Button("Clear Browsing Data…") {
                    confirmClearData = true
                }
                .confirmationDialog(
                    "Clear history, cookies, and cached icons?",
                    isPresented: $confirmClearData) {
                    Button("Clear", role: .destructive) {
                        HistoryStore.shared.clear()
                        FaviconCache.shared.removeAll()
                        FormDataStore.shared.removeAll()
                        CEFRuntime.clearCookies()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Signs you out of most sites. Cached page data clears on next launch.")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    /// System Settings-style color swatch: a filled circle with a selection ring.
    private func accentSwatch(_ accent: AccentChoice) -> some View {
        Button {
            settings.accent = accent
        } label: {
            ZStack {
                Circle()
                    .fill(accent == .system ? AnyShapeStyle(.conicGradient(
                        colors: [.blue, .purple, .pink, .orange, .green, .blue],
                        center: .center)) : AnyShapeStyle(accent.color))
                    .frame(width: 16, height: 16)
                if settings.accent == accent {
                    Circle()
                        .strokeBorder(.primary, lineWidth: 1.5)
                        .frame(width: 21, height: 21)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(accent.displayName)
    }
}

#Preview {
    SettingsView()
}
