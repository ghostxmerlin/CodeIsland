import AppKit
import CodeIslandCore
import SwiftUI

/// Every dictated sentence, Mac or Tab5, with whether it reached the cursor: the safety net when typing fails.
/// Stored in ~/Library/Application Support/AISM/dictation-history.jsonl (owner-only, last 1000 sentences).
@MainActor
final class MeilingDictationHistory: ObservableObject {
    static let shared = MeilingDictationHistory()

    @Published private(set) var entries: [MeilingHistoryEntry]
    private let file = MeilingHistoryFile(url: MeilingSoftSettings.historyFile)
    private let log = MeilingLog()

    private init() {
        entries = file.load()
    }

    var fileURL: URL { file.url }

    /// A final sentence arrived; returns its id for `mark`.
    @discardableResult
    func add(_ heard: String, typed: String? = nil, source: String, status: MeilingHistoryEntry.Status = .pending,
             note: String? = nil) -> UUID {
        let entry = MeilingHistoryEntry(text: heard, typed: typed, source: source, status: status, note: note)
        entries.append(entry)
        if entries.count > file.maxEntries { entries.removeFirst(entries.count - file.maxEntries) }
        save()
        return entry.id
    }

    func mark(_ id: UUID, _ status: MeilingHistoryEntry.Status, note: String? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].status = status
        entries[i].note = note
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// Saves the owner's correction and learns its words; returns what was learned, for the confirmation.
    @discardableResult
    func correct(_ id: UUID, to text: String) -> [MeilingCorrection] {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return [] }
        let corrected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty, corrected != entries[i].shown else { return [] }
        let learned = MeilingCorrectionStore.shared.learn(heard: entries[i].text, corrected: corrected)
        entries[i].corrected = corrected
        save()
        return learned
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save() {
        do { try file.save(entries) } catch { log.write("history: save failed \(error.localizedDescription)") }
    }
}

/// The history window: newest first, search, copy one sentence or every sentence that was not typed.
@MainActor
final class MeilingHistoryWindow {
    static let shared = MeilingHistoryWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Meyrin Dictation History"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MeilingHistoryView(history: .shared))
            w.setFrameAutosaveName("MeilingHistoryWindow")
            if w.frame.origin == .zero { w.center() }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MeilingHistoryView: View {
    @ObservedObject var history: MeilingDictationHistory
    var limit: Int?  // the Settings page shows only the newest few
    @State private var search = ""
    @State private var copied: UUID?
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var learnedNote: String?

    private var shown: [MeilingHistoryEntry] {
        let newest = history.entries.reversed().filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
        return limit.map { Array(newest.prefix($0)) } ?? Array(newest)
    }

    var body: some View {
        if limit == nil {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                    Button("Copy Not Typed") {
                        let lost = history.entries.filter { $0.status != .typed }.map(\.shown)
                        MeilingDictationHistory.copy(lost.joined(separator: "\n"))
                    }
                    .disabled(!history.entries.contains { $0.status != .typed })
                    Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([history.fileURL]) }
                    Button("Clear…") { confirmClear() }.disabled(history.entries.isEmpty)
                }
                .padding(10)
                if let learnedNote {
                    Text(learnedNote).font(.caption).foregroundStyle(.green).padding(.horizontal, 10).padding(.bottom, 6)
                }
                Divider()
                if shown.isEmpty {
                    Text(history.entries.isEmpty ? "No dictation yet." : "Nothing matches.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(shown) { row($0) }
                }
            }
        } else {
            ForEach(shown) { row($0) }
            if history.entries.isEmpty { Text("No dictation yet.").foregroundStyle(.secondary) }
            if let learnedNote { Text(learnedNote).font(.caption).foregroundStyle(.green) }
        }
    }

    private func row(_ entry: MeilingHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon(entry.status))
                .foregroundStyle(color(entry.status))
                .help(label(entry))
            VStack(alignment: .leading, spacing: 2) {
                if editing == entry.id {
                    HStack {
                        TextField("Corrected sentence", text: $draft).textFieldStyle(.roundedBorder).onSubmit { save(entry) }
                        Button("Save") { save(entry) }
                        Button("Cancel") { editing = nil }
                    }
                } else {
                    Text(entry.shown).textSelection(.enabled)
                    if entry.shown != entry.text {
                        Text("heard: \(entry.text)").font(.caption).foregroundStyle(.secondary).strikethrough()
                    }
                }
                Text("\(entry.date.formatted(date: .abbreviated, time: .standard)) · \(entry.source) · \(label(entry))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if editing != entry.id {
                Button("Edit") {
                    draft = entry.shown
                    editing = entry.id
                }
                .help("Correct what was misheard: the corrected words are learned and fixed from now on")
                Button(copied == entry.id ? "Copied" : "Copy") {
                    MeilingDictationHistory.copy(entry.shown)
                    copied = entry.id
                }
            }
        }
    }

    private func save(_ entry: MeilingHistoryEntry) {
        let learned = history.correct(entry.id, to: draft)
        editing = nil
        learnedNote = learned.isEmpty ? "Saved. No single misheard word found to learn (a whole rewrite is not learned)."
            : "Learned: " + learned.map { "\($0.heard) → \($0.right)" }.joined(separator: ", ") + ". Fixed from now on."
    }

    private func icon(_ status: MeilingHistoryEntry.Status) -> String {
        switch status {
        case .typed: return "checkmark.circle.fill"
        case .notTyped: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        case .pending: return "clock"
        }
    }

    private func color(_ status: MeilingHistoryEntry.Status) -> Color {
        switch status {
        case .typed: return .green
        case .notTyped: return .orange
        case .cancelled, .pending: return .secondary
        }
    }

    private func label(_ entry: MeilingHistoryEntry) -> String {
        switch entry.status {
        case .typed: return "Typed"
        case .notTyped: return "Not typed" + (entry.note.map { " (\($0))" } ?? "")
        case .cancelled: return "Cancelled"
        case .pending: return "Not confirmed"
        }
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear dictation history?"
        alert.informativeText = "All \(history.entries.count) sentences are deleted from this Mac."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { history.clear() }
    }
}
