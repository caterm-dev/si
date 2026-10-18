import Foundation

/// Original demonstration entries. Production decoding and lexicon data are future work.
public struct PinyinCandidateProvider: CandidateProvider {
    public let language = InputLanguage.simplifiedChinese
    private let lexicon: [String: [String]] = [
        "ni": ["你", "呢", "泥"], "hao": ["好", "号", "浩"], "nihao": ["你好"],
        "shi": ["是", "时", "事", "十"], "wo": ["我", "握"], "women": ["我们"],
        "de": ["的", "得", "地"], "ha": ["哈"], "he": ["和", "喝", "河"],
        "ma": ["吗", "马", "妈"], "zhongwen": ["中文"], "yingwen": ["英文"],
        "shuru": ["输入"], "shurufa": ["输入法"], "shijie": ["世界"],
        "xiexie": ["谢谢"], "zaijian": ["再见"], "ceshi": ["测试"],
    ]

    public init() {}

    public func candidates(for input: String) -> [InputCandidate] {
        let key = input.lowercased().replacing("'", with: "")
        return (lexicon[key] ?? []).enumerated().map { index, text in
            InputCandidate(text: text, language: language, score: 100 - index)
        }
    }
}
