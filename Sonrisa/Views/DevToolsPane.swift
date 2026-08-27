//
//  DevToolsPane.swift
//  Sonrisa
//
//  Hosts Chromium DevTools docked inside the browser window. Chrome-style CEF
//  CHECK-crashes when ShowDevTools is given a SetAsChild window, so docking
//  works differently: the pane embeds a regular CEF browser that loads the
//  DevTools web frontend served by the remote-debugging server (:9222),
//  pointed at this tab's CDP target. Full DevTools, no native ShowDevTools.
//

import SwiftUI

struct DevToolsPane: NSViewRepresentable {
    let tab: Tab

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.autoresizesSubviews = true
        DispatchQueue.main.async {
            attach(to: host)
        }
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func attach(to host: NSView) {
        if let existing = tab.devToolsController {
            embed(existing.containerView, in: host)
            return
        }
        let tab = self.tab
        tab.controller.fetchDevToolsTargetID { targetID in
            MainActor.assumeIsolated {
                guard let targetID, tab.devToolsController == nil else { return }
                let url = "http://127.0.0.1:9222/devtools/inspector.html"
                    + "?ws=127.0.0.1:9222/devtools/page/\(targetID)"
                // Incognito context: the frontend needs no persistence, and
                // its storage shouldn't mingle with regular browsing data.
                let devtools = CEFBrowserController(url: url, incognito: true)
                // Remote-mode DevTools default to screencasting the page into
                // the pane — the page shows twice. Disable on first load; the
                // setting persists in the (shared, in-memory) incognito
                // context, so the reload happens at most once per app run.
                devtools.onLoadingStateChanged = { [weak devtools] loading, _, _ in
                    guard !loading, let devtools else { return }
                    devtools.evaluate(viaDevToolsProtocol: """
                        if (localStorage.getItem('screencastEnabled') !== 'false') {
                            localStorage.setItem('screencastEnabled', 'false');
                            location.reload();
                        }
                        """)
                }
                tab.devToolsController = devtools
                embed(devtools.containerView, in: host)
            }
        }
    }

    private func embed(_ view: NSView, in host: NSView) {
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
    }
}
