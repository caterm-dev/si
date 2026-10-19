import Testing
@testable import SICore

struct InputQualityTests {
    @Test func originalVocabularyGeneralizesToHeldOutEverydaySentences() {
        let examples = [
            ("woxiangyaoyigehaoyongdeshurufa", "我想要一个好用的输入法"),
            ("mingtianwomenqubeijing", "明天我们去北京"),
            ("jintiantianqihenhao", "今天天气很好"),
            ("zhegeshurufakeyishuruzhongwenheyingwen", "这个输入法可以输入中文和英文"),
            ("qingbangwobaocunwenjian", "请帮我保存文件"),
            ("womenzaibendixuexi", "我们在本地学习"),
            ("tianjiayigezidingyiduanyu", "添加一个自定义短语"),
            ("guanbichuangkou", "关闭窗口"),
            ("qingjianchashurujieguo", "请检查输入结果"),
            ("zhegewenjianmingbaohanyingwen", "这个文件名包含英文"),
        ]
        let engine = CandidateEngine()
        for (input, expected) in examples {
            #expect(!OriginalPinyinLexicon.entries.contains { $0.code == input })
            let candidates = engine.candidates(for: input, languages: Set(InputLanguage.allCases))
            #expect(candidates.first?.text == expected, "Input: \(input)")
            #expect(candidates.last?.text == input && candidates.last?.isLiteral == true)
        }
    }
}
