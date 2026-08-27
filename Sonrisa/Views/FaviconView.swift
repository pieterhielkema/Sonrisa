//
//  FaviconView.swift
//  Sonrisa
//
//  Shows a cached favicon for a host, falling back to a symbol.
//

import SwiftUI

struct FaviconView: View {
    let host: String?
    var fallbackSymbol: String = "globe"
    var size: CGFloat = 16
    /// Off for incognito content so browsing never triggers a favicon fetch
    /// or disk write.
    var fetchOnMiss: Bool = true

    private var cache = FaviconCache.shared

    init(host: String?, fallbackSymbol: String = "globe", size: CGFloat = 16,
         fetchOnMiss: Bool = true) {
        self.host = host
        self.fallbackSymbol = fallbackSymbol
        self.size = size
        self.fetchOnMiss = fetchOnMiss
    }

    var body: some View {
        // Reading `generation` subscribes this view to cache updates.
        let _ = cache.generation
        Group {
            if let image = cache.image(for: host) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: host) {
            // Fetch (or refresh a >1-day-old copy of) the icon straight from
            // the site; deduped and throttled inside the cache.
            if fetchOnMiss { cache.ensureFresh(host) }
        }
    }
}
