use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use si_engine::resources::EngineResources;
use si_engine::resources::user::{UserLearningConfig, UserModelStore};
use si_engine::{
    Candidate, CandidateEngine, CandidateLanguage, ConversionOptions, ConversionPreferences,
    EnabledLanguages, PersonalPhrase, SmallReranker,
};
use si_gram::GramBuilder;
use si_lexicon::{IndexId, Lexicon, WordId};

const ZH: IndexId = IndexId(0);
const EN: IndexId = IndexId(1);
const BILINGUAL: EnabledLanguages = EnabledLanguages {
    chinese: true,
    english: true,
};
const CHINESE: EnabledLanguages = EnabledLanguages {
    chinese: true,
    english: false,
};
const ENGLISH: EnabledLanguages = EnabledLanguages {
    chinese: false,
    english: true,
};

#[test]
fn small_reranker_scores_twelve_homophones_and_excludes_the_thirteenth() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for text in [
        "诗", "施", "狮", "尸", "师", "失", "湿", "时", "十", "史", "始", "是", "市",
    ] {
        add(&mut lexicon, ZH, "shi", text, 100);
    }
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let baseline = engine.candidates("shi", CHINESE);
    let model = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Data/RerankerSmall");
    let reranker = SmallReranker::open(&model)?;
    let ranked = engine.convert_with_options(
        "shi",
        CHINESE,
        false,
        &[],
        ConversionPreferences::default(),
        "",
        ConversionOptions {
            correction: None,
            reranker: Some(&reranker),
        },
    );
    assert_eq!(baseline.len(), 14);
    assert_eq!(ranked.len(), baseline.len());
    // The model measures rewards relative to its lowest-scoring result, which gets zero.
    assert_eq!(
        ranked
            .iter()
            .filter(|row| row.reranking_bonus > 0.0)
            .count(),
        11
    );
    assert_eq!(
        ranked
            .iter()
            .find(|row| row.text == baseline[12].text)
            .unwrap()
            .reranking_bonus,
        0.0
    );
    assert_eq!(ranked.last(), baseline.last());
    Ok(())
}

#[test]
fn small_reranker_scores_beyond_two_bits_and_caps_the_bonus_at_two() -> io::Result<()> {
    let directory = Scratch::new()?;
    let model = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Data/RerankerSmall");
    let reranker = SmallReranker::open(&model)?;

    // Score candidates across large statistical gaps while retaining the reward cap.
    for (leader_count, expected_first) in
        [(390, "原始拼写"), (410, "元是拼写"), (10_000, "元是拼写")]
    {
        let mut lexicon = Lexicon::new();
        add(
            &mut lexicon,
            ZH,
            "yuan'shi'pin'xie",
            "元是拼写",
            leader_count,
        );
        add(&mut lexicon, ZH, "yuan'shi'pin'xie", "原始拼写", 100);
        let resources = directory.resources(&mut lexicon, None)?;
        let engine = CandidateEngine::new(&resources, None);
        let baseline = engine.candidates("yuanshipinxie", CHINESE);
        assert_eq!(baseline[0].text, "元是拼写");

        let ranked = engine.convert_with_options(
            "yuanshipinxie",
            CHINESE,
            false,
            &[],
            ConversionPreferences::default(),
            "",
            ConversionOptions {
                correction: None,
                reranker: Some(&reranker),
            },
        );
        let expected = ranked.iter().find(|row| row.text == "原始拼写").unwrap();
        assert_eq!(ranked[0].text, expected_first);
        assert_eq!(expected.score_bits, baseline[1].score_bits);
        assert_eq!(expected.reranking_bonus, 2.0);
    }
    Ok(())
}

#[test]
fn reused_search_statistics_preserve_edits_context_and_request_preferences() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let ni = add(&mut lexicon, ZH, "ni", "你", 100);
    let hao = add(&mut lexicon, ZH, "hao", "好", 100);
    add(&mut lexicon, ZH, "ni'hao", "你好", 200);
    add(&mut lexicon, ZH, "ni'hao", "拟好", 100);
    add(&mut lexicon, ZH, "lv", "绿", 100);
    add(&mut lexicon, ZH, "xi'an", "西安", 100);
    add(&mut lexicon, ZH, "xian", "先", 100);
    let hello = add(&mut lexicon, EN, "hello", "hello", 100);
    let world = add(&mut lexicon, EN, "world", "world", 100);
    let mut grams = GramBuilder::new();
    grams.add(&[ni, hao], 100).unwrap();
    grams.add(&[hello, world], 100).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let reused = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    let tokens = [si_engine::TokenPreference {
        spelling: "nihao",
        text: "拟好",
        language: CandidateLanguage::Chinese,
        bonus: 20.0,
    }];
    let paths = [si_engine::PathPreference {
        consumed_bytes: 5,
        text: "拟好",
        language: CandidateLanguage::Chinese,
        frequency: 24.0,
        contextual: 0.0,
    }];
    let phrases = [PersonalPhrase {
        spelling: "nihao",
        text: "私有词",
        language: CandidateLanguage::Chinese,
        pinned: true,
    }];
    let mut inputs = Vec::new();
    for source in ["nihao", "nihoa", "helloworld", "nihaoworld"] {
        inputs.extend((1..=source.len()).map(|end| source[..end].to_owned()));
        inputs.extend((1..source.len()).rev().map(|end| source[..end].to_owned()));
    }
    inputs.extend(
        [
            "NIHAO",
            "HelloWorld",
            "lü",
            "lu:",
            "lu",
            "lv",
            "xi'an",
            "xian",
            "未知",
        ]
        .map(str::to_owned),
    );
    for (index, input) in inputs.iter().enumerate() {
        let fresh = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
        let languages = [
            BILINGUAL,
            CHINESE,
            ENGLISH,
            EnabledLanguages {
                chinese: false,
                english: false,
            },
        ][index % 4];
        let context = ["", "你", "hello", "未知"][index % 4];
        let preferences = if index % 2 == 0 {
            ConversionPreferences {
                tokens: &tokens,
                paths: &paths,
            }
        } else {
            ConversionPreferences::default()
        };
        let personal = if index % 3 == 0 {
            phrases.as_slice()
        } else {
            &[]
        };
        for preview in [false, true] {
            assert_eq!(
                reused.convert_with_context(
                    input,
                    languages,
                    preview,
                    personal,
                    preferences,
                    context
                ),
                fresh.convert_with_context(
                    input,
                    languages,
                    preview,
                    personal,
                    preferences,
                    context
                ),
                "reused decoding after edit {index}: {input}"
            );
        }
    }
    Ok(())
}

#[test]
fn concurrent_queries_share_resources_without_sharing_compositions() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    add(&mut lexicon, ZH, "lv", "绿", 100);
    add(&mut lexicon, EN, "hello", "hello", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    let inputs = ["nihao", "nihoa", "Hello", "lu:"];
    let expected: Vec<_> = inputs
        .iter()
        .map(|input| engine.candidates(input, BILINGUAL))
        .collect();
    std::thread::scope(|scope| {
        for (input, expected) in inputs.iter().zip(&expected) {
            let engine = &engine;
            scope.spawn(move || {
                for _ in 0..10 {
                    assert_eq!(&engine.candidates(input, BILINGUAL), expected);
                }
            });
        }
    });
    Ok(())
}

#[test]
fn dictionary_words_share_one_frequency_distribution_without_token_costs() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "you", "有", 29);
    add(&mut lexicon, ZH, "wu", "无", 10);
    add(&mut lexicon, ZH, "wu", "五", 0);
    add(&mut lexicon, ZH, "ni'hao", "你好", 29);
    let english = add(&mut lexicon, EN, "you", "you", 29);
    let thanks = add(&mut lexicon, EN, "thanks", "thanks", 10);
    let mut grams = GramBuilder::new();
    grams.add(&[thanks, english], 1_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);

    for preview in [false, true] {
        let convert = |context| {
            engine.convert_with_context(
                "you",
                BILINGUAL,
                preview,
                &[],
                ConversionPreferences::default(),
                context,
            )
        };
        let without_context = convert("");
        let unigram_bits = (29.0_f64 / 107.0).log2();
        let expected = Some(unigram_bits);
        assert_eq!(
            find(&without_context, "you", CandidateLanguage::English, 3).score_bits,
            expected
        );
        assert_eq!(
            find(&without_context, "有", CandidateLanguage::Chinese, 3).score_bits,
            expected
        );
        let standalone = engine.candidates("nihao", CHINESE);
        assert_eq!(
            find(&standalone, "你好", CandidateLanguage::Chinese, 5).score_bits,
            expected
        );
        let zero = engine.candidates("wu", CHINESE);
        assert!(
            find(&zero, "五", CandidateLanguage::Chinese, 2)
                .score_bits
                .unwrap()
                .is_finite()
        );
        let sequence = engine.convert_with_context(
            "wuyou",
            BILINGUAL,
            preview,
            &[],
            ConversionPreferences::default(),
            "",
        );
        let composed = Some((10.0_f64 / 107.0).log2() + unigram_bits);
        assert_eq!(
            find(&sequence, "无有", CandidateLanguage::Chinese, 5).score_bits,
            composed
        );
        assert_eq!(
            find(&sequence, "无 you", CandidateLanguage::Mixed, 5).score_bits,
            composed
        );
        assert_literal(without_context.last().unwrap(), "you");

        let with_context = convert("Thanks ");
        assert_eq!(with_context[0].text, "you");
        assert_eq!(with_context[0].language, CandidateLanguage::English);
        assert!(has(&with_context, "有", CandidateLanguage::Chinese, 3));
        assert_literal(with_context.last().unwrap(), "you");
    }
    Ok(())
}

