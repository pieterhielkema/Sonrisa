//
//  main.swift
//  Sonrisa
//
//  Custom entry point for CEF's single-executable model. CEF relaunches this
//  same binary for its sub-processes (renderer, GPU, ...); those launches must
//  be handled and exited before the SwiftUI app starts.
//

import AppKit
import SwiftUI

// When launched from Xcode, the environment carries a DYLD_INSERT_LIBRARIES
// entry for SwiftUI previews (__preview.dylib). CEF helper processes inherit
// the environment, can't resolve that dylib from their own bundles, and are
// killed by dyld before reaching main. Strip it before CEF spawns anything.
if let inserted = ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] {
    let kept = inserted.split(separator: ":").filter { !$0.hasSuffix("__preview.dylib") }
    if kept.isEmpty {
        unsetenv("DYLD_INSERT_LIBRARIES")
    } else {
        setenv("DYLD_INSERT_LIBRARIES", kept.joined(separator: ":"), 1)
    }
}

let subprocessExitCode = CEFRuntime.executeSubprocess()
if subprocessExitCode >= 0 {
    // This launch was a CEF sub-process; it has finished its work.
    exit(subprocessExitCode)
}

// Instantiate the CEF-aware NSApplication subclass BEFORE SwiftUI starts —
// the first sharedApplication call fixes the app object's class for good.
_ = SonrisaApplication.shared

// This is the main browser process — run the app.
SonrisaApp.main()
