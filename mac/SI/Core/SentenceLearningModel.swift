/// A read-only conversion snapshot with the user's local word and gram evidence.
public final class SentenceLearningModel: Sendable {
    let conversion: RustConversion

    init(conversion: RustConversion) {
        self.conversion = conversion
    }
}
