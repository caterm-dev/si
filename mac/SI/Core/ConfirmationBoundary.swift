/// Exact lexical boundary on one decoded path. Offsets refer to source characters and output UTF-8 bytes.
/// This transient evidence never participates in candidate identity or persistence.
public struct ConfirmationBoundary: Equatable, Sendable {
    public let sourceCount: Int
    public let outputByteCount: Int

    init(sourceCount: Int, outputByteCount: Int) {
        self.sourceCount = sourceCount
        self.outputByteCount = outputByteCount
    }
}
