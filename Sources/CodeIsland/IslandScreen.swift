import AppKit

/// The screen for AISM's own floating windows (the Meyrin HUD, Luna's card): the one the island is on, so they
/// appear next to the island instead of on whichever display has the focused window (owner 2026-10-26).
@MainActor
enum IslandScreen {
    static var current: NSScreen? {
        PanelWindowController.current?.islandScreen ?? NSScreen.main ?? NSScreen.screens.first
    }
}
