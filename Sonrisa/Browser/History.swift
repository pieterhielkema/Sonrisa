//
//  History.swift
//  Sonrisa
//
//  Browsing history: persisted visit records plus address-bar suggestions.
//

import Foundation
import Observation

struct HistoryEntry: Codable, Equatable, Identifiable {
    var url: String
    var title: String
    var visitCount: Int
    var lastVisited: Date

    // URLs are unique within the store.
    var id: String { url }
    var host: String? { URL(string: url)?.host() }
}

/// One row in the address bar's suggestion list.
struct HistorySuggestion: Identifiable, Equatable {
    var title: String
    var url: String
    /// Root-domain suggestions represent the site as a whole and sort first.
    var isRootDomain: Bool

    var id: String { url }
    var host: String? { URL(string: url)?.host() }
}

@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL
    private static let maxEntries = 2000

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appending(path: "Sonrisa", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "history.json")
        load()
    }

    // MARK: Recording

    func record(url: String, title: String) {
        // Only real web pages belong in history (not about:blank etc.).
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return }

        if let index = entries.firstIndex(where: { $0.url == url }) {
            entries[index].visitCount += 1
            entries[index].lastVisited = Date()
            if !title.isEmpty, title != "Untitled" {
                entries[index].title = title
            }
        } else {
            entries.append(HistoryEntry(url: url, title: title, visitCount: 1, lastVisited: Date()))
            if entries.count > Self.maxEntries {
                // Evict the least recently visited entries.
                entries.sort { $0.lastVisited > $1.lastVisited }
                entries.removeLast(entries.count - Self.maxEntries)
            }
        }
        save()
    }

    /// Page titles often arrive after the visit is recorded; refresh them in place.
    func updateTitle(for url: String, title: String) {
        guard !title.isEmpty, title != "Untitled",
              let index = entries.firstIndex(where: { $0.url == url }),
              entries[index].title != title else { return }
        entries[index].title = title
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.url == entry.url }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    // MARK: Suggestions

    /// Suggests sites from history for address-bar input. For every matching
    /// site the root domain comes first, followed by that site's most visited
    /// pages. Sites the user visits more often rank higher.
    /// Most-visited sites (aggregated per host) for the start page.
    func topSites(limit: Int = 8) -> [HistorySuggestion] {
        var byHost: [String: (visits: Int, best: HistoryEntry)] = [:]
        for entry in entries {
            guard let host = entry.host else { continue }
            if var existing = byHost[host] {
                existing.visits += entry.visitCount
                if entry.visitCount > existing.best.visitCount { existing.best = entry }
                byHost[host] = existing
            } else {
                byHost[host] = (entry.visitCount, entry)
            }
        }
        return byHost
            .sorted { $0.value.visits > $1.value.visits }
            .prefix(limit)
            .map { host, value in
                HistorySuggestion(title: value.best.title.isEmpty ? host : value.best.title,
                                  url: "https://\(host)",
                                  isRootDomain: true)
            }
    }

    func suggestions(for input: String, limit: Int = 6) -> [HistorySuggestion] {
        let query = Self.searchKey(from: input)
        guard !query.isEmpty else { return [] }

        var byHost: [String: [HistoryEntry]] = [:]
        for entry in entries {
            guard let host = URL(string: entry.url)?.host() else { continue }
            byHost[host, default: []].append(entry)
        }

        let matchingHosts = byHost
            .filter { Self.host($0.key, matches: query) }
            .sorted { totalVisits($0.value) > totalVisits($1.value) }

        var result: [HistorySuggestion] = []
        for (host, hostEntries) in matchingHosts {
            if result.count >= limit { break }
            let root = rootSuggestion(host: host, entries: hostEntries)
            result.append(root)

            for entry in hostEntries.sorted(by: { $0.visitCount > $1.visitCount })
            where entry.url != root.url {
                if result.count >= limit { break }
                result.append(HistorySuggestion(title: entry.title, url: entry.url,
                                                isRootDomain: false))
            }
        }

        // No matching site: fall back to title/URL substring matches.
        if result.isEmpty {
            for entry in entries.sorted(by: { $0.visitCount > $1.visitCount })
            where entry.url.localizedCaseInsensitiveContains(query)
                || entry.title.localizedCaseInsensitiveContains(query) {
                if result.count >= limit { break }
                result.append(HistorySuggestion(title: entry.title, url: entry.url,
                                                isRootDomain: false))
            }
        }
        return result
    }

    private func totalVisits(_ entries: [HistoryEntry]) -> Int {
        entries.reduce(0) { $0 + $1.visitCount }
    }

    /// The site-level suggestion: a previously visited root page if there is
    /// one (keeping its real scheme and title), otherwise a constructed one.
    private func rootSuggestion(host: String, entries: [HistoryEntry]) -> HistorySuggestion {
        let rootURLs = ["https://\(host)/", "https://\(host)",
                        "http://\(host)/", "http://\(host)"]
        if let entry = entries.first(where: { rootURLs.contains($0.url) }) {
            return HistorySuggestion(title: entry.title.isEmpty ? host : entry.title,
                                     url: entry.url, isRootDomain: true)
        }
        return HistorySuggestion(title: host, url: "https://\(host)/", isRootDomain: true)
    }

    /// Normalizes typed input for matching: lowercased, scheme and "www." stripped.
    private static func searchKey(from input: String) -> String {
        var query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where query.hasPrefix(prefix) {
            query.removeFirst(prefix.count)
        }
        if query.hasPrefix("www.") { query.removeFirst(4) }
        return query
    }

    /// Matches at label boundaries, so "gith" matches both "github.com" and
    /// "gist.github.com" (via its "github.com" suffix) but not "somegithub.com".
    private static func host(_ host: String, matches query: String) -> Bool {
        guard !query.contains("/"), !query.contains(" ") else { return false }
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        for start in labels.indices
        where labels[start...].joined(separator: ".").hasPrefix(query) {
            return true
        }
        return false
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
