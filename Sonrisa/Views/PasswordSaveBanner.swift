//
//  PasswordSaveBanner.swift
//  Sonrisa
//
//  Safari-style "Save this password?" prompt shown over the page after a
//  login form is submitted.
//

import SwiftUI

struct PasswordSaveBanner: View {
    let pending: PendingPasswordSave
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.tint)
                Text(pending.isUpdate
                     ? "Update the password for \(pending.host)?"
                     : "Save this password for \(pending.host)?")
                    .font(.headline)
            }
            if !pending.username.isEmpty {
                Text(pending.username)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Passwords are stored in your keychain and sync with iCloud Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Never for This Site") {
                    PasswordStore.shared.markNeverSave(host: pending.host)
                    onDismiss()
                }
                Spacer()
                Button("Not Now", action: onDismiss)
                Button(pending.isUpdate ? "Update Password" : "Save Password") {
                    PasswordStore.shared.save(host: pending.host,
                                              username: pending.username,
                                              password: pending.password)
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 380)
        // Solid, not material: the banner floats over the CEF surface, which
        // SwiftUI materials cannot sample — translucency just renders as a
        // murky gray. A solid window-background card matches native popovers.
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
    }
}