#[test]
fn gram_history_and_continuation_mass_span_languages() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let try_word = add(&mut lexicon, EN, "try", "try", 20);
    let yes = add(&mut lexicon, ZH, "you", "有", 20);
    let you = add(&mut lexicon, EN, "you", "you", 20);
    let book = add(&mut lexicon, ZH, "shu", "书", 20);
    let mut grams = GramBuilder::new();
    grams.add(&[try_word, yes], 64).unwrap();
    grams.add(&[try_word, you], 32).unwrap();
    grams.add(&[try_word, yes, book], 512).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);

    let unigram = 0.25_f64;
    let mixed_bigram = (64.0 + 32.0 * unigram) / 128.0;
    let same_language_bigram = (32.0 + 32.0 * unigram) / 128.0;
    let mixed_trigram = (1.0 - 0.8) * unigram + 0.8;
    for preview in [false, true] {
        let convert = |source, preceding| {
            engine.convert_with_context(
                source,
                BILINGUAL,
                preview,
                &[],
                ConversionPreferences::default(),
                preceding,
            )
        };
        let rows = convert("tryyou", "");
        assert_eq!(
            find(&rows, "try 有", CandidateLanguage::Mixed, 6).score_bits,
            Some(unigram.log2() + mixed_bigram.log2()),
        );
        assert_eq!(
            find(&rows, "try you", CandidateLanguage::English, 6).score_bits,
            Some(unigram.log2() + same_language_bigram.log2()),
        );
        let rows = convert("you", "Try ");
        assert_eq!(rows[0].text, "有");
        assert_eq!(
            rows[0].context_adjustment,
            mixed_bigram.log2() - unigram.log2()
        );
        let rows = convert("shu", "Try 有");
        assert_eq!(
            rows[0].context_adjustment,
            mixed_trigram.log2() - unigram.log2()
        );
        let rows = convert("you", "Try 有");
        let absent = find(&rows, "you", CandidateLanguage::English, 3);
        assert!((absent.context_adjustment - (1.0_f64 - 0.8).log2()).abs() < 1e-12);
    }
    Ok(())
}

#[test]
fn preceding_field_uses_only_the_last_sentence_for_gram_scoring() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let previous = add(&mut lexicon, ZH, "he'shui", "喝水", 20);
    let terminal = add(&mut lexicon, ZH, "guo", "过", 10);
    let river = add(&mut lexicon, ZH, "he", "河", 4);
    let together = add(&mut lexicon, ZH, "he", "和", 40);
    let the = add(&mut lexicon, EN, "the", "the", 15);
    let english = add(&mut lexicon, EN, "he", "he", 15);
    let mut grams = GramBuilder::new();
    grams.add(&[previous, together], 1_000).unwrap();
    grams.add(&[terminal, river], 1_000).unwrap();
    grams.add(&[previous, terminal, river], 1_000).unwrap();
    grams.add(&[the, english], 1_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    let convert = |text, context, preview| {
        engine.convert_with_context(
            text,
            BILINGUAL,
            preview,
            &[],
            ConversionPreferences::default(),
            context,
        )
    };
    for preview in [false, true] {
        let baseline = convert("he", "", preview);
        let latest = convert("he", "过。", preview);
        assert_eq!(latest, convert("he", "喝水！过。 ” ", preview));
        assert_eq!(latest, convert("he", "喝水\n过", preview));
        assert_eq!(latest, convert("he", "喝水。过，", preview));
        assert_eq!(convert("he", "喝水。🦉", preview), baseline);
        assert_ne!(latest, baseline);
        let first_chinese = |rows: &[Candidate]| {
            rows.iter()
                .find(|candidate| candidate.language == CandidateLanguage::Chinese)
                .unwrap()
                .text
                .clone()
        };
        assert_eq!(first_chinese(&baseline), "和");
        assert_eq!(first_chinese(&latest), "河");
        assert!(find(&latest, "he", CandidateLanguage::English, 2).context_adjustment < 0.0);
        assert!(
            find(
                &convert("he", "The ", preview),
                "he",
                CandidateLanguage::English,
                2
            )
            .context_adjustment
                > 0.0
        );
        let river = find(&latest, "河", CandidateLanguage::Chinese, 2);
        assert_eq!(
            river.score_bits,
            find(&baseline, "河", CandidateLanguage::Chinese, 2).score_bits
        );
        assert_eq!(
            river.context_adjustment,
            find(
                &convert("he'guo", "过。", preview),
                "河",
                CandidateLanguage::Chinese,
                3
            )
            .context_adjustment
        );
        assert!(
            find(
                &convert("he", "喝水过", preview),
                "河",
                CandidateLanguage::Chinese,
                2
            )
            .context_adjustment
                > river.context_adjustment
        );
        assert_literal(latest.last().unwrap(), "he");
    }
    let phrase = PersonalPhrase {
        spelling: "qxz",
        text: "小鹿",
        language: CandidateLanguage::Chinese,
        pinned: false,
    };
    let with_phrase = engine.convert_with_context(
        "heqxz",
        CHINESE,
        false,
        &[phrase],
        ConversionPreferences::default(),
        "过",
    );
    let personal = find(&with_phrase, "河小鹿", CandidateLanguage::Chinese, 5);
    assert!(personal.personal);
    assert_eq!(personal.context_adjustment, 0.0);
    let with_verbatim = convert("hezz", "过", false);
    let verbatim = find(&with_verbatim, "河zz", CandidateLanguage::Mixed, 4);
    assert!(verbatim.verbatim);
    assert_eq!(verbatim.context_adjustment, 0.0);
    Ok(())
}

#[test]
fn enabled_languages_preserve_ambiguous_and_literal_identities() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for (index, reading, text, count) in [
        (ZH, "he", "和", 20),
        (ZH, "he", "河", 4),
        (EN, "he", "he", 18),
        (EN, "he", "和", 1),
        (EN, "help", "help", 1),
    ] {
        add(&mut lexicon, index, reading, text, count);
    }
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let candidates = engine.candidates("he", BILINGUAL);
    assert_eq!(candidates, engine.candidates("he", BILINGUAL));
    assert!(has(&candidates, "和", CandidateLanguage::Chinese, 2));
    assert!(has(&candidates, "和", CandidateLanguage::English, 2));
    assert!(has(&candidates, "he", CandidateLanguage::English, 2));
    assert!(has(&candidates, "help", CandidateLanguage::English, 2));
    assert_literal(candidates.last().unwrap(), "he");
    assert!(engine.candidates("he", CHINESE).iter().all(|candidate| {
        matches!(
            candidate.language,
            CandidateLanguage::Chinese | CandidateLanguage::Literal
        )
    }));
    assert!(engine.candidates("he", ENGLISH).iter().all(|candidate| {
        matches!(
            candidate.language,
            CandidateLanguage::English | CandidateLanguage::Literal
        )
    }));
    let literal = "He_Σ🙂\n";
    let disabled = EnabledLanguages {
        chinese: false,
        english: false,
    };
    assert_eq!(engine.candidates(literal, disabled).len(), 1);
    assert_literal(&engine.candidates(literal, disabled)[0], literal);
    let unknown = "🦉\u{301}_UNKNOWN";
    assert_eq!(engine.candidates(unknown, BILINGUAL).len(), 1);
    assert_literal(&engine.candidates(unknown, BILINGUAL)[0], unknown);
    let combined = "he\u{301}";
    assert_eq!(engine.candidates(combined, BILINGUAL).len(), 1);
    assert_literal(&engine.candidates(combined, BILINGUAL)[0], combined);
    assert!(has(
        &engine.candidates("he🙂", BILINGUAL),
        "he",
        CandidateLanguage::English,
        2
    ));
    assert!(engine.candidates("", BILINGUAL).is_empty());
    Ok(())
}

#[test]
fn explicit_pinyin_boundaries_and_umlaut_aliases_keep_exact_source_bytes() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for (reading, text, count) in [
        ("xi'an", "西安", 60),
        ("xian", "先", 80),
        ("xi", "西", 40),
        ("an", "安", 20),
        ("lv", "绿", 60),
        ("lv'se", "绿色", 120),
        ("se", "色", 10),
        ("ju", "居", 20),
    ] {
        add(&mut lexicon, ZH, reading, text, count);
    }
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let candidates = engine.candidates("xian", CHINESE);
    assert!(has(&candidates, "先", CandidateLanguage::Chinese, 4));
    assert!(has(&candidates, "西安", CandidateLanguage::Chinese, 4));
    let separated = engine.candidates("xi'an", CHINESE);
    assert!(has(&separated, "西安", CandidateLanguage::Chinese, 5));
    assert!(!has(&separated, "先", CandidateLanguage::Chinese, 5));
    assert!(has(&separated, "西", CandidateLanguage::Chinese, 3));
    assert!(!has(
        &engine.candidates("x'ian", CHINESE),
        "西安",
        CandidateLanguage::Chinese,
        5
    ));

    let prefix_score = find(
        &engine.candidates("lv", CHINESE),
        "绿",
        CandidateLanguage::Chinese,
        2,
    )
    .score_bits;
    let complete_score = find(
        &engine.candidates("lvse", CHINESE),
        "绿色",
        CandidateLanguage::Chinese,
        4,
    )
    .score_bits;
    for input in ["lü'se", "lu:'se", "lv'se", "lu\u{308}'se"] {
        let (prefix, _) = input.split_at(input.find('\'').unwrap() + 1);
        let candidates = engine.candidates(input, CHINESE);
        assert_eq!(
            find(&candidates, "绿", CandidateLanguage::Chinese, prefix.len()).score_bits,
            prefix_score
        );
        assert_eq!(
            find(&candidates, "绿色", CandidateLanguage::Chinese, input.len()).score_bits,
            complete_score
        );
        assert_literal(candidates.last().unwrap(), input);
    }
    let pending = engine.candidates("lü'🙂", CHINESE);
    assert_eq!(
        find(&pending, "绿", CandidateLanguage::Chinese, "lü'".len()).score_bits,
        prefix_score
    );
    for spelling in ["ju", "jü", "ju:", "jv"] {
        assert!(has(
            &engine.candidates(spelling, CHINESE),
            "居",
            CandidateLanguage::Chinese,
            spelling.len()
        ));
    }
    Ok(())
}

