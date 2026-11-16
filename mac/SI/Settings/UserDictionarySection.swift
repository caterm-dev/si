import SwiftUI

struct UserDictionarySection: View {
    let dictionary: SentenceLearningSettings
    var body: some View {
        UserDictionaryView(dictionary: dictionary)
    }
}
