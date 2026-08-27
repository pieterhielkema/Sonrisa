//
//  BrowserView.swift
//  Sonrisa
//
//  Hosts a tab's Chromium content view inside SwiftUI.
//

import SwiftUI

/// Wraps the `NSView` created by a `CEFBrowserController` so it can appear in a
/// SwiftUI hierarchy. Each tab owns one controller, so the hosted view is
/// stable for the lifetime of the tab.
struct BrowserView: NSViewRepresentable {
    let controller: CEFBrowserController

    func makeNSView(context: Context) -> NSView {
        controller.containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The Chromium child view resizes itself via autoresizing masks.
    }
}

/// Hosts every tab's Chromium view at once; switching tabs just flips
/// `isHidden` on the subviews. Attaching/detaching an NSView (what a
/// per-tab representable does) forces CEF to reattach and repaint, which
/// makes tab switches visibly lag — hidden-view flips are instant.
struct BrowserStackView: NSViewRepresentable {
    let tabs: [Tab]
    let activeID: Tab.ID?
    /// This tab's view lives elsewhere right now (DevTools split); leave it.
    let excludedID: Tab.ID?

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.autoresizesSubviews = true
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        let wanted = tabs.filter { $0.id != excludedID }
        let wantedViews = Set(wanted.map(\.controller.containerView))
        // Views of closed (or excluded) tabs leave the hierarchy.
        for sub in host.subviews where !wantedViews.contains(sub) {
            sub.removeFromSuperview()
        }
        for tab in wanted {
            let view = tab.controller.containerView
            if view.superview !== host {
                view.frame = host.bounds
                view.autoresizingMask = [.width, .height]
                host.addSubview(view)
            }
            view.isHidden = tab.id != activeID
        }
    }
}
