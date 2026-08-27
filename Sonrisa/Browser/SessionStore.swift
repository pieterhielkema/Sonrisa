//
//  SessionStore.swift
//  Sonrisa
//
//  Persists each regular window's open-tab URLs so a fresh launch can restore
//  the last session. Windows claim slots in creation order; incognito windows
//  never touch this.
//

import Foundation

/// One window's tabs: pinned tabs come back pinned.
struct WindowSession: Codable {
    var pinned: [String] = []
    /// Ungrouped (Default-group) tab URLs.
    var urls: [String] = []
    /// Optional so files from before tab groups still decode.
    var groups: [SavedTabGroup]? = nil
}

struct SavedTabGroup: Codable {
    var name: String
    var urls: [String]
    /// Optional so files written by earlier builds still decode.
    var pinned: Bool? = nil
}

@MainActor
final class SessionStore {
    static let shared = SessionStore()

    /// Snapshot from the previous session, read once at launch.
    private let restored: [WindowSession]
    /// What this session's windows currently have open, keyed by slot.
    private var live: [Int: WindowSession] = [:]
    private var nextSlot = 0

    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appending(path: "Sonrisa", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "session.json")
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode([WindowSession].self, from: data) {
                restored = decoded
            } else if let legacy = try? JSONDecoder().decode([[String]].self, from: data) {
                // Pre-pinned-tabs format: plain URL lists.
                restored = legacy.map { WindowSession(pinned: [], urls: $0) }
            } else {
                restored = []
            }
        } else {
            restored = []
        }
    }

    /// Claims the next window slot and returns the tabs it had last session.
    func claim() -> (slot: Int, session: WindowSession) {
        let slot = nextSlot
        nextSlot += 1
        let session = slot < restored.count ? restored[slot] : WindowSession()
        live[slot] = session
        return (slot, session)
    }

    func update(slot: Int, session: WindowSession) {
        live[slot] = session
        save()
    }

    private func save() {
        let slots = live.keys.sorted().map { live[$0] ?? WindowSession() }
        guard let data = try? JSONEncoder().encode(slots) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
