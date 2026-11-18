import AppKit
import CodeIslandCore
import SwiftUI

/// The owner's vocabulary (~/Library/Application Support/AISM/meiling-terms.json), edited in Settings → Meyrin →
/// Vocabulary. Every change is written at once and announced through `onChange`: the vocabulary is fixed when a
/// session is set up, so the dictation opens a new one on the next press. The file stays the source of truth
/// (MeilingSoftSettings.vocabulary reads it), so `reload` picks up an edit made outside the app.
@MainActor
final class MeilingTermStore: ObservableObject {
    static let shared = MeilingTermStore()

    @Published private(set) var list = MeilingTermList()
    var onChange: (() -> Void)?
    private let url = MeilingSoftSettings.termsFile
    private let log = MeilingLog()

    private init() { reload() }

    func reload() {
        let terms = (try? Data(contentsOf: url)).map(MeilingSoftFiles.terms(from:)) ?? []
        if terms != list.terms { list = MeilingTermList(terms) }
    }

    @discardableResult
    func add(_ term: String) -> Bool { change { $0.add(term) } }

    @discardableResult
    func rename(_ old: String, to new: String) -> Bool { change { $0.rename(old, to: new) } }

    func remove(_ term: String) {
        change {
            $0.remove(term)
            return true
        }
    }

    private func change(_ edit: (inout MeilingTermList) -> Bool) -> Bool {
        reload()  // never write over an edit made in the file meanwhile
        var edited = list
        guard edit(&edited), edited != list else { return false }
        do {
            try edited.fileData().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.write("vocabulary: save failed \(error.localizedDescription)")
            return false
        }
        list = edited
        log.write("vocabulary: \(list.terms.count) terms")
        onChange?()
        return true
    }
}

/// The vocabulary window: add, search, click a term to change it, delete.
@MainActor
final class MeilingVocabularyWindow {
    static let shared = MeilingVocabularyWindow()
    private var window: NSWindow?

    func show() {
        MeilingTermStore.shared.reload()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Meyrin Vocabulary"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MeilingVocabularyView())
            w.setFrameAutosaveName("MeilingVocabularyWindow")
            if w.frame.origin == .zero { w.center() }
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MeilingVocabularyView: View {
    @ObservedObject private var store = MeilingTermStore.shared
    @ObservedObject private var corrections = MeilingCorrectionStore.shared
    @State private var newTerm = ""
    @State private var search = ""
    @State private var editing: String?
    @State private var draft = ""
    @State private var note: String?
    @FocusState private var draftFocused: Bool

    private var shown: [String] {
        store.list.terms.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let inUse = store.list.inUse(corrections: corrections.corrections, limit: MeilingSoftSettings.maxVocabulary)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Add a term…", text: $newTerm).textFieldStyle(.roundedBorder).onSubmit { add() }
                    Button("Add") { add() }.disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                Text(note ?? "\(store.list.terms.count) terms, \(inUse.count) in use. Words the transcription should know: names, jargon, product names. A common word here pulls ordinary speech toward it. Click a term to change it; changes apply from the next press.")
                    .font(.caption)
                    .foregroundStyle(note == nil ? Color.secondary : Color.orange)
            }
            .padding(10)
            Divider()
            if shown.isEmpty {
                Text(store.list.terms.isEmpty ? "No terms yet." : "Nothing matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown, id: \.self) { row($0, sent: inUse.contains($0)) }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }

    private func row(_ term: String, sent: Bool) -> some View {
        HStack {
            if editing == term {
                TextField("Term", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($draftFocused)
                    .onSubmit { save(term) }
                    .onExitCommand { editing = nil }
                Button("Save") { save(term) }
                Button("Cancel") { editing = nil }
            } else {
                Text(term)
                    .foregroundStyle(sent ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        note = nil
                        draft = term
                        editing = term
                        draftFocused = true
                    }
                    .help("Click to change")
                if !sent {
                    Text("not sent: over \(MeilingSoftSettings.maxVocabulary)").font(.caption).foregroundStyle(.secondary)
                }
                Button("Delete") {
                    note = nil
                    store.remove(term)
                }
            }
        }
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if store.add(term) {
            newTerm = ""
            note = nil
        } else {
            note = "\(term) is already in the list."
        }
    }

    private func save(_ term: String) {
        let new = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if new == term || store.rename(term, to: new) {
            editing = nil
            note = nil
        } else {
            note = new.isEmpty ? "A term cannot be empty: use Delete to remove it." : "\(new) is already in the list."
        }
    }
}
