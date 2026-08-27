//
//  PasswordsSettingsView.swift
//  Sonrisa
//
//  Settings tab listing saved web passwords: reveal (after Touch ID / account
//  password authentication), copy, and delete.
//

import AppKit
import SwiftUI

struct PasswordsSettingsView: View {
    private var store = PasswordStore.shared
    @State private var revealed: [SavedCredential.ID: String] = [:]
    @State private var pendingDelete: SavedCredential?

    var body: some View {
        Form {
            if store.credentials.isEmpty {
                Text("No saved passwords yet. When you sign in to a website, Sonrisa offers to save the password.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(store.credentials) { credential in
                        row(credential)
                    }
                }
                Text("\(store.credentials.count) saved passwords, stored in your keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .confirmationDialog(
            "Remove the password for \(pendingDelete?.host ?? "")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Remove Password", role: .destructive) {
                if let credential = pendingDelete {
                    store.delete(credential)
                }
                pendingDelete = nil
            }
        }
    }

    private func row(_ credential: SavedCredential) -> some View {
        HStack(spacing: 10) {
            FaviconView(host: credential.host, fallbackSymbol: "globe", size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(credential.host)
                if !credential.username.isEmpty {
                    Text(credential.username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let password = revealed[credential.id] {
                    Text(password)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button {
                toggleReveal(credential)
            } label: {
                Image(systemName: revealed[credential.id] == nil ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .help(revealed[credential.id] == nil ? "Show Password" : "Hide Password")

            Button {
                copy(credential)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy Password")

            Button(role: .destructive) {
                pendingDelete = credential
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove Password")
        }
    }

    private func toggleReveal(_ credential: SavedCredential) {
        if revealed[credential.id] != nil {
            revealed[credential.id] = nil
            return
        }
        Task {
            if let password = await store.passwordAfterAuthentication(for: credential) {
                revealed[credential.id] = password
            }
        }
    }

    private func copy(_ credential: SavedCredential) {
        Task {
            guard let password = await store.passwordAfterAuthentication(for: credential)
            else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(password, forType: .string)
        }
    }
}

#Preview {
    PasswordsSettingsView()
}
