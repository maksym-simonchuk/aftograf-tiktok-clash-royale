import SwiftUI

/// Brand colors — crGold matches the render pipeline's progress-bar gold
/// (0xF7D046, RenderKit/Effects/ProgressBar.swift) so video and UI share
/// one identity.
extension Color {
    static let crGold = Color(red: 0xF7 / 255, green: 0xD0 / 255, blue: 0x46 / 255)
    static let crBackground = Color(red: 0x0E / 255, green: 0x0F / 255, blue: 0x13 / 255)
}