#[test]
fn word_paths_cover_chinese_english_and_mixed_inputs_with_tail_completion() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for (index, reading, text) in [
        (ZH, "wo", "我"),
        (ZH, "xiang", "想"),
        (ZH, "ni", "你"),
        (ZH, "hao", "好"),
        (EN, "deploy", "deploy"),
        (EN, "hello", "hello"),
        (EN, "world", "world"),
        (EN, "node.js", "Node.js"),
    ] {
        add(&mut lexicon, index, reading, text, 10);
    }
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let mixed_input = "woxiangDeploy";
    let mixed = engine.candidates(mixed_input, BILINGUAL);
    assert_eq!(mixed[0].text, "我想 Deploy");
    assert!(
        !find(
            &mixed,
            "我想 Deploy",
            CandidateLanguage::Mixed,
            mixed_input.len()
        )
        .completion
    );
    assert!(
        find(
            &engine.candidates("woxiangdep", BILINGUAL),
            "我想 deploy",
            CandidateLanguage::Mixed,
            10
        )
        .completion
    );
    assert!(has(
        &engine.candidates("HELLOworld", BILINGUAL),
        "HELLO world",
        CandidateLanguage::English,
        10
    ));
    assert!(has(
        &engine.candidates("node.js", BILINGUAL),
        "Node.js",
        CandidateLanguage::English,
        7
    ));
    assert!(has(
        &engine.candidates("deploynihao", BILINGUAL),
        "deploy 你好",
        CandidateLanguage::Mixed,
        11
    ));
    assert!(
        find(
            &engine.candidates("niha", CHINESE),
            "你好",
            CandidateLanguage::Chinese,
            4
        )
        .completion
    );
    assert!(
        !find(
            &engine.candidates("nihao", CHINESE),
            "你好",
            CandidateLanguage::Chinese,
            5
        )
        .completion
    );
    assert!(
        engine
            .candidates(mixed_input, CHINESE)
            .iter()
            .all(|candidate| {
                matches!(
                    candidate.language,
                    CandidateLanguage::Chinese | CandidateLanguage::Literal
                )
            })
    );
    Ok(())
}

#[test]
fn gram_scores_select_a_rare_path_before_the_terminal_limit() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let pick_up = add(&mut lexicon, ZH, "shou'shi", "收拾", 100);
    add(&mut lexicon, ZH, "shou'shi", "首饰", 200);
    let luggage = add(&mut lexicon, ZH, "xing'li", "行李", 1);
    for index in 0..40 {
        add(
            &mut lexicon,
            ZH,
            "xing'li",
            &format!("行李{index:02}"),
            1000,
        );
    }
    let mut grams = GramBuilder::new();
    grams.add(&[pick_up, luggage], u64::MAX).unwrap();
    let with_grams = directory.resources(&mut lexicon, Some(grams))?;
    let without_grams = EngineResources::open(&directory.path("base.silex"), None)?;
    let base = CandidateEngine::new(&without_grams, None);
    let contextual = CandidateEngine::new(&with_grams, None);
    let text = "shoushixingli";
    assert!(!has(
        &base.candidates(text, CHINESE),
        "收拾行李",
        CandidateLanguage::Chinese,
        text.len()
    ));
    let ranked = contextual.candidates(text, CHINESE);
    assert_eq!(ranked[0].text, "收拾行李");
    assert!(
        ranked
            .iter()
            .filter_map(|candidate| candidate.score_bits)
            .all(f64::is_finite)
    );
    // Exact lexical homophones bypass the terminal beam.
    let direct = contextual.candidates("xingli", CHINESE);
    assert_eq!(
        direct
            .iter()
            .filter(|candidate| candidate.language == CandidateLanguage::Chinese
                && candidate.consumed_bytes == 6
                && !candidate.completion)
            .count(),
        41
    );
    Ok(())
}

#[test]
fn longer_gram_histories_refine_the_bigram_ranking() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let me = add(&mut lexicon, ZH, "wo", "我", 100);
    let want = add(&mut lexicon, ZH, "xiang", "想", 100);
    let look = add(&mut lexicon, ZH, "kan", "看", 100);
    let book = add(&mut lexicon, ZH, "shu", "书", 100);
    let tree = add(&mut lexicon, ZH, "shu", "树", 100);
    let mut grams = GramBuilder::new();
    grams.add(&[look, tree], 200).unwrap();
    grams.add(&[want, look, tree], 200).unwrap();
    grams.add(&[me, want, look, book], 2000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    assert_eq!(engine.candidates("kanshu", CHINESE)[0].text, "看树");
    assert_eq!(engine.candidates("xiangkanshu", CHINESE)[0].text, "想看树");
    assert_eq!(
        engine.candidates("woxiangkanshu", CHINESE)[0].text,
        "我想看书"
    );
    Ok(())
}

#[test]
fn constructed_output_bounds_leave_long_direct_words_and_literal_available() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let direct = "x".repeat(4100);
    let constructed = "z".repeat(4096);
    let long_input = "p".repeat(150);
    add(&mut lexicon, EN, &long_input, &direct, 1);
    add(&mut lexicon, EN, "begin", &constructed, 1);
    add(&mut lexicon, EN, "end", "end", 1);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let long = engine.candidates(&long_input, ENGLISH);
    assert!(has(
        &long,
        &direct,
        CandidateLanguage::English,
        long_input.len()
    ));
    assert_literal(long.last().unwrap(), &long_input);
    let short = engine.candidates("beginend", ENGLISH);
    assert!(has(&short, &constructed, CandidateLanguage::English, 5));
    assert!(
        short
            .iter()
            .filter(|candidate| candidate.language != CandidateLanguage::Literal)
            .all(|candidate| candidate.consumed_bytes < 8)
    );
    assert_literal(short.last().unwrap(), "beginend");
    Ok(())
}

#[test]
fn user_ingestion_counts_whole_mailboxes_and_only_the_hosts_of_web_urls() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, EN, "alpha", "alpha", 20);
    add(&mut lexicon, ZH, "yun", "云", 20);
    let base = directory.resources(&mut lexicon, None)?;
    let store = UserModelStore::new(directory.path("addresses.si-user"));
    let domain = "https://Example.test";
    let url = "https://Example.test:8443/Case%20Sensitive?q=KeepCase&lang=zh#Section";
    let other_url = "https://Example.test/Second?Token=Hidden@example.test";
    let authenticated_url = "https://AccountOnly:Password@Example.test/Docs";
    let bare = "example.test/路径?q=Value#章节";
    let mailbox = "_Reader89.Name+work@sub.example.test";
    for batch in ["first", "second"] {
        store.ingest(
            base.lexicon(),
            batch,
            [
                Ok(format!("alpha {url} 云")),
                Ok(format!("alpha {other_url} 云")),
                Ok(format!("alpha {authenticated_url} 云")),
                Ok(format!("({bare}).")),
                Ok(format!("alpha {mailbox} 云")),
            ],
        )?;
    }
    let user = store.load()?.unwrap();
    let lexicon = user.lexicon();
    let id = lexicon
        .find_reading(EN, b"https://example.test", domain)
        .unwrap();
    assert_eq!(lexicon.word(id).unwrap().count, 6);
    let mailbox_id = lexicon
        .find_reading(EN, b"_reader89.name+work@sub.example.test", mailbox)
        .unwrap();
    assert_eq!(lexicon.word(mailbox_id).unwrap().count, 2);
    assert_eq!(
        lexicon
            .word(lexicon.find_word("example.test").unwrap())
            .unwrap()
            .count,
        2
    );
    for fragment in [
        url,
        other_url,
        authenticated_url,
        bare,
        "https",
        "Case",
        "Sensitive",
        "KeepCase",
        "Section",
        "Second",
        "Token",
        "Hidden",
        "Hidden@example.test",
        "AccountOnly",
        "Password",
        "Docs",
        "路径",
        "Value",
        "章节",
        "_Reader89.Name+work",
        "Reader",
        "Name",
        "work",
        "sub.example.test",
    ] {
        assert_eq!(lexicon.find_word(fragment), None, "{fragment}");
    }
    let alpha = lexicon.find_word("alpha").unwrap();
    let cloud = lexicon.find_word("云").unwrap();
    let grams = user.grams().unwrap();
    assert_eq!(grams.count(&[alpha, id]), Some(6));
    assert_eq!(grams.count(&[id, cloud]), Some(6));
    assert_eq!(grams.count(&[alpha, id, cloud]), Some(6));
    assert_eq!(grams.count(&[alpha, mailbox_id]), Some(2));
    assert_eq!(grams.count(&[mailbox_id, cloud]), Some(2));
    assert_eq!(grams.count(&[alpha, mailbox_id, cloud]), Some(2));
    assert_eq!(grams.count(&[alpha, cloud]), None);
    Ok(())
}

#[test]
fn user_ingestion_skips_single_letters_without_bridging_grams() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, EN, "a", "a", 20);
    add(&mut lexicon, EN, "alpha", "alpha", 20);
    add(&mut lexicon, ZH, "yun", "云", 20);
    let base = directory.resources(&mut lexicon, None)?;
    let store = UserModelStore::new(directory.path("letters.si-user"));
    let existing = si_engine::resources::user::UserEntry {
        text: "I".into(),
        reading: Some((1, b"i".to_vec())),
        count: 7,
    };
    store.edit_entry(None, Some(&existing))?;
    for batch in ["first", "second"] {
        store.ingest(
            base.lexicon(),
            batch,
            [Ok(
                "alpha a Beta. alpha I Beta. alpha Z Beta. alpha Beta 云",
            )],
        )?;
    }
    let user = store.load()?.unwrap();
    assert!(user.lexicon().find_word("a").is_none());
    assert!(user.lexicon().find_word("Z").is_none());
    let saved_i = user.lexicon().find_word("I").unwrap();
    assert_eq!(user.lexicon().word(saved_i).unwrap().count, 7);
    let alpha = user.lexicon().find_word("alpha").unwrap();
    let beta = user.lexicon().find_reading(EN, b"beta", "Beta").unwrap();
    let cloud = user.lexicon().find_word("云").unwrap();
    assert_eq!(user.lexicon().word(beta).unwrap().count, 8);
    let grams = user.grams().unwrap();
    assert_eq!(grams.count(&[alpha, beta]), Some(2));
    assert_eq!(grams.count(&[beta, cloud]), Some(2));
    assert_eq!(grams.count(&[alpha, saved_i]), None);
    assert_eq!(grams.count(&[saved_i, beta]), None);
    assert_eq!(
        base.lexicon()
            .word(base.lexicon().find_word("a").unwrap())
            .unwrap()
            .count,
        20
    );
    assert!(base.lexicon().find_word("Beta").is_none());
    Ok(())
}

