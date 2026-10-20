import SwiftUI

@main
struct CodeIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var l10n = L10n.shared

    var body: some Scene {
        // SwiftUI needs a scene, but every window here is AppKit-hosted. A
        // `Settings { EmptyView() }` placeholder opened as an empty window on
        // every launch and from the app menu; a never-inserted menu bar extra
        // shows nothing.
        MenuBarExtra(AppBrand.name, isInserted: .constant(false)) {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(l10n["settings_ellipsis"]) {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
