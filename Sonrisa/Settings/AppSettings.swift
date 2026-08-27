//
//  AppSettings.swift
//  Sonrisa
//
//  User-configurable settings, persisted to UserDefaults.
//

import SwiftUI
import Observation

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckduckgo
    case ecosia
    case google
    case bing
    case startpage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .duckduckgo: "DuckDuckGo"
        case .ecosia: "Ecosia"
        case .google: "Google"
        case .bing: "Bing"
        case .startpage: "Startpage"
        }
    }

    /// Short blurb shown in the first-launch chooser.
    var blurb: String {
        switch self {
        case .duckduckgo: "Privacy-focused, doesn't track you"
        case .ecosia: "Plants trees with its ad revenue"
        case .google: "The most widely used search engine"
        case .bing: "Microsoft's search engine"
        case .startpage: "Google results, without the tracking"
        }
    }

    var homepage: String {
        switch self {
        case .duckduckgo: "https://duckduckgo.com"
        case .ecosia: "https://www.ecosia.org"
        case .google: "https://www.google.com"
        case .bing: "https://www.bing.com"
        case .startpage: "https://www.startpage.com"
        }
    }

    /// Returns the search-results URL for a percent-encoded query.
    func searchURL(for encodedQuery: String) -> String {
        switch self {
        case .duckduckgo: "https://duckduckgo.com/?q=\(encodedQuery)"
        case .ecosia: "https://www.ecosia.org/search?q=\(encodedQuery)"
        case .google: "https://www.google.com/search?q=\(encodedQuery)"
        case .bing: "https://www.bing.com/search?q=\(encodedQuery)"
        case .startpage: "https://www.startpage.com/sp/search?query=\(encodedQuery)"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case system
    case orange
    case blue
    case purple
    case pink
    case green

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .orange: "Orange"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .green: "Green"
        }
    }

    var color: Color {
        switch self {
        case .system: .accentColor
        case .orange: .orange
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .green: .green
        }
    }
}

enum DevToolsPlacement: String, CaseIterable, Identifiable {
    case sidebar
    case window

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .sidebar: "Sidebar"
        case .window: "Separate Window"
        }
    }

    /// The docked sidebar embeds the DevTools frontend served by the CDP
    /// port, which only Debug builds expose — Release always uses the
    /// native DevTools window.
    static var sidebarAvailable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Placement after applying build-capability limits.
    var effective: DevToolsPlacement {
        Self.sidebarAvailable ? self : .window
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var searchEngine: SearchEngine {
        didSet { defaults.set(searchEngine.rawValue, forKey: Keys.searchEngine) }
    }

    /// Start page URL for new tabs. Empty means "use the search engine's home".
    var startPage: String {
        didSet { defaults.set(startPage, forKey: Keys.startPage) }
    }

    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            Self.apply(appearance)
        }
    }

    var accent: AccentChoice {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    /// Colorful chrome: accent washes over the bars, tinted folder icons,
    /// accent star and active-tab capsule. Off = the simple plain look.
    var colorfulChrome: Bool {
        didSet { defaults.set(colorfulChrome, forKey: Keys.colorfulChrome) }
    }

    /// Reopen last session's tabs on launch (regular windows only).
    var restoreSession: Bool {
        didSet { defaults.set(restoreSession, forKey: Keys.restoreSession) }
    }

    /// Show the favorites bar under the toolbar.
    var showFavoritesBar: Bool {
        didSet { defaults.set(showFavoritesBar, forKey: Keys.showFavoritesBar) }
    }

    /// Where DevTools opens: docked as a sidebar or in a separate window.
    var devToolsPlacement: DevToolsPlacement {
        didSet { defaults.set(devToolsPlacement.rawValue, forKey: Keys.devToolsPlacement) }
    }

    /// Block requests to known ad/tracker hosts.
    var blockAds: Bool {
        didSet {
            defaults.set(blockAds, forKey: Keys.blockAds)
            AdBlocker.setEnabled(blockAds)
        }
    }

    /// Ids from DeeplinkApp.all whose URL schemes may open the matching app.
    var enabledDeeplinks: Set<String> {
        didSet {
            defaults.set(Array(enabledDeeplinks).sorted(), forKey: Keys.enabledDeeplinks)
            Self.pushDeeplinkSchemes(enabledDeeplinks)
        }
    }

    private static func pushDeeplinkSchemes(_ ids: Set<String>) {
        let schemes = DeeplinkApp.all
            .filter { ids.contains($0.id) }
            .flatMap(\.schemes)
        SonrisaDeeplinkSetAllowedSchemes(schemes)
    }

    /// Accent used by the chrome flourishes; nil when the simple look is on.
    var chromeTint: Color? { colorfulChrome ? accent.color : nil }

    /// Accent for small details (favorite star, folder icons, address ring).
    /// Colored whenever the user picked an explicit accent color, even with
    /// the simple look; nil only for the plain system default.
    var detailTint: Color? {
        colorfulChrome || accent != .system ? accent.color : nil
    }

    /// Whether the user has picked a search engine in the first-launch chooser.
    var hasChosenSearchEngine: Bool {
        didSet { defaults.set(hasChosenSearchEngine, forKey: Keys.hasChosenSearchEngine) }
    }

    /// Effective URL for a new tab.
    var resolvedStartPage: String {
        let trimmed = startPage.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? searchEngine.homepage : URLNormalizer.normalize(trimmed)
    }

    static func apply(_ appearance: AppAppearance) {
        NSApp.appearance = appearance.nsAppearance
    }

    private enum Keys {
        static let searchEngine = "settings.searchEngine"
        static let startPage = "settings.startPage"
        static let appearance = "settings.appearance"
        static let accent = "settings.accent"
        static let colorfulChrome = "settings.colorfulChrome"
        static let restoreSession = "settings.restoreSession"
        static let blockAds = "settings.blockAds"
        static let devToolsPlacement = "settings.devToolsPlacement"
        static let showFavoritesBar = "settings.showFavoritesBar"
        static let hasChosenSearchEngine = "settings.hasChosenSearchEngine"
        static let enabledDeeplinks = "settings.enabledDeeplinks"
    }

    private let defaults = UserDefaults.standard

    private init() {
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: Keys.searchEngine) ?? "") ?? .duckduckgo
        startPage = defaults.string(forKey: Keys.startPage) ?? ""
        appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        accent = AccentChoice(rawValue: defaults.string(forKey: Keys.accent) ?? "") ?? .system
        colorfulChrome = defaults.bool(forKey: Keys.colorfulChrome)
        // Defaults to on; bool(forKey:) alone would default new users to off.
        restoreSession = defaults.object(forKey: Keys.restoreSession) as? Bool ?? true
        blockAds = defaults.object(forKey: Keys.blockAds) as? Bool ?? true
        devToolsPlacement = DevToolsPlacement(
            rawValue: defaults.string(forKey: Keys.devToolsPlacement) ?? "") ?? .sidebar
        // Defaults to on, like restoreSession above.
        showFavoritesBar = defaults.object(forKey: Keys.showFavoritesBar) as? Bool ?? true
        hasChosenSearchEngine = defaults.bool(forKey: Keys.hasChosenSearchEngine)
        enabledDeeplinks = (defaults.stringArray(forKey: Keys.enabledDeeplinks)
                            .map(Set.init)) ?? DeeplinkApp.defaultEnabled
        Self.pushDeeplinkSchemes(enabledDeeplinks)
    }
}