#[test]
fn user_unigrams_share_one_total_and_only_raise_scores() -> io::Result<()> {
    let base_dir = Scratch::new()?;
    let mut base_lexicon = Lexicon::new();
    add(&mut base_lexicon, EN, "he", "he", 1);
    add(&mut base_lexicon, EN, "and", "and", 1_000);
    add(&mut base_lexicon, ZH, "he", "和", 1);
    add(&mut base_lexicon, ZH, "yun", "云", 1_000);
    let base = base_dir.resources(&mut base_lexicon, None)?;

    let user_dir = Scratch::new()?;
    let mut user_lexicon = Lexicon::new();
    add(&mut user_lexicon, EN, "he", "he", 5);
    add(&mut user_lexicon, EN, "and", "and", 5);
    add(&mut user_lexicon, ZH, "he", "和", 10);
    add(&mut user_lexicon, ZH, "he", "河", 80);
    let user = user_dir.resources(&mut user_lexicon, None)?;

    let base_engine = CandidateEngine::new(&base, None);
    let user_engine = CandidateEngine::new(&base, Some(&user));
    let base_matches = base_engine.candidates("he", BILINGUAL);
    let user_matches = user_engine.candidates("he", BILINGUAL);
    let base_prior = 1.0_f64 / 2_002.0;
    for (text, language, count) in [
        ("he", CandidateLanguage::English, 5.0),
        ("和", CandidateLanguage::Chinese, 10.0),
    ] {
        let gain = find(&user_matches, text, language, 2).score_bits.unwrap()
            - find(&base_matches, text, language, 2).score_bits.unwrap();
        let expected_gain = (1.0 + 0.8 * (count / 100.0 / base_prior - 1.0) * 100.0 / 132.0).log2();
        assert!((gain - expected_gain).abs() < 1e-12);
    }
    for (source, text, language) in [
        ("and", "and", CandidateLanguage::English),
        ("yun", "云", CandidateLanguage::Chinese),
    ] {
        let baseline = base_engine.candidates(source, BILINGUAL);
        let personalized = user_engine.candidates(source, BILINGUAL);
        assert_eq!(
            find(&personalized, text, language, source.len()).score_bits,
            find(&baseline, text, language, source.len()).score_bits,
        );
    }
    Ok(())
}

#[test]
fn user_grams_only_raise_scores_within_compositions_and_after_preceding_text() -> io::Result<()> {
    let base_dir = Scratch::new()?;
    let mut base_lexicon = Lexicon::new();
    let look = add(&mut base_lexicon, ZH, "kan", "看", 100);
    let book = add(&mut base_lexicon, ZH, "shu", "书", 100);
    let cloud = add(&mut base_lexicon, ZH, "yun", "云", 100);
    add(&mut base_lexicon, EN, "paper", "paper", 100);
    let mut base_grams = GramBuilder::new();
    base_grams.add(&[look, book], 90).unwrap();
    base_grams.add(&[look, cloud], 10).unwrap();
    let base = base_dir.resources(&mut base_lexicon, Some(base_grams))?;

    let user_dir = Scratch::new()?;
    let mut user_lexicon = Lexicon::new();
    let look = add(&mut user_lexicon, ZH, "kan", "看", 100);
    let book = add(&mut user_lexicon, ZH, "shu", "书", 100);
    add(&mut user_lexicon, ZH, "yun", "云", 100);
    let paper = add(&mut user_lexicon, EN, "paper", "paper", 100);
    let mut user_grams = GramBuilder::new();
    user_grams.add(&[look, book], 1).unwrap();
    user_grams.add(&[look, paper], 9).unwrap();
    let user = user_dir.resources(&mut user_lexicon, Some(user_grams))?;
    let lexicon_only = EngineResources::open(&user_dir.path("base.silex"), None)?;
    let unigrams = CandidateEngine::new(&base, Some(&lexicon_only));
    let grams = CandidateEngine::new(&base, Some(&user));

    for (source, context, text, language, boosted) in [
        ("kanshu", "", "看书", CandidateLanguage::Chinese, false),
        ("kanyun", "", "看云", CandidateLanguage::Chinese, false),
        ("kanpaper", "", "看 paper", CandidateLanguage::Mixed, true),
        ("shu", "看", "书", CandidateLanguage::Chinese, false),
        ("yun", "看", "云", CandidateLanguage::Chinese, false),
        ("paper", "看", "paper", CandidateLanguage::English, true),
    ] {
        let score = |engine: &CandidateEngine<'_>| {
            let rows = engine.convert_with_context(
                source,
                BILINGUAL,
                false,
                &[],
                ConversionPreferences::default(),
                context,
            );
            let row = find(&rows, text, language, source.len());
            row.score_bits.unwrap() + row.context_adjustment
        };
        if boosted {
            assert!(score(&grams) > score(&unigrams), "{source}");
        } else {
            assert_eq!(score(&grams), score(&unigrams), "{source}");
        }
    }
    Ok(())
}

#[test]
fn terminal_completion_keeps_base_and_user_gram_winners() -> io::Result<()> {
    let base_dir = Scratch::new()?;
    let mut base_lexicon = Lexicon::new();
    let go = add(&mut base_lexicon, EN, "go", "go", 100);
    for letter in b'a'..=b'z' {
        let word = format!("sa{}", char::from(letter));
        add(&mut base_lexicon, EN, &word, &word, 100);
    }
    let star = add(&mut base_lexicon, EN, "star", "star", 1);
    let mut base_grams = GramBuilder::new();
    base_grams.add(&[go, star], 1_000).unwrap();
    let base = base_dir.resources(&mut base_lexicon, Some(base_grams))?;

    let user_dir = Scratch::new()?;
    let mut user_lexicon = Lexicon::new();
    let go = add(&mut user_lexicon, EN, "go", "go", 1_000);
    let swift = add(&mut user_lexicon, EN, "swift", "swift", 1);
    let mut user_grams = GramBuilder::new();
    user_grams.add(&[go, swift], 1_000).unwrap();
    let user = user_dir.resources(&mut user_lexicon, Some(user_grams))?;
    let user_without_grams = EngineResources::open(&user_dir.path("base.silex"), None)?;

    assert!(!has(
        &CandidateEngine::new(&base, Some(&user_without_grams)).candidates("gos", ENGLISH),
        "go swift",
        CandidateLanguage::English,
        3
    ));
    let engine = CandidateEngine::new(&base, Some(&user));
    for preview in [false, true] {
        let rows = engine.convert(
            "gos",
            ENGLISH,
            preview,
            &[],
            ConversionPreferences::default(),
        );
        for text in ["go star", "go swift"] {
            assert!(find(&rows, text, CandidateLanguage::English, 3).completion);
        }
    }
    Ok(())
}

#[test]
fn user_only_preceding_word_preserves_base_context_evidence() -> io::Result<()> {
    let base_dir = Scratch::new()?;
    let mut base_lexicon = Lexicon::new();
    add(&mut base_lexicon, ZH, "kan", "看", 10);
    let book = add(&mut base_lexicon, ZH, "shu", "书", 10);
    let good = add(&mut base_lexicon, ZH, "hao", "好", 10);
    add(&mut base_lexicon, ZH, "huai", "坏", 10);
    let mut base_grams = GramBuilder::new();
    base_grams.add(&[book, good], 1_000).unwrap();
    let base = base_dir.resources(&mut base_lexicon, Some(base_grams))?;

    let user_dir = Scratch::new()?;
    let mut user_lexicon = Lexicon::new();
    let reading = add(&mut user_lexicon, ZH, "kan'shu", "看书", 12);
    let bad = add(&mut user_lexicon, ZH, "huai", "坏", 12);
    let mut user_grams = GramBuilder::new();
    user_grams.add(&[reading, bad], 8).unwrap();
    let user = user_dir.resources(&mut user_lexicon, Some(user_grams))?;

    let adjustment = |engine: &CandidateEngine<'_>, source, text| {
        let rows = engine.convert_with_context(
            source,
            CHINESE,
            false,
            &[],
            ConversionPreferences::default(),
            "看书",
        );
        find(&rows, text, CandidateLanguage::Chinese, source.len()).context_adjustment
    };
    let base_engine = CandidateEngine::new(&base, None);
    let user_engine = CandidateEngine::new(&base, Some(&user));
    let base_good = adjustment(&base_engine, "hao", "好");
    assert!(base_good > 0.0);
    assert_eq!(adjustment(&user_engine, "hao", "好"), base_good);
    assert!(adjustment(&user_engine, "huai", "坏") > 0.0);
    Ok(())
}

