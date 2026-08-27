//
//  Tab.swift
//  Sonrisa
//
//  Observable model for a single browser tab, wired to its CEF controller.
//

import AppKit
import Observation

@MainActor
@Observable
final class Tab: Identifiable {
    let id = UUID()

    var title: String = "New Tab"
    var url: String
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    /// Host of the current page, used to look up a cached favicon.
    var host: String?
    /// True for a fresh empty tab that hasn't navigated anywhere yet; the
    /// start page (favorites grid) is shown instead of web content.
    var isBlank: Bool { url.isEmpty || url == "about:blank" }
    /// Set when the page submitted login credentials worth saving; drives the
    /// "Save password?" banner.
    var pendingPasswordSave: PendingPasswordSave?
    /// The renderer died; the content area shows a reload UI.
    var isCrashed: Bool = false
    /// Mirrors the browser's audio-mute state for the tab chip menu.
    var isMuted: Bool = false
    /// Pinned tabs render favicon-only at the front of the strip.
    var isPinned: Bool = false
    /// Group this tab belongs to; nil means the implicit "Default" group.
    var groupID: UUID?
    /// DevTools shown docked in the sidebar for this tab.
    var devToolsInSidebar: Bool = false
    /// Browser hosting the DevTools web frontend for the sidebar pane
    /// (chrome-style ShowDevTools can't dock natively). Created by
    /// DevToolsPane, torn down when the pane or tab closes.
    var devToolsController: CEFBrowserController?
    /// The page is in HTML5 fullscreen (video player etc.) — chrome hides.
    var isHTMLFullscreen: Bool = false

    let controller: CEFBrowserController

    /// Fired when a page finishes loading, so history can record the visit.
    var onVisit: ((_ url: String, _ title: String) -> Void)?
    /// Fired when the page title changes, so history can refresh stored titles.
    var onTitleUpdated: ((_ url: String, _ title: String) -> Void)?

    /// True when the tab browses in the shared in-memory incognito context;
    /// nothing it does is persisted (history, favicons, passwords).
    let isIncognito: Bool

    /// Pass `nil` for an empty tab that loads nothing (address bar takes focus).
    init(url: String?, incognito: Bool = false) {
        isIncognito = incognito
        if let url {
            let normalized = URLNormalizer.normalize(url)
            self.url = normalized
            self.controller = CEFBrowserController(url: normalized, incognito: incognito)
        } else {
            self.url = ""
            self.controller = CEFBrowserController(url: "about:blank", incognito: incognito)
        }
        wireCallbacks()
    }

