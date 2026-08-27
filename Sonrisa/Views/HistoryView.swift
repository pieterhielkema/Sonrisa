//
//  HistoryView.swift
//  Sonrisa
//
//  Browsable history sheet: search, time-period and site filters, entries
//  grouped by day, per-entry deletion, and Clear History.
//

import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by the History menu to open the history sheet.
    static let sonrisaShowHistory = Notification.Name("SonrisaShowHistoryNotification")
}

/// Time-period filter for the history list.
enum HistoryPeriod: String, CaseIterable, Identifiable {
    case all, today, yesterday, lastWeek, lastMonth

    var id: Self { self }

    var displayName: String {
        switch self {
        case .all: "All Time"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastWeek: "Last 7 Days"
        case .lastMonth: "Last 30 Days"
        }
    }

    func contains(_ date: Date) -> Bool {
        let calendar = Calendar.current
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDateInToday(date)
        case .yesterday:
            return calendar.isDateInYesterday(date)
        case .lastWeek:
            return date > calendar.date(byAdding: .day, value: -7, to: Date())!
        case .lastMonth:
            return date > calendar.date(byAdding: .day, value: -30, to: Date())!
        }
    }
}

struct HistoryView: View {
    /// Called when the user opens an entry; `inNewTab` distinguishes the two open actions.
    var onOpen: (_ url: String, _ inNewTab: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var period: HistoryPeriod = .all
    @State private var siteFilter: String?
    @State private var showsClearConfirmation = false

    private var history = HistoryStore.shared

    init(onOpen: @escaping (_ url: String, _ inNewTab: Bool) -> Void) {
        self.onOpen = onOpen
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            Divider()
            entryList
            Divider()
            footer
        }
        .frame(width: 680, height: 480)
        .confirmationDialog("Clear browsing history?",
                            isPresented: $showsClearConfirmation) {
            Button("Clear History", role: .destructive) {
                history.clear()
            }
        } message: {
            Text("This removes all remembered pages and address bar suggestions.")
        }
    }

    // MARK: Filtering

    /// Hosts present in history (www-stripped), for the site filter menu.
    private var availableSites: [String] {
        Set(history.entries.compactMap { $0.host.map(Self.strippedHost) })
            .sorted()
    }

    private var filteredEntries: [HistoryEntry] {
        history.entries.filter { entry in
            guard period.contains(entry.lastVisited) else { return false }
            if let siteFilter,
               entry.host.map(Self.strippedHost) != siteFilter { return false }
            let query = searchText.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return true }
            return entry.title.localizedCaseInsensitiveContains(query)
                || entry.url.localizedCaseInsensitiveContains(query)
        }
        .sorted { $0.lastVisited > $1.lastVisited }
    }

    /// The filtered entries grouped by calendar day, newest day first.
    private var dayGroups: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredEntries) {
            calendar.startOfDay(for: $0.lastVisited)
        }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!) }
    }

    private static func strippedHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: Subviews

    private var header: some View {
        HStack {
            Text("History")
                .font(.title3.bold())
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search history", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary.opacity(0.5)))

            Picker("Period", selection: $period) {
                ForEach(HistoryPeriod.allCases) { period in
                    Text(period.displayName).tag(period)
                }
            }
            .labelsHidden()
            .fixedSize()

            Picker("Site", selection: $siteFilter) {
                Text("All Sites").tag(String?.none)
                Divider()
                ForEach(availableSites, id: \.self) { site in
                    Text(site).tag(String?.some(site))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var entryList: some View {
        if dayGroups.isEmpty {
            ContentUnavailableView(
                history.entries.isEmpty ? "No History" : "No Results",
                systemImage: "clock",
                description: Text(history.entries.isEmpty
                                  ? "Pages you visit will appear here."
                                  : "No history matches the current search and filters."))
                .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(dayGroups, id: \.day) { group in
                    Section(dayTitle(for: group.day)) {
                        ForEach(group.entries) { entry in
                            HistoryRowView(entry: entry) { inNewTab in
                                onOpen(entry.url, inNewTab)
                            } onDelete: {
                                history.remove(entry)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            Text(footerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear History…") {
                showsClearConfirmation = true
            }
            .disabled(history.entries.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footerSummary: String {
        let total = history.entries.count
        let shown = filteredEntries.count
        return shown == total ? "\(total) pages" : "\(shown) of \(total) pages"
    }

    private func dayTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }
}

/// A single history entry: favicon, title, URL, visit info, and a hover delete button.
private struct HistoryRowView: View {
    let entry: HistoryEntry
    var onOpen: (_ inNewTab: Bool) -> Void
    var onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onOpen(false)
        } label: {
            HStack(spacing: 8) {
                FaviconView(host: entry.host, fallbackSymbol: "clock", size: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title.isEmpty ? entry.url : entry.title)
                        .lineLimit(1)
                    Text(displayURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if entry.visitCount > 1 {
                    Text("\(entry.visitCount) visits")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(entry.lastVisited.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .help("Remove from History")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open") { onOpen(false) }
            Button("Open in New Tab") { onOpen(true) }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url, forType: .string)
            }
            Divider()
            Button("Remove from History", role: .destructive, action: onDelete)
        }
    }

    private var displayURL: String {
        var text = entry.url
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

#Preview {
    HistoryView { _, _ in }
}