#[test]
fn user_word_and_gram_evidence_follow_lexeme_identity_across_files() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let ornament = add(&mut lexicon, ZH, "shou'shi", "首饰", 200);
    let luggage = add(&mut lexicon, ZH, "xing'li", "行李", 80);
    let pick_up = add(&mut lexicon, ZH, "shou'shi", "收拾", 5);
    let counter = add(&mut lexicon, ZH, "gui'tai", "柜台", 80);
    add(&mut lexicon, ZH, "yun", "云", 10);
    add(&mut lexicon, ZH, "he", "鹤", 10);
    add(&mut lexicon, ZH, "bai'cha", "白茶", 50);
    let mut grams = GramBuilder::new();
    grams.add(&[ornament, luggage], 300).unwrap();
    grams.add(&[ornament, counter], 1_200).unwrap();
    let base = directory.resources(&mut lexicon, Some(grams))?;
    let user_store = UserModelStore::new(directory.path("user.si-user"));
    user_store.ingest(
        base.lexicon(),
        "observations",
        (0..50).flat_map(|_| [Ok("收拾行李"), Ok("首饰柜台")]),
    )?;
    user_store.ingest(
        base.lexicon(),
        "names",
        (0..8).flat_map(|_| [Ok("云鹤"), Ok("白茶")]),
    )?;
    let user = user_store.load()?.unwrap();
    let user_pick_up = user.lexicon().find_word("收拾").unwrap();
    let user_luggage = user.lexicon().find_word("行李").unwrap();
    assert_ne!(user_pick_up, pick_up);
    assert_eq!(
        user.grams().unwrap().count(&[user_pick_up, user_luggage]),
        Some(50)
    );

    let base_engine = CandidateEngine::new(&base, None);
    let user_engine = CandidateEngine::new(&base, Some(&user));
    assert_eq!(
        base_engine.candidates("shoushixingli", CHINESE)[0].text,
        "首饰行李"
    );
    let results = user_engine.candidates("shoushixingli", CHINESE);
    assert_eq!(results[0].text, "收拾行李");
    assert!(has(&results, "首饰行李", CandidateLanguage::Chinese, 13));
    let alternate_store = UserModelStore::new(directory.path("alternate.si-user"));
    alternate_store.ingest(
        base.lexicon(),
        "observations",
        (0..50).flat_map(|_| [Ok("收拾柜台"), Ok("首饰行李")]),
    )?;
    alternate_store.ingest(
        base.lexicon(),
        "names",
        (0..8).flat_map(|_| [Ok("云鹤"), Ok("白茶")]),
    )?;
    let alternate = alternate_store.load()?.unwrap();
    for word in user.lexicon().words() {
        let alternate_id = alternate.lexicon().find_word(word.text).unwrap();
        assert_eq!(
            word.count,
            alternate.lexicon().word(alternate_id).unwrap().count
        );
    }
    let alternate_engine = CandidateEngine::new(&base, Some(&alternate));
    assert_eq!(
        alternate_engine.candidates("shoushixingli", CHINESE)[0].text,
        "首饰行李"
    );

    assert!(
        user_store
            .learn(base.lexicon(), &UserLearningConfig::default())?
            .added_words
            > 0
    );
    let learned = user_store.load()?.unwrap();
    assert!(learned.lexicon().find_word("云鹤").is_some());
    let learned_engine = CandidateEngine::new(&base, Some(&learned));
    let before = user_engine.candidates("yunhe", CHINESE);
    let after = learned_engine.candidates("yunhe", CHINESE);
    assert!(
        find(&after, "云鹤", CandidateLanguage::Chinese, 5).score_bits
            > find(&before, "云鹤", CandidateLanguage::Chinese, 5).score_bits
    );
    Ok(())
}

#[test]
fn fivegram_evidence_can_change_candidate_order() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let words = [
        ("jin", "今"),
        ("tian", "天"),
        ("wo", "我"),
        ("he", "喝"),
        ("cha", "茶"),
    ]
    .map(|(reading, text)| add(&mut lexicon, ZH, reading, text, 10));
    add(&mut lexicon, ZH, "cha", "查", 100);
    let mut grams = GramBuilder::new();
    grams.add(&words, 1000).unwrap();
    let contextual = directory.resources(&mut lexicon, Some(grams))?;
    let plain = EngineResources::open(&directory.path("base.silex"), None)?;
    let spelling = "jintianwohecha";
    assert_eq!(
        CandidateEngine::new(&plain, None).candidates(spelling, CHINESE)[0].text,
        "今天我喝查"
    );
    assert_eq!(
        CandidateEngine::new(&contextual, None).candidates(spelling, CHINESE)[0].text,
        "今天我喝茶"
    );
    assert_eq!(
        CandidateEngine::new(&plain, Some(&contextual)).candidates(spelling, CHINESE)[0].text,
        "今天我喝茶"
    );
    Ok(())
}

fn add(lexicon: &mut Lexicon, index: IndexId, reading: &str, text: &str, count: u64) -> WordId {
    lexicon
        .add_reading(index, reading.as_bytes(), text, count)
        .unwrap()
}

fn has(candidates: &[Candidate], text: &str, language: CandidateLanguage, bytes: usize) -> bool {
    candidates.iter().any(|candidate| {
        candidate.text == text
            && candidate.language == language
            && candidate.consumed_bytes == bytes
    })
}

fn find<'a>(
    candidates: &'a [Candidate],
    text: &str,
    language: CandidateLanguage,
    bytes: usize,
) -> &'a Candidate {
    candidates
        .iter()
        .find(|candidate| {
            candidate.text == text
                && candidate.language == language
                && candidate.consumed_bytes == bytes
        })
        .unwrap_or_else(|| panic!("missing {text:?} at {bytes} bytes"))
}

fn assert_literal(candidate: &Candidate, text: &str) {
    assert_eq!(candidate.text, text);
    assert_eq!(candidate.consumed_bytes, text.len());
    assert_eq!(candidate.language, CandidateLanguage::Literal);
    assert_eq!(candidate.score_bits, None);
}

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> io::Result<Self> {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        loop {
            let next = NEXT.fetch_add(1, Ordering::Relaxed);
            let directory =
                std::env::temp_dir().join(format!("si-conversion-{}-{next}", std::process::id()));
            match fs::create_dir(&directory) {
                Ok(()) => return Ok(Self(directory)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
    }

    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }

    fn resources(
        &self,
        lexicon: &mut Lexicon,
        grams: Option<GramBuilder>,
    ) -> io::Result<EngineResources> {
        let path = self.path("base.silex");
        lexicon.save(&path)?;
        let model_path = grams
            .map(|grams| {
                let mut model = grams.finish().map_err(io::Error::other)?;
                model.bind_lexicon(lexicon)?;
                let output = self.path("base.sigram");
                model.save(&output)?;
                Ok::<PathBuf, io::Error>(output)
            })
            .transpose()?;
        EngineResources::open(&path, model_path.as_deref())
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn field_context_uses_the_complete_frequency_segmentation() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "mei'you", "没有", 78_908_345);
    add(&mut lexicon, ZH, "mei'you'shu", "没有输", 155);
    let ime = add(&mut lexicon, ZH, "shu'ru'fa", "输入法", 472_646);
    add(&mut lexicon, ZH, "ru", "入", 1_746_243);
    add(&mut lexicon, ZH, "fa", "法", 2_191_827);
    let good = add(&mut lexicon, ZH, "hao", "好", 100);
    add(&mut lexicon, ZH, "hao", "豪", 200);
    let mut grams = GramBuilder::new();
    grams.add(&[ime, good], 1_000).unwrap();
    let base = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&base, None);
    let convert = |context| {
        engine.convert_with_context(
            "hao",
            CHINESE,
            false,
            &[],
            ConversionPreferences::default(),
            context,
        )
    };
    let actual = convert("没有输入法");
    assert_eq!(actual, convert("输入法"));
    assert!(find(&actual, "好", CandidateLanguage::Chinese, 3).context_adjustment > 0.0);
    assert_ne!(actual, convert("入法"));
    Ok(())
}

#[test]
fn correction_rejects_suggestions_below_the_exact_path_floor() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "hou'mo", "后模", 1_000);
    add(&mut lexicon, ZH, "zhou'mo", "周末", 1_000);
    add(&mut lexicon, EN, "houmo", "houmo", 1_000);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    let spelling = "houmo";
    for languages in [CHINESE, BILINGUAL] {
        let matches = engine.candidates(spelling, languages);
        assert!(matches.iter().all(|row| !row.is_corrected()));
        assert!(has(
            &matches,
            "后模",
            CandidateLanguage::Chinese,
            spelling.len()
        ));
    }
    Ok(())
}

#[test]
fn pinyin_correction_ranks_with_completions_and_exact_candidates() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "zhou'mo", "周末", 2_600);
    add(&mut lexicon, ZH, "hou'mo", "后模", 1);
    add(&mut lexicon, ZH, "hou'mo'ju", "后模具", 16);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);

    let input = "houmo";
    let rows = engine.candidates(input, CHINESE);
    assert_eq!(rows[0].text, "周末");
    assert!(rows[0].is_corrected());
    let completion = find(&rows, "后模具", CandidateLanguage::Chinese, input.len());
    assert!(completion.completion);
    let exact = find(&rows, "后模", CandidateLanguage::Chinese, input.len());
    assert!(!exact.is_corrected() && !exact.completion);
    assert_eq!(
        Candidate::default_for_whole_input(&rows, input.len()),
        rows.iter()
            .find(|row| row.text == "后模" || row.text == "后模具")
    );
    Ok(())
}

