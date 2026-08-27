//
//  PermissionPrompt.swift
//  Sonrisa
//
//  Allow/Block sheet for site capability requests (camera, mic, location…).
//

import AppKit

@MainActor
enum PermissionPrompt {
    static func present(origin: String, permissions: String,
                        completion: @escaping (Bool) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            completion(false)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Allow \(origin)?"
        alert.informativeText = "This site wants to use: \(permissions)."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Block")

        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }
}
