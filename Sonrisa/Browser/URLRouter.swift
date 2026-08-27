//
//  URLRouter.swift
//  Sonrisa
//
//  Routes URLs handed to the app by macOS — links clicked in other apps once
//  Sonrisa is the default browser — into a browser window. URLs that arrive
//  before any window's model has started (cold launch from a link) are queued
//  and drained as soon as one registers.
//

import AppKit

@MainActor
final class URLRouter {
    static let shared = URLRouter()

    private struct WeakModel {
        weak var model: BrowserViewModel?
    }

    private var models: [WeakModel] = []
    private var pending: [URL] = []
    /// A regular window has been requested for queued URLs; don't request
    /// another until a model registers (its startIfNeeded will drain).
    private var awaitingWindow = false

    /// Opens a new regular browser window. Set by ContentView (any window,
    /// incognito included) — used when URLs arrive while only incognito
    /// windows exist: external links never go into incognito.
    var openRegularWindow: (() -> Void)?

    /// A live regular-window model is registered. Used to spot the phantom
    /// duplicate browser window SwiftUI opens at launch.
    var hasLiveRegularModel: Bool {
        models.contains { $0.model != nil }
    }

    /// Live regular-window models, most recently registered last.
    var liveModels: [BrowserViewModel] {
        models.compactMap(\.model)
    }

    /// Called from BrowserViewModel.startIfNeeded() for regular (non-incognito)
    /// windows. The most recently registered live model receives URLs.
    func register(_ model: BrowserViewModel) {
        models.removeAll { $0.model == nil || $0.model === model }
        models.append(WeakModel(model: model))
        awaitingWindow = false
        drain()
    }

    func open(_ urls: [URL]) {
        pending.append(contentsOf: urls)
        drain()
    }

    private func drain() {
        models.removeAll { $0.model == nil }
        guard !pending.isEmpty else { return }
        guard let target = models.last?.model else {
            // Only incognito windows (or none registered yet mid-launch).
            // Ask for a regular window; drain resumes when it registers.
            if !awaitingWindow, let openRegularWindow {
                awaitingWindow = true
                openRegularWindow()
            }
            return
        }
        let urls = pending
        pending.removeAll()
        for url in urls { target.openInNewTab(url.absoluteString) }
        // Raise the receiving window: NSApp.activate() alone leaves the
        // window order untouched (and cooperative activation may not even
        // bring the app forward when the sender doesn't yield focus).
        // The just-opened tab's view isn't attached to a window yet, so
        // look through the model's existing tabs for the hosting window.
        if let window = target.tabs.lazy
            .compactMap({ $0.controller.containerView.window }).first {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