#[test]
fn pinyin_correction_preserves_exact_results_and_original_spans() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni", "你", 100);
    add(&mut lexicon, ZH, "hao", "好", 100);
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    add(&mut lexicon, ZH, "o", "哦", 1);
    add(&mut lexicon, ZH, "lv'se", "绿色", 100);
    add(&mut lexicon, ZH, "biao", "表", 100);
    add(&mut lexicon, ZH, "zhou'mo", "周末", 2_600);
    add(&mut lexicon, ZH, "hou'mo", "后模", 1);
    add(&mut lexicon, ZH, "sui'bian", "随便", 200);
    add(&mut lexicon, ZH, "yi'bian", "一遍", 100);
    add(&mut lexicon, ZH, "shi'jie", "世界", 100);
    add(&mut lexicon, EN, "nihoa", "nihoa", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let baseline = CandidateEngine::new(&resources, None);
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    for preview in [false, true] {
        for (input, expected) in [
            ("niao", "你好"),
            ("nohao", "你好"),
            ("njhao", "你好"),
            ("houmo", "周末"),
            ("nihoa", "你好"),
            ("ni'hoa", "你好"),
            ("lv'es", "绿色"),
            ("lü'es", "绿色"),
            ("lu:'es", "绿色"),
            ("lu\u{308}'es", "绿色"),
            ("nihaoshijei", "你好世界"),
            ("niha'shijie", "你好世界"),
            (
                "nihaonihaonihaonihaonihaoshijei",
                "你好你好你好你好你好世界",
            ),
        ] {
            let convert = |engine: &CandidateEngine<'_>| {
                engine.convert(
                    input,
                    CHINESE,
                    preview,
                    &[],
                    ConversionPreferences::default(),
                )
            };
            let rows = convert(&engine);
            let corrected = find(&rows, expected, CandidateLanguage::Chinese, input.len());
            assert!(corrected.is_corrected(), "{input}");
            assert!(!corrected.completion);
            assert!(corrected.confirmation_boundaries.is_empty());
            assert_eq!(corrected.source_boundaries.last(), Some(&input.len()));
            assert!(
                corrected
                    .source_boundaries
                    .iter()
                    .all(|&offset| input.is_char_boundary(offset))
            );
            assert_eq!(
                rows.into_iter()
                    .filter(|candidate| !candidate.is_corrected())
                    .collect::<Vec<_>>(),
                convert(&baseline),
                "{input}",
            );
        }
    }
    assert!(
        engine
            .candidates("nihao'x", CHINESE)
            .iter()
            .all(|row| { !row.is_corrected() || row.text != "你好" })
    );
    for input in ["nihoa'shij", "nihoa'shi'j'e"] {
        let rows = engine.candidates(input, CHINESE);
        assert!(rows.iter().all(|row| !row.is_corrected()), "{input}");
        assert_eq!(rows, baseline.candidates(input, CHINESE));
    }
    let competing = engine.candidates("syibian", CHINESE);
    let strongest = competing.iter().find(|row| row.is_corrected()).unwrap();
    assert_eq!(strongest.text, "随便");
    for input in ["büiao", "bu:iao", "bu\u{308}iao"] {
        assert!(
            engine
                .candidates(input, CHINESE)
                .iter()
                .all(|row| { !row.is_corrected() || row.text != "表" })
        );
    }
    let clean = engine.candidates("nihao", BILINGUAL);
    assert!(clean.iter().all(|row| !row.is_corrected()));
    assert_eq!(
        clean.first(),
        baseline.candidates("nihao", BILINGUAL).first()
    );
    for input in ["NiHao", "ni_hao", "nih'oa", "nohoa", "nihoa"] {
        assert!(
            !engine
                .candidates(input, BILINGUAL)
                .iter()
                .any(|row| row.is_corrected()),
            "{input}"
        );
    }
    assert_eq!(
        engine.candidates("nihoa", ENGLISH),
        baseline.candidates("nihoa", ENGLISH)
    );
    Ok(())
}

#[test]
fn pinyin_correction_uses_context_without_changing_ordinary_results() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let say = add(&mut lexicon, ZH, "shuo", "说", 100);
    let emotion = add(&mut lexicon, ZH, "gan'qing", "感情", 100);
    let hello = add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    let greeting = add(&mut lexicon, ZH, "ni'hao", "拟好", 10);
    let mut grams = GramBuilder::new();
    grams.add(&[say, hello], 10_000).unwrap();
    grams.add(&[emotion, greeting], 10_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let baseline = CandidateEngine::new(&resources, None);
    let enabled = CandidateEngine::new(&resources, None).with_pinyin_correction(true);

    for preview in [false, true] {
        for (preceding_text, expected) in [("说", "你好"), ("说。感情", "拟好"), ("", "你好")]
        {
            let convert = |engine: &CandidateEngine<'_>| {
                engine.convert_with_context(
                    "nihoa",
                    BILINGUAL,
                    preview,
                    &[],
                    ConversionPreferences::default(),
                    preceding_text,
                )
            };
            let rows = convert(&enabled);
            let best = rows.iter().find(|row| row.is_corrected()).unwrap();
            assert_eq!(best.text, expected);
            assert_eq!(best.consumed_bytes, 5);
            assert!(best.confirmation_boundaries.is_empty());
            assert_eq!(
                rows.into_iter()
                    .filter(|row| !row.is_corrected())
                    .collect::<Vec<_>>(),
                convert(&baseline),
            );
        }
    }
    Ok(())
}

#[test]
fn pinyin_correction_considers_frequent_entries_in_dense_spelling_groups() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for codepoint in 0x4e00..0x4e90 {
        let word = format!("{}好", char::from_u32(codepoint).unwrap());
        add(&mut lexicon, ZH, "ni'hao", &word, 1);
    }
    add(&mut lexicon, ZH, "ni'hao", "你好", 10_000);
    let resources = directory.resources(&mut lexicon, None)?;
    let ordinary = CandidateEngine::new(&resources, None);
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    assert_eq!(
        engine.candidates("nihao", CHINESE),
        ordinary.candidates("nihao", CHINESE)
    );
    let rows = engine.candidates("nihoa", CHINESE);
    let best = rows.iter().find(|row| row.is_corrected()).unwrap();
    assert_eq!(best.text, "你好");
    Ok(())
}

#[test]
fn dense_pinyin_correction_keeps_frequent_paired_user_words() -> io::Result<()> {
    let directory = Scratch::new()?;
    let user_directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for codepoint in 0x4e00..0x4e90 {
        let word = format!("{}好", char::from_u32(codepoint).unwrap());
        add(&mut lexicon, ZH, "ni'hao", &word, 50);
    }
    add(&mut lexicon, ZH, "ni'hao", "你好", 1);
    let resources = directory.resources(&mut lexicon, None)?;
    let mut user_lexicon = Lexicon::new();
    add(&mut user_lexicon, ZH, "ni'hao", "你好", 10_000);
    let user = user_directory.resources(&mut user_lexicon, None)?;
    let engine = CandidateEngine::new(&resources, Some(&user)).with_pinyin_correction(true);
    let baseline = CandidateEngine::new(&resources, Some(&user));
    let rows = engine.candidates("nihoa", CHINESE);
    let best = rows.iter().find(|row| row.is_corrected()).unwrap();
    assert_eq!(best.text, "你好");
    assert!(
        baseline
            .candidates("nihoa", CHINESE)
            .iter()
            .eq(rows.iter().filter(|row| !row.is_corrected()))
    );
    Ok(())
}

#[test]
fn pinyin_correction_respects_an_exact_personal_code() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    let baseline = CandidateEngine::new(&resources, None);
    for preview in [false, true] {
        for pinned in [false, true] {
            let phrase = PersonalPhrase {
                spelling: "nihoa",
                text: "自定义",
                language: CandidateLanguage::Chinese,
                pinned,
            };
            let convert = |engine: &CandidateEngine<'_>, phrases: &[PersonalPhrase<'_>]| {
                engine.convert(
                    "nihoa",
                    CHINESE,
                    preview,
                    phrases,
                    ConversionPreferences::default(),
                )
            };
            assert!(convert(&engine, &[]).iter().any(|row| row.is_corrected()));
            let rows = convert(&engine, std::slice::from_ref(&phrase));
            assert_eq!(rows, convert(&baseline, std::slice::from_ref(&phrase)));
            assert!(find(&rows, "自定义", CandidateLanguage::Chinese, 5).personal);
            assert!(rows.iter().all(|row| !row.is_corrected()));

            let prefix = PersonalPhrase {
                spelling: "ni",
                ..phrase
            };
            assert!(
                convert(&engine, &[prefix])
                    .iter()
                    .any(|row| row.is_corrected())
            );
        }
    }
    Ok(())
}

#[test]
fn pinyin_correction_rejects_a_marginal_lead_over_an_exact_word() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "duo'jiu", "多久", 600);
    add(&mut lexicon, ZH, "duo'ju", "多聚", 1);
    add(&mut lexicon, ZH, "zhuang'tai", "状态", 900);
    add(&mut lexicon, ZH, "huang'tai", "黄台", 1);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    for (spelling, expected) in [("duoju", "多聚"), ("huangtai", "黄台")] {
        for rows in [
            engine.preview(spelling, CHINESE),
            engine.candidates(spelling, CHINESE),
        ] {
            assert_eq!(rows[0].text, expected);
            assert!(rows.iter().all(|candidate| !candidate.is_corrected()));
            assert_eq!(rows.last().unwrap().text, spelling);
        }
    }
    let higher_recall =
        engine.with_correction_sensitivity(Some(si_engine::CorrectionSensitivity::HigherRecall));
    let rows = higher_recall.candidates("duoju", CHINESE);
    assert_eq!(rows[0].text, "多久");
    assert!(rows[0].is_corrected());
    assert_eq!(rows[1].text, "多聚");
    assert!(!rows[1].is_corrected());
    assert_literal(rows.last().unwrap(), "duoju");
    Ok(())
}

#[test]
fn pinyin_correction_respects_a_strong_complete_english_path() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ou'pen'ai", "欧喷爱", 1);
    add(&mut lexicon, EN, "open", "open", 100);
    add(&mut lexicon, EN, "ai", "AI", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    for preview in [false, true] {
        let convert = |languages| {
            engine.convert(
                "openai",
                languages,
                preview,
                &[],
                ConversionPreferences::default(),
            )
        };
        let bilingual = convert(BILINGUAL);
        assert!(bilingual.iter().all(|row| !row.is_corrected()));
        assert_eq!(bilingual[0].text, "open AI");
        assert_eq!(bilingual.last().unwrap().text, "openai");
        assert!(
            convert(CHINESE)
                .iter()
                .any(|row| row.is_corrected() && row.text == "欧喷爱")
        );
    }
    Ok(())
}

