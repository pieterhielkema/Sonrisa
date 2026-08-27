//
//  FaviconCache.swift
//  Sonrisa
//
//  Caches favicons on disk and in memory, keyed by host. Icons are downloaded
//  through the page's own network context (see CEFBrowserController) or fetched
//  directly from the site itself — never a third-party favicon service — so
//  browsing stays private. Disk entries expire after a day.
//

import AppKit

@MainActor
@Observable
final class FaviconCache {
    static let shared = FaviconCache()

    /// Disk entries older than this are refetched on next request.
    private static let maxAge: TimeInterval = 24 * 60 * 60

    /// Bumped whenever a new icon is stored, so SwiftUI views observing the
    /// cache refresh even though images are keyed by host.
    private(set) var generation: Int = 0

    private var memory: [String: NSImage] = [:]
    private let directory: URL

    /// Hosts with a fetch currently in flight, and hosts attempted this
    /// session (successful or not) — prevents refetch storms and re-hitting
    /// hosts that have no icon.
    private var inFlight: Set<String> = []
    private var lastAttempt: [String: Date] = [:]

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        directory = support.appending(path: "Sonrisa/Favicons", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    /// Bundled icons for well-known hosts (the search engines), so they have
    /// icons before the user ever visits them. Ships in the app — no network.
    private static let bundledIcons: [String: String] = Dictionary(
        uniqueKeysWithValues: SearchEngine.allCases.compactMap { engine in
            URL(string: engine.homepage)?.host().map { ($0, "engine-\(engine.rawValue)") }
        }
    )

    /// Returns a cached icon for `host`, loading from disk on first access and
    /// falling back to an icon bundled with the app for well-known hosts.
    func image(for host: String?) -> NSImage? {
        guard let host, !host.isEmpty else { return nil }
        if let cached = memory[host] { return cached }
        if let image = NSImage(contentsOf: fileURL(for: host)) {
            memory[host] = image
            return image
        }
        if let assetName = Self.bundledIcons[host] ?? Self.bundledIcons["www.\(host)"],
           let image = NSImage(named: assetName) {
            memory[host] = image
            return image
        }
        return nil
    }

    /// Fetches an icon for `host` directly from the site if the cached copy is
    /// missing or older than a day. Safe to call freely (e.g. from every
    /// favicon view); attempts are deduplicated and throttled to one per host
    /// per day, so hosts without any icon aren't hammered.
    func ensureFresh(_ host: String?) {
        guard let host, !host.isEmpty else { return }
        if inFlight.contains(host) { return }
        if let attempted = lastAttempt[host],
           Date().timeIntervalSince(attempted) < Self.maxAge { return }
        if isFreshOnDisk(host) { return }

        inFlight.insert(host)
        lastAttempt[host] = Date()
        Task {
            let png = await FaviconFetcher.fetch(host: host)
            inFlight.remove(host)
            if let png {
                store(png: png, for: host)
            }
        }
    }

    /// Stores a freshly downloaded PNG for `host`.
    func store(png: Data, for host: String) {
        guard !host.isEmpty, let image = NSImage(data: png) else { return }
        memory[host] = image
        try? png.write(to: fileURL(for: host), options: .atomic)
        lastAttempt[host] = Date()
        generation &+= 1
    }

    /// Wipes every cached icon (memory + disk). Bundled icons come back on
    /// next lookup.
    func removeAll() {
        memory.removeAll()
        lastAttempt.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        generation &+= 1
    }

    private func isFreshOnDisk(_ host: String) -> Bool {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: fileURL(for: host).path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < Self.maxAge
    }

    private func fileURL(for host: String) -> URL {
        let safe = host.replacingOccurrences(of: "/", with: "_")
        return directory.appending(path: "\(safe).png")
    }
}

/// Fetches a site's icon straight from the site (first-party only): the
/// well-known /favicon.ico, then icons declared in the page's HTML head, then
/// /apple-touch-icon.png. Returns PNG data, or nil if the site has no usable
/// icon.
enum FaviconFetcher {
    static func fetch(host: String) async -> Data? {
        guard let base = URL(string: "https://\(host)") else { return nil }

        var candidates: [URL] = [base.appending(path: "favicon.ico")]
        candidates.append(contentsOf: await htmlDeclaredIcons(at: base))
        candidates.append(base.appending(path: "apple-touch-icon.png"))

        for url in candidates {
            if let png = await downloadIcon(url) { return png }
        }
        return nil
    }

    /// Icon URLs declared via <link rel="icon"...> / apple-touch-icon in the
    /// homepage's HTML. SVGs are skipped (NSImage can't rasterize them).
    private static func htmlDeclaredIcons(at base: URL) async -> [URL] {
        guard let (data, response) = try? await session.data(from: base),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data.prefix(128 * 1024), encoding: .utf8)
                  ?? String(data: data.prefix(128 * 1024), encoding: .isoLatin1)
        else { return [] }

        let pattern = #"<link\b[^>]*\brel\s*=\s*["']?([^"'>]*icon[^"'>]*)["']?[^>]*>"#
        guard let linkRegex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive])
        else { return [] }
        let hrefRegex = try? NSRegularExpression(pattern: #"\bhref\s*=\s*["']?([^"'\s>]+)"#,
                                                 options: [.caseInsensitive])

        var icons: [URL] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in linkRegex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let tagNSRange = NSRange(tag.startIndex..., in: tag)
            guard let href = hrefRegex?.firstMatch(in: tag, range: tagNSRange),
                  let hrefRange = Range(href.range(at: 1), in: tag),
                  let url = URL(string: String(tag[hrefRange]), relativeTo: base)?.absoluteURL
            else { continue }
            if url.pathExtension.lowercased() == "svg" { continue }
            if url.scheme == "https" || url.scheme == "http" || url.scheme == "data" {
                icons.append(url)
            }
        }
        return icons
    }

    /// Downloads and decodes one candidate, re-encoding to PNG. Returns nil
    /// for 404s, HTML error pages, and anything NSImage can't decode.
    private static func downloadIcon(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return nil }
        guard data.count > 0, data.count < 2 * 1024 * 1024,
              let image = NSImage(data: data), image.size.width > 0,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = ["Accept": "*/*"]
        return URLSession(configuration: config)
    }()
}
