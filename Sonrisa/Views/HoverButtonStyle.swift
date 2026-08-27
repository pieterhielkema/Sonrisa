//
//  HoverButtonStyle.swift
//  Sonrisa
//
//  Icon-button style with a capsule highlight on hover and a pressed state,
//  matching the toolbar-button feel of native macOS apps.
//

import SwiftUI

struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButton(configuration: configuration)
    }

    private struct HoverButton: View {
        let configuration: Configuration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background {
                    Capsule()
                        .fill(highlight)
                }
                .onHover { isHovering = $0 }
        }

        private var highlight: AnyShapeStyle {
            guard isEnabled else { return AnyShapeStyle(.clear) }
            if configuration.isPressed {
                return AnyShapeStyle(.tertiary.opacity(0.6))
            }
            if isHovering {
                return AnyShapeStyle(.quaternary.opacity(0.8))
            }
            return AnyShapeStyle(.clear)
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    /// Capsule hover/press highlight for toolbar-like icon buttons.
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}

/// Capsule highlight on hover for views that can't use a ButtonStyle (e.g. `Menu`).
private struct CapsuleHover: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                Capsule().fill(isHovering ? AnyShapeStyle(.quaternary.opacity(0.8)) : AnyShapeStyle(.clear))
            }
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Applies the same capsule hover highlight as `.buttonStyle(.hover)`.
    func capsuleHover() -> some View { modifier(CapsuleHover()) }
}
