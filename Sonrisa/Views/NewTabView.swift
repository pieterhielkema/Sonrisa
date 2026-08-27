//
//  NewTabView.swift
//  Sonrisa
//
//  Start page shown in fresh empty tabs: an embedded address bar (the page
//  IS the address bar on a new tab) above a read-only grid of the user's
//  favorites and most-visited sites. Editing (rename, remove, reorder) stays
//  in the favorites bar.
//

import SwiftUI

struct NewTabView: View {
    let favorites: [Favorite]
    /// Most-visited sites from history; empty in incognito.
    var topSites: [HistorySuggestion] = []
    /// Bumped counter (⌘L / active-tab click); refocuses the embedded field.
    var focusRequest = 0
    /// History suggestions for the embedded field.
    var suggest: (String) -> [HistorySuggestion] = { _ in [] }
    let open: (String) -> Void

    @State private var openFolderID: UUID?
    @State private var addressText = ""
    @State private var suggestions: [HistorySuggestion] = []
    @State private var selectedIndex: Int?
    @FocusState private var addressFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 8)]

    /// First name of the macOS user account, for the greeting.
    private var firstName: String? {
        let first = NSFullUserName().split(separator: " ").first.map(String.init)
        return (first?.isEmpty == false) ? first : nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let firstName {
                    Text("Hi \(firstName)")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 48)
                        .padding(.bottom, 20)
                }
                addressCard
                    .padding(.top, firstName == nil ? 64 : 0)
                    .padding(.bottom, 40)
                gridsOrEmpty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(nsColor: .textBackgroundColor)
                .overlay((AppSettings.shared.chromeTint ?? .clear).opacity(0.05))
        )
        .onAppear { focusField() }
        .onChange(of: focusRequest) { _, _ in focusField() }
        .onChange(of: addressText) { _, text in
            selectedIndex = nil
            suggestions = text.isEmpty ? [] : suggest(text)
        }
    }

    // MARK: Embedded address bar

    /// Focus the field and keep asserting briefly: the fresh tab's CEF
    /// browser view attaches asynchronously and steals first responder right
    /// after the initial focus lands, so one set is not enough. Stops as
    /// soon as a field editor (NSTextView) holds focus.
    private func focusField(retries: Int = 8) {
        addressFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard retries > 0 else { return }
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
                focusField(retries: retries - 1)
                return
            }
            if window.firstResponder is NSTextView { return }
            // Stolen back — drop and retake so SwiftUI re-applies focus.
            addressFocused = false
            DispatchQueue.main.async { focusField(retries: retries - 1) }
        }
    }

    private var addressCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search or enter website", text: $addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($addressFocused)
                    .onSubmit {
                        if let index = selectedIndex,
                           suggestions.indices.contains(index) {
                            open(suggestions[index].url)
                        } else if !addressText.isEmpty {
                            open(addressText)
                        }
                    }
                    .onKeyPress(.downArrow) { moveSelection(by: 1) }
                    .onKeyPress(.upArrow) { moveSelection(by: -1) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            if !suggestions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, s in
                        suggestionRow(s, isSelected: index == selectedIndex)
                    }
                }
                .padding(6)
            }
        }
        .frame(maxWidth: 600)
        // Solid, not material — matches the spotlight overlay card.
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .padding(.horizontal, 24)
    }

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let count = suggestions.count
        let current = selectedIndex ?? (delta > 0 ? -1 : count)
        selectedIndex = (current + delta + count) % count
        return .handled
    }

    private func suggestionRow(_ suggestion: HistorySuggestion, isSelected: Bool) -> some View {
        Button {
            open(suggestion.url)
        } label: {
            HStack(spacing: 8) {
                FaviconView(host: suggestion.host)
                Text(suggestion.title.isEmpty ? suggestion.url : suggestion.title)
                    .lineLimit(1)
                Text(suggestion.url)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var gridsOrEmpty: some View {
            if favorites.isEmpty && topSites.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    if !favorites.isEmpty {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(favorites) { favorite in
                                if favorite.isFolder {
                                    folderTile(favorite)
                                } else {
                                    linkTile(favorite)
                                }
                            }
                        }
                    }
                    if !topSites.isEmpty {
                        HStack {
                            Text("Frequently Visited")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, favorites.isEmpty ? 0 : 24)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(topSites) { site in
                                Button {
                                    open(site.url)
                                } label: {
                                    tileLabel(title: site.host ?? site.title) {
                                        FaviconView(host: site.host, size: 32)
                                    }
                                }
                                .buttonStyle(NewTabTileStyle())
                                .help(site.url)
                            }
                        }
                    }
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 24)
            }
    }

    private func linkTile(_ favorite: Favorite) -> some View {
        Button {
            open(favorite.url)
        } label: {
            tileLabel(title: favorite.title) {
                FaviconView(host: favorite.host, size: 32)
            }
        }
        .buttonStyle(NewTabTileStyle())
        .help(favorite.url)
    }

    private func folderTile(_ folder: Favorite) -> some View {
        Button {
            openFolderID = folder.id
        } label: {
            tileLabel(title: folder.title) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(AppSettings.shared.detailTint?.opacity(0.8)
                                     ?? Color(nsColor: .secondaryLabelColor))
                    .frame(width: 32, height: 32)
            }
        }
        .buttonStyle(NewTabTileStyle())
        .popover(isPresented: Binding(
            get: { openFolderID == folder.id },
            set: { if !$0 { openFolderID = nil } }
        )) {
            folderContents(folder)
        }
    }

    private func folderContents(_ folder: Favorite) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(folder.children.filter { !$0.isFolder }) { child in
                Button {
                    openFolderID = nil
                    open(child.url)
                } label: {
                    HStack(spacing: 8) {
                        FaviconView(host: child.host)
                        Text(child.title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(minWidth: 180, maxWidth: 280)
    }

    private func tileLabel(title: String, @ViewBuilder icon: () -> some View) -> some View {
        VStack(spacing: 8) {
            icon()
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "star")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No favorites yet")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 120)
    }
}

/// Subtle hover highlight for start-page tiles.
private struct NewTabTileStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12)
                          : hovering ? Color.primary.opacity(0.06)
                          : Color.clear)
            )
            .onHover { hovering = $0 }
    }
}
