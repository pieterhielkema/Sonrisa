//
//  Favorite.swift
//  Sonrisa
//
//  A saved favorite plus the store that persists the favorites bar. A favorite
//  is either a link or a folder that holds nested favorites.
//

import Foundation
import Observation

struct Favorite: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var url: String = ""
    /// When false the favorite renders as an icon only (no text).
    var showsTitle: Bool = true
    /// A folder groups `children`; its `url` is unused.
    var isFolder: Bool = false
    var children: [Favorite] = []

    var host: String? { URL(string: url)?.host() }

    init(id: UUID = UUID(), title: String, url: String = "",
         showsTitle: Bool = true, isFolder: Bool = false, children: [Favorite] = []) {
        self.id = id
        self.title = title
        self.url = url
        self.showsTitle = showsTitle
        self.isFolder = isFolder
        self.children = children
    }

    // Decode defensively so favorites saved before folders existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        showsTitle = try c.decodeIfPresent(Bool.self, forKey: .showsTitle) ?? true
        isFolder = try c.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
        children = try c.decodeIfPresent([Favorite].self, forKey: .children) ?? []
    }
}

@MainActor
@Observable
final class FavoritesStore {
    private(set) var favorites: [Favorite] = []

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appending(path: "Sonrisa", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "favorites.json")
        load()
    }

    // MARK: Mutations

    func add(title: String, url: String) {
        // Avoid obvious duplicates by URL.
        guard !contains(url: url) else { return }
        favorites.append(Favorite(title: title.isEmpty ? (URL(string: url)?.host() ?? url) : title,
                                  url: url))
        save()
    }

    @discardableResult
    func addFolder(name: String) -> Favorite {
        let folder = Favorite(title: name.isEmpty ? "New Folder" : name, isFolder: true)
        favorites.append(folder)
        save()
        return folder
    }

    func remove(_ favorite: Favorite) {
        Self.remove(id: favorite.id, in: &favorites)
        save()
    }

    func rename(_ favorite: Favorite, to newTitle: String) {
        Self.mutate(id: favorite.id, in: &favorites) { $0.title = newTitle }
        save()
    }

    func toggleShowsTitle(_ favorite: Favorite) {
        Self.mutate(id: favorite.id, in: &favorites) { $0.showsTitle.toggle() }
        save()
    }

    /// Pull `id` out of any folder (or reorder it) so it sits at top level just
    /// before `targetID`. Appends to the end when `targetID` is nil/missing.
    func moveToTopLevel(_ id: UUID, before targetID: UUID?) {
        guard id != targetID,
              let item = Self.extract(id: id, in: &favorites) else { return }
        if let targetID, let to = favorites.firstIndex(where: { $0.id == targetID }) {
            favorites.insert(item, at: to)
        } else {
            favorites.append(item)
        }
        save()
    }

    /// Move `id` into `folderID`'s children. No-op when it would nest a folder
    /// inside itself or one of its descendants.
    func moveIntoFolder(_ id: UUID, folder folderID: UUID) {
        guard id != folderID else { return }
        if let dragged = Self.find(id: id, in: favorites), dragged.isFolder,
           Self.find(id: folderID, in: dragged.children) != nil { return }
        guard let item = Self.extract(id: id, in: &favorites) else { return }
        let landed = Self.mutate(id: folderID, in: &favorites) { $0.children.append(item) }
        if !landed { favorites.append(item) } // folder vanished — don't drop the item
        save()
    }

    /// Merge imported bookmarks onto the bar, skipping top-level links already present.
    func importFavorites(_ imported: [Favorite]) {
        var added = false
        for item in imported {
            if !item.isFolder, contains(url: item.url) { continue }
            favorites.append(item)
            added = true
        }
        if added { save() }
    }

    func contains(url: String) -> Bool {
        favorites.contains { $0.url == url }
    }

    // MARK: Recursive helpers

    @discardableResult
    private static func mutate(id: UUID, in list: inout [Favorite],
                               _ body: (inout Favorite) -> Void) -> Bool {
        for i in list.indices {
            if list[i].id == id { body(&list[i]); return true }
            if list[i].isFolder, mutate(id: id, in: &list[i].children, body) { return true }
        }
        return false
    }

    /// Remove and return the favorite with `id` from anywhere in the tree.
    private static func extract(id: UUID, in list: inout [Favorite]) -> Favorite? {
        if let idx = list.firstIndex(where: { $0.id == id }) {
            return list.remove(at: idx)
        }
        for i in list.indices where list[i].isFolder {
            if let item = extract(id: id, in: &list[i].children) { return item }
        }
        return nil
    }

    /// Find the favorite with `id` anywhere in the tree.
    private static func find(id: UUID, in list: [Favorite]) -> Favorite? {
        for f in list {
            if f.id == id { return f }
            if f.isFolder, let hit = find(id: id, in: f.children) { return hit }
        }
        return nil
    }

    private static func remove(id: UUID, in list: inout [Favorite]) {
        if let idx = list.firstIndex(where: { $0.id == id }) {
            list.remove(at: idx)
            return
        }
        for i in list.indices where list[i].isFolder {
            remove(id: id, in: &list[i].children)
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Favorite].self, from: data) else {
            return
        }
        favorites = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
