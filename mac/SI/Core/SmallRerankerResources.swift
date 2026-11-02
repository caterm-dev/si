import Foundation

public enum SmallRerankerResources {
    public static var directory: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: "Reranker", withExtension: nil)
        #else
        Bundle.main.url(forResource: "Reranker", withExtension: nil)
        #endif
    }
}
