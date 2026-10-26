import Foundation
import Testing
import SILocalization

struct LocalizationTests {
    @Test func bothLanguagesHaveCompleteTranslationsAndMatchingArguments() throws {
        let english = try strings("en")
        let chinese = try strings("zh-Hans")
        #expect(Set(english.keys) == Set(chinese.keys))
        #expect(!english.isEmpty)
        let placeholders = try NSRegularExpression(pattern: "%(@|ld)")
        for (key, value) in english {
            let translated = try #require(chinese[key])
            #expect(!translated.isEmpty)
            #expect(value == key)
            let arguments: (String) -> [String] = { text in
                placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                    String(text[Range($0.range, in: text)!])
                }
            }
            #expect(arguments(value) == arguments(translated), "Format arguments differ for \(key)")
        }
    }

    @Test func systemLanguageNegotiationSupportsRegionalVariantsAndEnglishFallback() {
        let supported = L10n.bundle.localizations
        #expect(supported.contains("en") && supported.contains("zh-Hans"))
        #expect(Bundle.preferredLocalizations(from: supported, forPreferences: ["zh-CN"]).first == "zh-Hans")
        #expect(Bundle.preferredLocalizations(from: supported, forPreferences: ["en-GB"]).first == "en")
        #expect(Bundle.preferredLocalizations(from: supported, forPreferences: ["fr"]).first == "en")
    }

    @Test func chineseControlsAndFormattedValuesUseResourcesWithoutTranslatingUserContent() throws {
        let chinese = try localizedBundle("zh-Hans")
        let english = try localizedBundle("en")
        #expect(L10n.text("SI Settings", bundle: chinese) == "SI 设置")
        #expect(L10n.text("Clear all personal phrases?", bundle: chinese) == "清空所有个人短语？")
        #expect(L10n.text("SI Settings", bundle: english) == "SI Settings")
        #expect(L10n.text("unrecognized.localization.key", bundle: chinese) == "unrecognized.localization.key")
        #expect(L10n.format("Page %ld of %ld", 2, 3, bundle: chinese) == "第 2 页，共 3 页")
        #expect(L10n.format("Imported: %ld; already saved: %ld.", 1, 0, bundle: chinese) == "已导入：1 条；已存在：0 条。")
        let phrase = "SI_build42 e\u{301} 你好 %@"
        let label = L10n.format("Edit phrase %@, code %@", phrase, "sig", bundle: chinese)
        #expect(label.utf8.elementsEqual("编辑短语 \(phrase)，输入码 sig".utf8))
    }

    private func localizedBundle(_ language: String) throws -> Bundle {
        let path = try #require(L10n.bundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private func strings(_ language: String) throws -> [String: String] {
        let bundle = try localizedBundle(language)
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }
}
