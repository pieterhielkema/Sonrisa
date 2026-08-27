//
//  FavoritesBarView.swift
//  Sonrisa
//
//  A thin bar of favorites. Each favorite is easy to add, rename, delete, or
//  switch to an icon-only presentation via its context menu. Favorites can be
//  grouped into folders, dragged to reorder, and imported from other browsers.
//

import SwiftUI

struct FavoritesBarView: View {
    @Bindable var model: BrowserViewModel

    @State private var renameTarget: Favorite?
    @State private var renameText: String = ""
    @State private var importMessage: String?

    private var store: FavoritesStore { model.favorites }

    var body: some View {
        // The whole bar collapses when there are no favorites.
        if !store.favorites.isEmpty {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(store.favorites) { favorite in
                            node(favorite)
                                .draggable(favorite.id.uuidString)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let raw = items.first,
                                          let dragged = UUID(uuidString: raw) else { return false }
                                    if favorite.isFolder {
                                        store.moveIntoFolder(dragged, folder: favorite.id)
                                    } else {
                                        store.moveToTopLevel(dragged, before: favorite.id)
                                    }
                                    return true
                                }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            // Subtle wash of the user's accent color over the chrome (colorful
            // chrome setting; clear when the simple look is on). Incognito
            // windows get a darker wash instead.
            .background(model.isIncognito ? Color.black.opacity(0.2)
                        : (AppSettings.shared.chromeTint ?? .clear).opacity(0.05))
            .background(.bar)
            .contentShape(Rectangle())
            // Dropping anywhere on the bar that isn't a folder (gaps, the empty
            // right side) pulls the favorite out to the top level. Folder nodes'
            // own drop targets take priority, so drops on them still move-in.
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first,
                      let dragged = UUID(uuidString: raw) else { return false }
                store.moveToTopLevel(dragged, before: nil)
                return true
            }
            .contextMenu { barContextMenu }
            .popover(item: $renameTarget) { favorite in
                renamePopover(favorite)
            }
            .alert("Nothing Imported", isPresented: importAlertBinding) {
                Button("OK", role: .cancel) { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    // MARK: Nodes

    @ViewBuilder
    private func node(_ favorite: Favorite) -> some View {
        if favorite.isFolder {
            FolderButton(favorite: favorite, model: model, beginRename: beginRename)
        } else {
            favoriteButton(favorite)
        }
    }

    private func favoriteButton(_ favorite: Favorite) -> some View {
        Button {
            model.navigateActive(to: favorite.url)
        } label: {
            HStack(spacing: 5) {
                FaviconView(host: favorite.host)
                if favorite.showsTitle {
                    Text(favorite.title)
                        .lineLimit(1)
                        .font(.callout)
                }
            }
            .padding(.horizontal, favorite.showsTitle ? 10 : 6)
            .padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.hover)
        .help(favorite.title)
        .contextMenu { FavoriteContextMenu(favorite: favorite, model: model, beginRename: beginRename) }
    }

    private func beginRename(_ favorite: Favorite) {
        renameText = favorite.title
        renameTarget = favorite
    }

    // MARK: Bar actions

    @ViewBuilder
    private var barContextMenu: some View {
        Button("New Folder") { newFolder() }
        Divider()
        Section("Import") {
            Button("From Safari") { runImport(BookmarkImporter.safari(), source: "Safari") }
            Button("From Chrome") { runImport(BookmarkImporter.chrome(), source: "Chrome") }
        }
    }

    private func newFolder() {
        let folder = store.addFolder(name: "New Folder")
        renameText = folder.title
        renameTarget = folder
    }

    private func runImport(_ imported: [Favorite], source: String) {
        let before = store.favorites.count
        store.importFavorites(imported)
        if store.favorites.count == before {
            importMessage = imported.isEmpty
                ? "Couldn't read \(source) bookmarks. Grant Full Disk Access to Sonrisa in System Settings › Privacy & Security, then try again."
                : "All \(source) bookmarks are already on the bar."
        }
    }

    private var importAlertBinding: Binding<Bool> {
        Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })
    }

    // MARK: Rename

    private func renamePopover(_ favorite: Favorite) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(favorite.isFolder ? "Rename Folder" : "Rename Favorite")
                .font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { commitRename(favorite) }
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
                Button("Save") { commitRename(favorite) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func commitRename(_ favorite: Favorite) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.rename(favorite, to: trimmed)
        }
        renameTarget = nil
    }
}

