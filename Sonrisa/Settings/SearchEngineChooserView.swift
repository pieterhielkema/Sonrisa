//
//  SearchEngineChooserView.swift
//  Sonrisa
//
//  One-time chooser shown on first launch: which search engine to use.
//

import SwiftUI

struct SearchEngineChooserView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var selection: SearchEngine = .duckduckgo
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("Choose Your Search Engine")
                .font(.title2.bold())
            Text("Used when you type a search in the address bar.\nYou can change this anytime in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 4) {
                ForEach(SearchEngine.allCases) { engine in
                    engineRow(engine)
                }
            }
            .padding(.vertical, 4)

            Button("Continue") {
                settings.searchEngine = selection
                settings.hasChosenSearchEngine = true
                onDone()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 400)
        .onAppear { selection = settings.searchEngine }
    }

    private func engineRow(_ engine: SearchEngine) -> some View {
        Button {
            selection = engine
        } label: {
            HStack(spacing: 10) {
                FaviconView(host: URL(string: engine.homepage)?.host(), size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.displayName)
                        .font(.body.weight(.medium))
                    Text(engine.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selection == engine ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection == engine ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection == engine ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SearchEngineChooserView {}
}
