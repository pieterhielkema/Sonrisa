//
//  AuthPrompt.swift
//  Sonrisa
//
//  Sheet asking for HTTP basic/digest credentials, presented on the window
//  that triggered the request.
//

import AppKit

@MainActor
enum AuthPrompt {
    static func present(host: String, port: Int, realm: String,
                        completion: @escaping (String?, String?) -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            completion(nil, nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Sign in to \(host)"
        alert.informativeText = realm.isEmpty
            ? "The server requires a username and password."
            : "The server says: “\(realm)”."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let username = NSTextField(frame: NSRect(x: 0, y: 32, width: 240, height: 24))
        username.placeholderString = "Username"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        password.placeholderString = "Password"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        container.addSubview(username)
        container.addSubview(password)
        alert.accessoryView = container
        alert.window.initialFirstResponder = username
        username.nextKeyView = password

        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completion(username.stringValue, password.stringValue)
            } else {
                completion(nil, nil)
            }
        }
    }
}
