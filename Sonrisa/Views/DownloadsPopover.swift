//
//  DownloadsPopover.swift
//  Sonrisa
//
//  Content of the toolbar downloads popover: one row per download with the
//  file's real Finder icon, progress/size subtitle, double-click to open and
//  a folder button to reveal in Finder.
//

import SwiftUI
import AppKit

struct DownloadsPopoverView: View {
    let store: DownloadsStore
    @Binding var isPresented: Bool

    private var hasFinished: Bool {
        store.downloads.contains { $0.isComplete || $0.isCanceled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.headline)
                Spacer()
                if hasFinished {
                    Button("Clear") {
                        store.clearFinished()
                        if store.downloads.isEmpty { isPresented = false }
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.downloads) { download in
                        DownloadRow(download: download, store: store)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 340)
        .onDisappear { store.markSeen() }
    }
}

private struct DownloadRow: View {
    let download: DownloadsStore.Download
    let store: DownloadsStore

    @State private var hovering = false
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon ?? NSWorkspace.shared.icon(forFile: download.path))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(download.isCanceled ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(download.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(download.isCanceled ? .secondary : .primary)
                if !download.isComplete && !download.isCanceled,
                   let progress = download.progress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                }
                Text(download.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !download.isCanceled {
                Button {
                    store.revealInFinder(download)
                } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0.35)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            if download.isComplete { store.open(download) }
        }
        .help(download.isComplete ? "Double-click to open" : "")
        // Refresh once the file finishes — the icon can change when the full
        // file (and its extension handler) is in place.
        .task(id: download.isComplete) {
            icon = NSWorkspace.shared.icon(forFile: download.path)
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
