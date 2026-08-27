//
//  DownloadsStore.swift
//  Sonrisa
//
//  Session-scoped list of downloads across all windows. Files land in
//  ~/Downloads; this store only tracks progress for the UI.
//

import AppKit
import Observation

@MainActor
@Observable
final class DownloadsStore {
    static let shared = DownloadsStore()

    struct Download: Identifiable {
        let id: UInt32
        var path: String
        var received: Int64
        var total: Int64
        var isComplete: Bool
        var isCanceled: Bool

        var filename: String { (path as NSString).lastPathComponent }
        /// 0...1, or nil when the server didn't send a length.
        var progress: Double? {
            total > 0 ? Double(received) / Double(total) : nil
        }

        var subtitle: String {
            if isCanceled { return "Canceled" }
            let totalText = total > 0
                ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : nil
            if isComplete {
                return totalText
                    ?? ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            }
            let receivedText = ByteCountFormatter.string(fromByteCount: received,
                                                         countStyle: .file)
            return totalText.map { "\(receivedText) of \($0)" } ?? receivedText
        }
    }

    private(set) var downloads: [Download] = []

    /// Downloads started since the popover was last open — drives the badge
    /// count on the toolbar button.
    private(set) var unseenCount = 0

    /// True while anything is still transferring — drives the button badge.
    var hasActive: Bool {
        downloads.contains { !$0.isComplete && !$0.isCanceled }
    }

    /// Combined 0...1 across active downloads with a known size, or nil when
    /// nothing active reports one — drives the toolbar progress ring.
    var activeProgress: Double? {
        let sized = downloads.filter { !$0.isComplete && !$0.isCanceled && $0.total > 0 }
        guard !sized.isEmpty else { return nil }
        let received = sized.reduce(Int64(0)) { $0 + $1.received }
        let total = sized.reduce(Int64(0)) { $0 + $1.total }
        return Double(received) / Double(total)
    }

    private init() {}

    func update(id: UInt32, path: String, received: Int64, total: Int64,
                complete: Bool, canceled: Bool) {
        // The first update can arrive with an empty path (before the target
        // file is decided) — skip those, they'd render as a nameless row.
        guard !path.isEmpty else { return }
        let entry = Download(id: id, path: path, received: received,
                             total: total, isComplete: complete, isCanceled: canceled)
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index] = entry
        } else {
            downloads.insert(entry, at: 0)
            unseenCount += 1
        }
    }

    /// The popover was opened — clear the badge.
    func markSeen() {
        unseenCount = 0
    }

    func revealInFinder(_ download: Download) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: download.path)])
    }

    /// Extensions that can execute code — confirm before opening.
    private static let dangerousExtensions: Set<String> = [
        "app", "pkg", "dmg", "sh", "command", "scpt", "jar", "terminal",
    ]

    func open(_ download: Download) {
        let url = URL(fileURLWithPath: download.path)
        guard Self.dangerousExtensions.contains(url.pathExtension.lowercased()),
              let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open “\(download.filename)”?"
        alert.informativeText =
            "This file type can run software on your Mac. Only open it if you trust where it came from."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Removes finished/canceled rows; in-flight ones stay.
    func clearFinished() {
        downloads.removeAll { $0.isComplete || $0.isCanceled }
    }
}
