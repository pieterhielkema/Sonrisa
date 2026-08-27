//
//  AdBlocker.swift
//  Sonrisa
//
//  Keeps the C++ host blocklist fed. The list (StevenBlack hosts, ads +
//  trackers) is cached in Application Support and refreshed weekly.
//

import Foundation

@MainActor
enum AdBlocker {
    private static let listURL = URL(
        string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")!
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        return support.appending(path: "Sonrisa/adblock-hosts.txt")
    }

    /// Applies the enabled setting and loads the cached list, downloading a
    /// fresh copy in the background when missing or older than a week.
    static func bootstrap() {
        SonrisaAdblockSetEnabled(AppSettings.shared.blockAds)

        let path = fileURL.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes?[.modificationDate] as? Date

        if FileManager.default.fileExists(atPath: path) {
            Task.detached(priority: .utility) {
                SonrisaAdblockLoadHostsFile(path)
                NSLog("[Sonrisa] adblock: %lu hosts loaded", SonrisaAdblockHostCount())
            }
        }
        if modified == nil || Date().timeIntervalSince(modified!) > maxAge {
            refresh()
        }
    }

    static func setEnabled(_ enabled: Bool) {
        SonrisaAdblockSetEnabled(enabled)
        if enabled, SonrisaAdblockHostCount() == 0 {
            bootstrap()
        }
    }

    private static func refresh() {
        let destination = fileURL
        Task.detached(priority: .utility) {
            guard let (data, response) = try? await URLSession.shared.data(from: listURL),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count > 100_000 else { return }
            try? data.write(to: destination, options: .atomic)
            SonrisaAdblockLoadHostsFile(destination.path)
            NSLog("[Sonrisa] adblock: refreshed, %lu hosts", SonrisaAdblockHostCount())
        }
    }
}
