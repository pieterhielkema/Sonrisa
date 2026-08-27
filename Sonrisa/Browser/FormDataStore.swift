//
//  FormDataStore.swift
//  Sonrisa
//
//  Previously submitted form values (never passwords), keyed by host and
//  field name, powering the in-page autocomplete dropdown. Chromium's own
//  autofill popup can't render under chrome-style CEF with native parent
//  views, so the app provides its own.
//

import Foundation

@MainActor
final class FormDataStore {
    static let shared = FormDataStore()

    /// host → field key → values, most recent first.
    private var data: [String: [String: [String]]] = [:]
    private let fileURL: URL

    private static let maxValuesPerField = 10
    private static let maxHosts = 200

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appending(path: "Sonrisa", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "formdata.json")
        if let raw = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: [String: [String]]].self, from: raw) {
            data = decoded
        }
    }

    func values(host: String, field: String) -> [String] {
        data[host]?[field] ?? []
    }

    func record(host: String, field: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return }
        // Never store card-number-looking values.
        let digits = trimmed.replacingOccurrences(of: "[\\s-]", with: "",
                                                  options: .regularExpression)
        if digits.count >= 12, digits.allSatisfy(\.isNumber) { return }

        var fields = data[host] ?? [:]
        var list = fields[field] ?? []
        list.removeAll { $0 == trimmed }
        list.insert(trimmed, at: 0)
        if list.count > Self.maxValuesPerField {
            list.removeLast(list.count - Self.maxValuesPerField)
        }
        fields[field] = list
        if data[host] == nil, data.count >= Self.maxHosts,
           let oldest = data.keys.first {
            data[oldest] = nil
        }
        data[host] = fields
        save()
    }

    func removeAll() {
        data = [:]
        save()
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }
}
