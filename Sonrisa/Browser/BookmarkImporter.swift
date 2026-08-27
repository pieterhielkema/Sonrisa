//
//  BookmarkImporter.swift
//  Sonrisa
//
//  Reads bookmarks out of Safari and Chromium browsers and maps them onto our
//  Favorite tree (folders become folders, links become links).
//
//  Note: reading ~/Library/Safari/Bookmarks.plist requires Full Disk Access.
//  When access is denied the read simply yields an empty result.
//

import Foundation

enum BookmarkImporter {

    // MARK: Chrome / Chromium

    /// Bookmarks bar entries from the first Chromium profile we can read.
    static func chrome() -> [Favorite] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "Library/Application Support/Google/Chrome/Default/Bookmarks",
            "Library/Application Support/Google/Chrome/Profile 1/Bookmarks",
            "Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks",
            "Library/Application Support/Microsoft Edge/Default/Bookmarks",
        ]
        for rel in candidates {
            let url = home.appending(path: rel)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = json["roots"] as? [String: Any],
                  let bar = roots["bookmark_bar"] as? [String: Any] else { continue }
            let out = chromeChildren(bar["children"] as? [[String: Any]] ?? [])
            if !out.isEmpty { return out }
        }
        return []
    }

    private static func chromeChildren(_ items: [[String: Any]]) -> [Favorite] {
        items.compactMap { node in
            let name = node["name"] as? String ?? ""
            switch node["type"] as? String {
            case "url":
                guard let url = node["url"] as? String else { return nil }
                return Favorite(title: name.isEmpty ? url : name, url: url)
            case "folder":
                let kids = chromeChildren(node["children"] as? [[String: Any]] ?? [])
                return Favorite(title: name.isEmpty ? "Folder" : name,
                                isFolder: true, children: kids)
            default:
                return nil
            }
        }
    }

    // MARK: Safari

    /// Entries from the Safari bookmarks bar (falls back to the whole tree).
    static func safari() -> [Favorite] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appending(path: "Library/Safari/Bookmarks.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization
                  .propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return []
        }
        let children = plist["Children"] as? [[String: Any]] ?? []
        if let bar = children.first(where: { ($0["Title"] as? String) == "BookmarksBar" }) {
            return safariChildren(bar["Children"] as? [[String: Any]] ?? [])
        }
        return safariChildren(children)
    }

    private static func safariChildren(_ items: [[String: Any]]) -> [Favorite] {
        items.compactMap { node in
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = node["URLString"] as? String else { return nil }
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                return Favorite(title: title?.isEmpty == false ? title! : url, url: url)
            case "WebBookmarkTypeList":
                let title = node["Title"] as? String ?? "Folder"
                let kids = safariChildren(node["Children"] as? [[String: Any]] ?? [])
                return Favorite(title: title, isFolder: true, children: kids)
            default:
                return nil
            }
        }
    }
}
