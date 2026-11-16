use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use si_engine::resources::EngineResources;
use si_engine::resources::user::{UserLearningConfig, UserModelStore};
use si_engine::{
    Candidate, CandidateEngine, CandidateLanguage, ConversionPreferences, EnabledLanguages,
    PersonalPhrase,
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
        assert_eq!(
            find(&latest, "he", CandidateLanguage::English, 2).context_adjustment,
            0.0
        );
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
fn user_word_and_gram_evidence_follow_lexeme_identity_across_files() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let ornament = add(&mut lexicon, ZH, "shou'shi", "首饰", 200);
    let luggage = add(&mut lexicon, ZH, "xing'li", "行李", 80);
    let pick_up = add(&mut lexicon, ZH, "shou'shi", "收拾", 5);
    add(&mut lexicon, ZH, "gui'tai", "柜台", 80);
    add(&mut lexicon, ZH, "yun", "云", 10);
    add(&mut lexicon, ZH, "he", "鹤", 10);
    add(&mut lexicon, ZH, "bai'cha", "白茶", 50);
    let mut grams = GramBuilder::new();
    grams.add(&[ornament, luggage], 300).unwrap();
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
