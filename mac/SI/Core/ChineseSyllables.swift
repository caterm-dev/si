// Adapted from MSIME pinyin/syllables.rs and segment.rs, GPL-3.0-only.
// Pinned upstream and local adaptations: Data/Chinese/MSIME/sources.lock.json.
import Foundation

enum ChineseSyllables {
    static let complete: Set<String> = Set("""
    a ai an ang ao ba bai ban bang bao bei ben beng bi bian biang biao bie bin bing bo bu ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo e ei en er fa fan fang fei fen feng fiao fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun jv jve ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lue lun luo lv lve ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nue nun nuo nv nve o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun qv qve ran rang rao re ren reng ri rong rou ru ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun xv xve ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun yv yve za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
    """.split(separator: " ").map(String.init))
    static let prefixes: Set<String> = Set(complete.flatMap { syllable in
        (1...syllable.count).map { String(syllable.prefix($0)) }
    })

    static func canonical(_ syllable: String) -> String {
        switch syllable {
        case "jv": "ju"
        case "qv": "qu"
        case "xv": "xu"
        case "yv": "yu"
        case "jve": "jue"
        case "qve": "que"
        case "xve": "xue"
        case "yve": "yue"
        case "lue": "lve"
        case "nue": "nve"
        default: syllable
        }
    }

    /// Minimum syllable count; ties hand the consonant to the later syllable.
    static func primary(_ input: PinyinInput, personal: UserDictionary = UserDictionary()) -> [String] {
        let letters = input.letters
        if input.separators.isEmpty { return minimumCut(letters, personal: personal) }
        var result: [String] = []
        var start = 0
        // MSIME cuts each explicit chunk independently. An unsegmentable chunk remains
        // a raw lookup segment rather than erasing useful prefixes before the separator.
        for end in input.separators.union([letters.count]).sorted() where end > start {
            let chunk = Array(letters[start..<end])
            let cut = minimumCut(chunk, personal: personal)
            result += cut.isEmpty ? [String(chunk)] : cut
            start = end
        }
        return result
    }

    private static func minimumCut(_ letters: [Character], personal: UserDictionary) -> [String] {
        let count = letters.count
        var best = Array<(end: Int, count: Int)?>(repeating: nil, count: count + 1)
        for start in (0..<count).reversed() {
            for end in (start + 1...min(count, start + max(6, personal.maximumCodeLength))).reversed() {
                let piece = String(letters[start..<end])
                let isPersonal = personal.phrases(for: piece).contains { $0.language == .simplifiedChinese }
                guard prefixes.contains(piece) || isPersonal else { continue }
                let suffix: Int? = end == count ? 0 : best[end]?.count
                guard let suffix else { continue }
                let candidate = (end: end, count: suffix + 1)
                if best[start] == nil || candidate.count < best[start]!.count
                    || (candidate.count == best[start]!.count && end < best[start]!.end) {
                    best[start] = candidate
                }
            }
        }
        var result: [String] = []
        var start = 0
        while start < count {
            guard let next = best[start] else { return [] }
            result.append(String(letters[start..<next.end]))
            start = next.end
        }
        return result
    }

    /// Complete alternative segmentations of short input, in longest-edge-first order.
    static func alternatives(_ input: PinyinInput, limit: Int = 32) -> [[String]] {
        let count = input.letters.count
        var edges = Array(repeating: [(end: Int, text: String)](), count: count + 1)
        var reachable = Array(repeating: false, count: count + 1)
        reachable[count] = true
        for start in (0..<count).reversed() {
            for end in (start + 1...min(count, start + 6)).reversed() where reachable[end] {
                guard !input.separators.contains(where: { $0 > start && $0 < end }) else { continue }
                let piece = String(input.letters[start..<end])
                if complete.contains(piece) { edges[start].append((end, piece)) }
            }
            reachable[start] = !edges[start].isEmpty
        }
        var paths: [[String]] = []
        var current: [String] = []
        func visit(_ start: Int) {
            guard paths.count < limit else { return }
            if start == count { paths.append(current); return }
            for edge in edges[start] {
                current.append(edge.text)
                visit(edge.end)
                current.removeLast()
                if paths.count >= limit { return }
            }
        }
        if reachable[0] { visit(0) }
        return paths
    }
}