    private func wireCallbacks() {
        controller.onTitleChanged = { [weak self] title in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.title = title.isEmpty ? "Untitled" : title
                self.onTitleUpdated?(self.url, self.title)
            }
        }
        controller.onURLChanged = { [weak self] url in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.url = url
                let newHost = URL(string: url)?.host()
                if newHost != self.host {
                    // A stale save prompt must not outlive its site.
                    self.pendingPasswordSave = nil
                }
                self.host = newHost
            }
        }
        controller.onLoadingStateChanged = { [weak self] loading, back, forward in
            MainActor.assumeIsolated {
                guard let self else { return }
                let finishedLoad = self.isLoading && !loading
                self.isLoading = loading
                self.canGoBack = back
                self.canGoForward = forward
                if finishedLoad {
                    self.onVisit?(self.url, self.title)
                }
            }
        }
        // Incognito leaves no trace: favicons aren't written to the disk
        // cache and submitted passwords are never offered for saving.
        if !isIncognito {
            controller.onFaviconReady = { host, png in
                MainActor.assumeIsolated {
                    FaviconCache.shared.store(png: png, for: host)
                }
            }
        }
        controller.onRenderProcessCrashed = { [weak self] in
            MainActor.assumeIsolated {
                self?.isCrashed = true
            }
        }
        controller.onFullscreenModeChanged = { [weak self] fullscreen in
            MainActor.assumeIsolated {
                self?.isHTMLFullscreen = fullscreen
            }
        }
        controller.onDownloadUpdated = { id, path, received, total, complete, canceled in
            MainActor.assumeIsolated {
                DownloadsStore.shared.update(id: id, path: path, received: received,
                                             total: total, complete: complete,
                                             canceled: canceled)
            }
        }
        controller.onPermissionRequested = { origin, permissions, completion in
            MainActor.assumeIsolated {
                PermissionPrompt.present(origin: origin, permissions: permissions,
                                         completion: completion)
            }
        }
        controller.onAuthRequested = { host, port, realm, completion in
            MainActor.assumeIsolated {
                AuthPrompt.present(host: host, port: Int(port), realm: realm,
                                   completion: completion)
            }
        }
        controller.onFormValuesRequested = { host, field in
            MainActor.assumeIsolated {
                FormDataStore.shared.values(host: host, field: field)
            }
        }
        if !isIncognito {
            controller.onFormValueSubmitted = { host, field, value in
                MainActor.assumeIsolated {
                    FormDataStore.shared.record(host: host, field: field, value: value)
                }
            }
        }
        controller.onPasswordsRequested = { host in
            MainActor.assumeIsolated {
                PasswordStore.shared.passwords(for: host).map {
                    ["username": $0.username, "password": $0.password]
                }
            }
        }
        if !isIncognito {
            controller.onPasswordSubmitted = { [weak self] host, username, password in
                MainActor.assumeIsolated {
                    guard let self,
                          let offer = PasswordStore.shared.offer(
                              host: host, username: username, password: password)
                    else { return }
                    self.pendingPasswordSave = PendingPasswordSave(
                        host: host, username: username, password: password,
                        isUpdate: offer == .update)
                }
            }
        }
    }

    func load(_ input: String) {
        let normalized = URLNormalizer.normalize(input)
        url = normalized
        isCrashed = false
        controller.loadURL(normalized)
    }

    func toggleMute() {
        isMuted.toggle()
        controller.setAudioMuted(isMuted)
    }

    func goBack() { controller.goBack() }
    func goForward() { controller.goForward() }
    func reload() { isCrashed = false; controller.reload() }
    func stop() { controller.stopLoad() }

    func close() {
        closeDevToolsPane()
        controller.close()
    }

    /// Tears down the sidebar DevTools frontend browser, if any.
    func closeDevToolsPane() {
        devToolsController?.close()
        devToolsController = nil
    }
}

/// Credentials a page submitted, waiting for the user's save/never/dismiss
/// decision in the banner.
struct PendingPasswordSave: Equatable {
    let host: String
    let username: String
    let password: String
    /// True when a different password is already saved for this login.
    let isUpdate: Bool
}

/// Turns free-form address-bar input into a loadable URL: passes through real
/// URLs, adds a scheme to bare hosts, and otherwise runs a web search.
enum URLNormalizer {
    static func normalize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "about:blank" }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("about:") || trimmed.hasPrefix("file://")
            || trimmed.hasPrefix("view-source:") {
            return trimmed
        }

        // Filesystem path (absolute or ~-relative) → file URL. Only for
        // paths that exist, so stray "/foo bar" input still falls through
        // to search.
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded).absoluteString
            }
        }

        // localhost (optionally with port and/or path) → plain http, since
        // local dev servers rarely have TLS.
        if !trimmed.contains(" ") {
            let host = trimmed.prefix(while: { $0 != ":" && $0 != "/" })
            if host.lowercased() == "localhost" {
                return "http://\(trimmed)"
            }
        }

        // Looks like a domain (has a dot, no spaces) → assume https.
        if trimmed.contains("."), !trimmed.contains(" ") {
            return "https://\(trimmed)"
        }

        // Otherwise treat as a search query using the configured engine.
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return AppSettings.shared.searchEngine.searchURL(for: query)
    }
}