#[test]
fn pinyin_correction_bounds_output_without_limiting_exact_words() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let oversized = "汉".repeat(1_366);
    let at_limit = format!("{}x", "字".repeat(1_365));
    add(&mut lexicon, ZH, "ni'hao", &oversized, 1000);
    for suffix in 0..130 {
        let over_limit = format!("{oversized}{suffix}");
        add(&mut lexicon, ZH, "ni'hao", &over_limit, 1_000);
    }
    add(&mut lexicon, ZH, "shi'jie", &oversized, 1_000);
    add(&mut lexicon, ZH, "ni'hao", &at_limit, 100);
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);

    let sparse = engine.candidates("shijei", CHINESE);
    assert!(
        sparse
            .iter()
            .all(|row| !row.is_corrected() || row.text != oversized)
    );
    let exact = engine.candidates("nihao", CHINESE);
    assert!(
        exact
            .iter()
            .any(|row| row.text == oversized && !row.is_corrected())
    );
    for candidates in [
        engine.preview("nihoa", CHINESE),
        engine.candidates("nihoa", CHINESE),
    ] {
        assert!(
            candidates
                .iter()
                .all(|row| !row.is_corrected() || row.text != oversized)
        );
        assert!(
            candidates
                .iter()
                .any(|row| row.text == at_limit && row.is_corrected())
        );
        assert!(
            candidates
                .iter()
                .any(|row| row.text == "你好" && row.is_corrected())
        );
        assert_eq!(candidates.last().unwrap().text, "nihoa");
    }
    Ok(())
}

#[test]
fn pinyin_abbreviation_does_not_count_as_an_exact_spelling_for_correction() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "xiang'an", "香案", 100);
    add(&mut lexicon, ZH, "xiang'ni", "想你", 10_000);
    let resources = directory.resources(&mut lexicon, None)?;
    let baseline = CandidateEngine::new(&resources, None);
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    let rows = engine.candidates("xiangn", CHINESE);
    let best = rows.iter().find(|row| row.is_corrected()).unwrap();
    assert_eq!(best.text, "香案");
    assert!(
        baseline
            .candidates("xiangn", CHINESE)
            .iter()
            .eq(rows.iter().filter(|row| !row.is_corrected()))
    );
    Ok(())
}

#[test]
fn opt_in_pinyin_correction_keeps_ordinary_candidates_for_generated_edits() -> io::Result<()> {
    use std::collections::BTreeSet;

    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let words = [("ni'hao", "你好"), ("shi'jie", "世界"), ("xi'tong", "系统")];
    for (reading, text) in words {
        add(&mut lexicon, ZH, reading, text, 100);
    }
    add(&mut lexicon, EN, "hello", "hello", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let ordinary = CandidateEngine::new(&resources, None);
    let correction = CandidateEngine::new(&resources, None).with_pinyin_correction(true);

    let mut inputs = BTreeSet::from([
        String::new(),
        "Hello".to_owned(),
        "ni__hao".to_owned(),
        "nihao🙂".to_owned(),
        "nihao".repeat(26),
    ]);
    for (reading, _) in words {
        let spelling = reading.replace('\'', "");
        inputs.insert(spelling.clone());
        for index in 0..spelling.len() {
            let mut extra = spelling.clone();
            extra.insert(index, spelling.as_bytes()[index] as char);
            inputs.insert(extra);
            let mut missing = spelling.clone();
            missing.remove(index);
            inputs.insert(missing);
            if index + 1 < spelling.len() {
                let mut swapped = spelling.as_bytes().to_vec();
                swapped.swap(index, index + 1);
                inputs.insert(String::from_utf8(swapped.clone()).unwrap());
                swapped[index] = b'z';
                inputs.insert(String::from_utf8(swapped).unwrap());
            }
        }
    }
    let readings = [("你好", "nihao"), ("世界", "shijie"), ("系统", "xitong")];
    for input in inputs {
        for preview in [false, true] {
            let convert = |engine: &CandidateEngine<'_>| {
                engine.convert(
                    &input,
                    BILINGUAL,
                    preview,
                    &[],
                    ConversionPreferences::default(),
                )
            };
            let expected = convert(&ordinary);
            let actual = convert(&correction);
            assert!(
                expected
                    .iter()
                    .eq(actual.iter().filter(|row| !row.is_corrected())),
                "{input}"
            );
            assert_eq!(convert(&correction), actual, "{input}");
            let suggestions: Vec<_> = actual.iter().filter(|row| row.is_corrected()).collect();
            assert!(suggestions.len() <= 4, "{input}");
            for row in suggestions {
                assert_eq!(row.consumed_bytes, input.len(), "{input}");
                assert!(row.confirmation_boundaries.is_empty(), "{input}");
                let (_, reading) = readings.iter().find(|(text, _)| *text == row.text).unwrap();
                assert!(
                    one_key_edit(input.as_bytes(), reading.as_bytes()),
                    "{input} → {reading}"
                );
            }
        }
    }
    Ok(())
}

fn one_key_edit(typed: &[u8], reading: &[u8]) -> bool {
    if typed.len() == reading.len() {
        let changed: Vec<_> = typed
            .iter()
            .zip(reading)
            .enumerate()
            .filter_map(|(index, (left, right))| (left != right).then_some(index))
            .collect();
        return match changed.as_slice() {
            [_] => true,
            &[left, right] if right == left + 1 => {
                typed[left] == reading[right] && typed[right] == reading[left]
            }
            _ => false,
        };
    }
    reading.len() == typed.len() + 1
        && (0..reading.len()).any(|index| {
            reading[..index]
                .iter()
                .chain(&reading[index + 1..])
                .eq(typed)
        })
}

#[test]
fn dense_correction_retains_a_reading_matching_explicit_boundaries() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for codepoint in 0x4e00..0x4e90 {
        let word = char::from_u32(codepoint).unwrap().to_string();
        add(&mut lexicon, ZH, "xian", &word, 100);
    }
    add(&mut lexicon, ZH, "xi'an", "西安", 1);
    let resources = directory.resources(&mut lexicon, None)?;
    let enabled = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    let rows = enabled.candidates("xi'na", CHINESE);
    assert!(find(&rows, "西安", CandidateLanguage::Chinese, 5).is_corrected());
    assert_literal(rows.last().unwrap(), "xi'na");

    let disabled = enabled.with_pinyin_correction(false);
    assert!(
        disabled
            .candidates("xi'na", CHINESE)
            .iter()
            .all(|row| !row.is_corrected())
    );
    let reenabled = disabled.with_pinyin_correction(true);
    assert_eq!(reenabled.candidates("xi'na", CHINESE), rows);
    Ok(())
}

#[test]
fn pinyin_correction_requires_strong_context_to_challenge_a_valid_spelling() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let want = add(&mut lexicon, ZH, "xiang", "想", 100);
    let find_name = add(&mut lexicon, ZH, "zhao", "找", 100);
    let target = add(&mut lexicon, ZH, "gao'su", "告诉", 100);
    let literal_reading = add(&mut lexicon, ZH, "gao'xu", "高旭", 100);
    add(&mut lexicon, ZH, "zhi'dao", "知道", 2_000_000);
    let mut grams = GramBuilder::new();
    grams.add(&[want, target], 100_000).unwrap();
    grams.add(&[find_name, literal_reading], 100_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let ordinary = CandidateEngine::new(&resources, None);
    let correction = CandidateEngine::new(&resources, None).with_pinyin_correction(true);

    for preview in [false, true] {
        for (context, should_suggest) in [("", false), ("想。找", false), ("找。想", true)] {
            let convert = |engine: &CandidateEngine<'_>| {
                engine.convert_with_context(
                    "gaoxu",
                    CHINESE,
                    preview,
                    &[],
                    ConversionPreferences::default(),
                    context,
                )
            };
            let rows = convert(&correction);
            assert_eq!(rows[0].text, if should_suggest { "告诉" } else { "高旭" });
            assert!(
                convert(&ordinary)
                    .iter()
                    .eq(rows.iter().filter(|row| !row.is_corrected()))
            );
            let suggested = rows
                .iter()
                .find(|row| row.text == "告诉" && row.is_corrected());
            assert_eq!(suggested.is_some(), should_suggest, "{context:?}");
            assert_literal(rows.last().unwrap(), "gaoxu");
        }
    }
    Ok(())
}

#[test]
fn pinyin_correction_finds_a_long_dictionary_entry_with_one_typo() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(
        &mut lexicon,
        ZH,
        "long'zhou'dong'xia'shi'cheng'kong",
        "龙舟东下事成空",
        100,
    );
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    let mistyped = "longzhoudongxiasihchengkong";
    for rows in [
        engine.preview(mistyped, CHINESE),
        engine.candidates(mistyped, CHINESE),
    ] {
        assert!(
            find(
                &rows,
                "龙舟东下事成空",
                CandidateLanguage::Chinese,
                mistyped.len()
            )
            .is_corrected()
        );
        assert_literal(rows.last().unwrap(), mistyped);
    }
    Ok(())
}

#[test]
fn pinyin_correction_can_restore_a_key_at_the_long_window_limit() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let reading = format!("{}hong", "zhang'".repeat(9));
    let exact = reading.replace('\'', "");
    let output = "章".repeat(9) + "红";
    assert_eq!(exact.len(), 49);
    add(&mut lexicon, ZH, &reading, &output, 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);

    for lost_key in [0, exact.len() - 2] {
        let mut spelling = exact.clone();
        spelling.remove(lost_key);
        let rows = engine.candidates(&spelling, CHINESE);
        let suggestion = find(&rows, &output, CandidateLanguage::Chinese, 48);
        assert!(suggestion.is_corrected());
        assert!(suggestion.confirmation_boundaries.is_empty());
        assert_literal(rows.last().unwrap(), &spelling);
    }
    Ok(())
}

#[test]
fn pinyin_correction_preview_keeps_contextually_strong_continuations() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni'hao", "你好", 300);
    add(&mut lexicon, ZH, "ni'hao", "你号", 200);
    let prepare = add(&mut lexicon, ZH, "ni'hao", "拟好", 100);
    let world = add(&mut lexicon, ZH, "shi'jie", "世界", 1);
    add(&mut lexicon, ZH, "chang'jian", "常见", 100_000);
    let mut grams = GramBuilder::new();
    grams.add(&[prepare, world], 100_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);

    for rows in [
        engine.candidates("nihoashijie", CHINESE),
        engine.preview("nihoashijie", CHINESE),
    ] {
        let suggestion = rows.iter().find(|row| row.is_corrected()).unwrap();
        assert_eq!(suggestion.text, "拟好世界");
        assert_literal(rows.last().unwrap(), "nihoashijie");
    }
    Ok(())
}

