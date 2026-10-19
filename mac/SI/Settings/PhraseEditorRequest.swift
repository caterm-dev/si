import Foundation

struct PhraseEditorRequest: Identifiable {
    let id = UUID()
    let phrase: UserPhrase?
}
