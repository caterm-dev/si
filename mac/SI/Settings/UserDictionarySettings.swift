import Foundation
import Observation
import Carbon
#if SWIFT_PACKAGE
import SICore
import SIStorage
#endif

@MainActor
@Observable
final class UserDictionarySettings {
    static let shared = UserDictionarySettings()
    private(set) var dictionary = UserDictionary()
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var isImporting = false
    private var storageError: String?
    private var operationError: String?
    private(set) var notice: String?

    @ObservationIgnored private let store: UserDictionaryStore?
    @ObservationIgnored private let allowsSuggestions: @MainActor () -> Bool
    @ObservationIgnored private var loadSucceeded = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?

    var canEdit: Bool { loadSucceeded && !isLoading }
    var canRetrySaving: Bool { canEdit && storageError != nil }
    var errorMessage: String? {
        let messages = [storageError, operationError].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    var entries: [UserPhrase] { dictionary.entries }
    var dictionaryForInput: UserDictionary { canEdit && allowsSuggestions() ? dictionary : UserDictionary() }

    init(store: UserDictionaryStore? = nil, isPreview: Bool = false,
         allowsSuggestions: @escaping @MainActor () -> Bool = { !IsSecureEventInputEnabled() }) {
        self.store = isPreview ? nil : store ?? UserDictionaryStore(
            url: URL.applicationSupportDirectory.appending(path: "SI/UserDictionary/phrases-v1.json")
        )
        self.allowsSuggestions = allowsSuggestions
        if isPreview { isLoading = false; loadSucceeded = true }
    }

    func start() async {
        guard !hasStarted, isLoading, let store else { return }
        hasStarted = true
        do {
            dictionary = try await store.load()
            loadSucceeded = true
        } catch {
            storageError = "Saved phrases could not be opened. They have been left untouched. Clear the dictionary to start again."
        }
        isLoading = false
    }

    func save(_ phrase: UserPhrase) throws {
        guard canEdit else { throw CocoaError(.fileReadUnknown) }
        try dictionary.upsert(phrase)
        notice = nil
        operationError = nil
        scheduleSave()
    }

    func remove(id: UUID) {
        guard canEdit else { return }
        dictionary.remove(id: id)
        notice = nil
        operationError = nil
        scheduleSave()
    }

    func clear() {
        guard !isLoading else { return }
        dictionary.removeAll()
        pendingWrite?.cancel()
        revision += 1
        let current = revision
        notice = nil
        operationError = nil
        isSaving = true
        pendingWrite = Task {
            do {
                try await store?.erase(revision: current)
                guard current == revision else { return }
                loadSucceeded = true
                storageError = nil
                isSaving = false
            } catch {
                guard current == revision else { return }
                loadSucceeded = false
                storageError = "Saved phrases could not be cleared. Please retry."
                isSaving = false
            }
        }
    }

    func importFile(_ url: URL) async {
        guard canEdit, !isImporting, let store else { return }
        isImporting = true
        operationError = nil
        notice = nil
        let current = revision
        defer { isImporting = false }
        do {
            let imported = try await store.readImport(at: url)
            guard current == revision else {
                operationError = "Phrases changed while the file was being read. Import again to merge with the latest dictionary."
                return
            }
            let count = try dictionary.merge(imported)
            notice = "Imported \(count) phrases; skipped \(imported.entries.count - count) existing phrases."
            scheduleSave()
        } catch {
            operationError = "Import failed. Choose a valid SI dictionary JSON file with at most 1,000 phrases. Existing phrases have been kept."
        }
    }

    func exportData() async -> Data? {
        guard canEdit, let store else { return nil }
        operationError = nil
        do { return try await store.export(dictionary) }
        catch { operationError = "Phrases could not be prepared for export. Please retry."; return nil }
    }

    func reportFileActionFailure() {
        operationError = "The file operation could not be completed. Your saved phrases have been kept."
    }

    func flush() async {
        await pendingWrite?.value
        guard canEdit else { return }
        scheduleSave()
        await pendingWrite?.value
    }

    private func scheduleSave() {
        pendingWrite?.cancel()
        revision += 1
        let current = revision
        let snapshot = dictionary
        isSaving = true
        pendingWrite = Task {
            do {
                try await store?.save(snapshot, revision: current)
                guard current == revision else { return }
                storageError = nil
                isSaving = false
            } catch {
                guard current == revision else { return }
                storageError = "Phrase changes could not be saved. They remain in memory; retry saving before quitting."
                isSaving = false
            }
        }
    }
}