#[test]
fn pinyin_correction_keeps_a_late_edit_at_the_composition_limit() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    add(&mut lexicon, ZH, "shi", "是", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let baseline = CandidateEngine::new(&resources, None);
    let enabled = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    let source = "nihao".repeat(24) + "nihoashi";
    let expected = "你好".repeat(25) + "是";
    assert_eq!(source.len(), 128);

    let rows = enabled.preview(&source, CHINESE);
    let best = rows.iter().find(|row| row.is_corrected()).unwrap();
    assert_eq!(best.text, expected);
    assert_eq!(best.consumed_bytes, source.len());
    let ordinary = baseline.preview(&source, CHINESE);
    assert!(
        ordinary
            .iter()
            .eq(rows.iter().filter(|row| !row.is_corrected()))
    );
    assert_literal(rows.last().unwrap(), &source);
    Ok(())
}

#[test]
fn pinyin_correction_does_not_apply_exact_spelling_preferences() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    add(&mut lexicon, ZH, "shi'jie", "世界", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    let input = "nihaoshijei";
    let output = "你好世界";
    let tokens = [
        si_engine::TokenPreference {
            spelling: "nihao",
            text: "你好",
            language: CandidateLanguage::Chinese,
            bonus: 32.0,
        },
        si_engine::TokenPreference {
            spelling: "shijei",
            text: "世界",
            language: CandidateLanguage::Chinese,
            bonus: 32.0,
        },
    ];
    let paths = [si_engine::PathPreference {
        consumed_bytes: input.len(),
        text: output,
        language: CandidateLanguage::Chinese,
        frequency: 32.0,
        contextual: 12.0,
    }];
    let ordinary = engine.candidates(input, CHINESE);
    let personalized = engine.convert(
        input,
        CHINESE,
        false,
        &[],
        ConversionPreferences {
            tokens: &tokens,
            paths: &paths,
        },
    );
    let before = find(&ordinary, output, CandidateLanguage::Chinese, input.len());
    let after = find(
        &personalized,
        output,
        CandidateLanguage::Chinese,
        input.len(),
    );
    assert!(after.is_corrected());
    assert_eq!(before, after);
    assert_eq!(after.token_bonus, 0.0);
    Ok(())
}

#[test]
fn pinyin_correction_admission_compares_both_paths_with_context() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let want = add(&mut lexicon, ZH, "xiang", "想", 100);
    let unrelated = add(&mut lexicon, ZH, "chang'jian", "常见", 100);
    for text in ["你号", "你好", "你毫", "你好啊"] {
        add(&mut lexicon, ZH, "ni'hao", text, 10_000);
    }
    let target = add(&mut lexicon, ZH, "ni'hao", "拟好", 1);
    add(&mut lexicon, ZH, "shi'jie", "世界", 100);
    let mut grams = GramBuilder::new();
    grams.add(&[want, unrelated], 1_000_000).unwrap();
    grams.add(&[want, target], 200_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);

    let without_context = engine.preview("nihoashijie", CHINESE);
    assert!(
        without_context
            .iter()
            .find(|row| row.is_corrected())
            .is_some_and(|row| row.text != "拟好世界")
    );
    let rows = engine.convert_with_context(
        "nihoashijie",
        CHINESE,
        true,
        &[],
        ConversionPreferences::default(),
        "想",
    );
    assert_eq!(
        rows.iter().find(|row| row.is_corrected()).unwrap().text,
        "拟好世界",
    );
    Ok(())
}

#[test]
fn pinyin_correction_reports_the_edit_kind_and_original_word_span() -> io::Result<()> {
    use si_engine::{Correction, CorrectionKind};

    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    add(&mut lexicon, ZH, "lv'se", "绿色", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    for (spelling, output, edited_word, kind) in [
        ("niao", "你好", "niao", CorrectionKind::MissingKey),
        ("nohao", "你好", "nohao", CorrectionKind::NeighborKey),
        ("nihoa", "你好", "nihoa", CorrectionKind::AdjacentSwap),
        (
            "lü'se'nihoa",
            "绿色你好",
            "nihoa",
            CorrectionKind::AdjacentSwap,
        ),
    ] {
        let rows = engine.candidates(spelling, CHINESE);
        let row = find(&rows, output, CandidateLanguage::Chinese, spelling.len());
        assert_eq!(
            row.correction,
            Some(Correction {
                kind,
                word_start_bytes: spelling.len() - edited_word.len(),
                word_end_bytes: spelling.len(),
            })
        );
        assert_eq!(rows.last().unwrap().correction, None);
    }
    Ok(())
}

#[test]
fn pinyin_correction_uses_the_physical_key_for_normalized_v() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "qi'hao", "七号", 100_000);
    add(&mut lexicon, ZH, "qu'hao", "取号", 10);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);
    assert!(
        engine
            .candidates("qvhao", CHINESE)
            .iter()
            .all(|row| !row.is_corrected() || row.text != "七号")
    );
    assert_eq!(
        engine
            .candidates("qvhao", CHINESE)
            .iter()
            .find(|row| row.text == "取号")
            .unwrap()
            .correction,
        None
    );
    Ok(())
}

#[test]
fn default_whole_acceptance_skips_pinyin_corrections() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None).with_pinyin_correction(true);

    let mistyped = engine.candidates("nihoa", CHINESE);
    assert!(mistyped[0].is_corrected());
    assert_literal(
        Candidate::default_for_whole_input(&mistyped, 5).unwrap(),
        "nihoa",
    );
    let exact = engine.candidates("nihao", CHINESE);
    assert_eq!(
        Candidate::default_for_whole_input(&exact, 5).unwrap().text,
        "你好"
    );
    assert!(Candidate::default_for_whole_input(&[], 0).is_none());
    Ok(())
}

#[test]
fn pinyin_correction_does_not_discard_typed_letters() -> io::Result<()> {
    use si_engine::CorrectionSensitivity::{Conservative, HigherRecall};

    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni", "你", 100_000);
    add(&mut lexicon, ZH, "ni'hao", "你好", 100_000);
    add(&mut lexicon, ZH, "mi'lan'shi", "米兰市", 1);
    add(&mut lexicon, ZH, "mian'shi", "面试", 6_000);
    let resources = directory.resources(&mut lexicon, None)?;
    let baseline = CandidateEngine::new(&resources, None);
    for mode in [Conservative, HigherRecall] {
        let engine = CandidateEngine::new(&resources, None).with_correction_sensitivity(Some(mode));
        for input in ["nni", "nii", "nnihao", "nihaoo", "nihaox", "milanshi"] {
            assert_eq!(
                engine.candidates(input, CHINESE),
                baseline.candidates(input, CHINESE),
                "{input}"
            );
            assert_eq!(
                engine.preview(input, CHINESE),
                baseline.preview(input, CHINESE),
                "{input}"
            );
        }
        let separated = engine.candidates("ni'ihao", CHINESE);
        assert!(
            separated
                .iter()
                .all(|row| !row.is_corrected() || row.text != "你好")
        );
        assert_literal(separated.last().unwrap(), "ni'ihao");
    }
    Ok(())
}

#[test]
fn pinyin_correction_protects_a_strong_exact_path_without_context() -> io::Result<()> {
    use si_engine::CorrectionSensitivity::{Conservative, HigherRecall};

    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let name = add(&mut lexicon, ZH, "jiao", "叫", 100);
    add(&mut lexicon, ZH, "zhang'ling", "张玲", 10_000);
    let target = add(&mut lexicon, ZH, "zhang'liang", "张良", 10_000);
    let mut grams = GramBuilder::new();
    grams.add(&[name, target], 100_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    for preview in [false, true] {
        for mode in [Conservative, HigherRecall] {
            let engine =
                CandidateEngine::new(&resources, None).with_correction_sensitivity(Some(mode));
            let rows = engine.convert_with_context(
                "zhangling",
                CHINESE,
                preview,
                &[],
                ConversionPreferences::default(),
                "叫",
            );
            assert_eq!(rows[0].text, "张玲");
            assert!(rows.iter().all(|row| !row.is_corrected()), "{mode:?}");
            assert_literal(rows.last().unwrap(), "zhangling");
        }
    }
    Ok(())
}

#[test]
fn higher_recall_backs_off_negative_context_for_corrections() -> io::Result<()> {
    use si_engine::CorrectionSensitivity::{Conservative, HigherRecall};

    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let want = add(&mut lexicon, ZH, "xiang", "想", 100);
    let unrelated = add(&mut lexicon, ZH, "chang'jian", "常见", 100);
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    add(&mut lexicon, ZH, "shi'jie", "世界", 100);
    let mut grams = GramBuilder::new();
    grams.add(&[want, unrelated], 100_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let convert = |mode, input| {
        CandidateEngine::new(&resources, None)
            .with_correction_sensitivity(Some(mode))
            .convert_with_context(
                input,
                CHINESE,
                false,
                &[],
                ConversionPreferences::default(),
                "想",
            )
    };
    for (input, output) in [("nihoa", "你好"), ("nihaoshijei", "你好世界")] {
        let conservative = convert(Conservative, input);
        let recall = convert(HigherRecall, input);
        let corrected = |rows: &[Candidate]| {
            let row = find(rows, output, CandidateLanguage::Chinese, input.len());
            assert!(row.is_corrected());
            row.context_adjustment
        };
        assert!(corrected(&conservative) < corrected(&recall));
        assert_eq!(corrected(&recall), -2.0);
        assert!(
            conservative
                .iter()
                .filter(|row| !row.is_corrected())
                .eq(recall.iter().filter(|row| !row.is_corrected()))
        );
    }
    Ok(())
}
