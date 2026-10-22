import Testing
@testable import SICore

struct InputQualityTests {
    @Test func upstreamWeightedVocabularyRetainsEverydaySentenceRegressions() {
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
        var firstChoices = 0
        for (input, expected) in examples {
            let candidates = engine.candidates(for: input, languages: Set(InputLanguage.allCases))
            if candidates.first?.text == expected { firstChoices += 1 }
            #expect(candidates.prefix(5).contains { $0.text == expected && !$0.isPartial }, "Input: \(input)")
            #expect(candidates.last?.text == input && candidates.last?.isLiteral == true)
        }
        // Preserve the existing quality gate while changing model units and search scoring.
        #expect(firstChoices >= 9)
    }
}