/// A folder on the bar (or nested as a row): a tappable label that opens a
/// popover of its children. Children in the popover are real drag sources, so a
/// favorite can be dragged out onto the bar or into another folder.
private struct FolderButton: View {
    let favorite: Favorite
    let model: BrowserViewModel
    let beginRename: (Favorite) -> Void
    /// Bar folders render as a capsule; nested folders render as a full-width row.
    var isRow = false

    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: { label }
            .buttonStyle(.plain)
            .help(favorite.title)
            .contextMenu {
                FavoriteContextMenu(favorite: favorite, model: model,
                                    beginRename: beginRename)
            }
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                FolderPopover(folder: favorite, model: model,
                              beginRename: beginRename, dismiss: { isOpen = false })
            }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .foregroundStyle(AppSettings.shared.detailTint?.opacity(0.8)
                                 ?? Color(nsColor: .secondaryLabelColor))
            if isRow || favorite.showsTitle {
                Text(favorite.title)
                    .lineLimit(1)
                    .font(.callout)
            }
            if isRow {
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, isRow || favorite.showsTitle ? 10 : 6)
        .padding(.vertical, 4)
        .frame(maxWidth: isRow ? .infinity : nil, alignment: .leading)
        .contentShape(Rectangle())
        .capsuleHover()
    }
}

/// The scrollable list of a folder's children shown in its popover. Each child
/// is draggable; folder rows also accept drops (move a favorite into them).
private struct FolderPopover: View {
    let folder: Favorite
    let model: BrowserViewModel
    let beginRename: (Favorite) -> Void
    let dismiss: () -> Void

    private var store: FavoritesStore { model.favorites }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if folder.children.isEmpty {
                Text("Empty")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ForEach(folder.children) { child in
                    row(child)
                }
            }
        }
        .padding(6)
        .frame(minWidth: 200)
    }

    @ViewBuilder
    private func row(_ child: Favorite) -> some View {
        if child.isFolder {
            FolderButton(favorite: child, model: model,
                         beginRename: beginRename, isRow: true)
                .draggable(child.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first,
                          let dragged = UUID(uuidString: raw) else { return false }
                    store.moveIntoFolder(dragged, folder: child.id)
                    return true
                }
        } else {
            Button {
                model.navigateActive(to: child.url)
                dismiss()
            } label: {
                HStack(spacing: 5) {
                    FaviconView(host: child.host)
                    Text(child.title)
                        .lineLimit(1)
                        .font(.callout)
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .capsuleHover()
            }
            .buttonStyle(.plain)
            .help(child.title)
            .draggable(child.id.uuidString)
            .contextMenu {
                FavoriteContextMenu(favorite: child, model: model,
                                    beginRename: beginRename, dismiss: dismiss)
            }
        }
    }
}

/// Shared right-click menu for a favorite or folder, usable on the bar and
/// inside folder popovers.
private struct FavoriteContextMenu: View {
    let favorite: Favorite
    let model: BrowserViewModel
    let beginRename: (Favorite) -> Void
    var dismiss: (() -> Void)? = nil

    var body: some View {
        if !favorite.isFolder {
            Button("Open in New Tab") { model.openInNewTab(favorite.url) }
            Divider()
        }
        Button("Rename…") {
            dismiss?()
            beginRename(favorite)
        }
        Button(favorite.showsTitle ? "Show Icon Only" : "Show Title") {
            model.favorites.toggleShowsTitle(favorite)
        }
        Divider()
        Button("Remove", role: .destructive) { model.favorites.remove(favorite) }
    }
}
