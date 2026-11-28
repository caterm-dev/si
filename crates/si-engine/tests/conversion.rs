use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use si_engine::resources::EngineResources;
use si_engine::resources::user::{UserLearningConfig, UserModelStore};
use si_engine::{
    Candidate, CandidateEngine, CandidateLanguage, CandidatePoolInspector, ConversionOptions,
    ConversionPreferences, EnabledLanguages, PersonalPhrase, PoolOptions, SmallReranker,
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

fn engine_config(
    directory: &Scratch,
    changes: &[(&str, &str)],
) -> io::Result<si_engine::resources::EngineConfig> {
    let mut config = include_str!("../../../config/si.conf").to_owned();
    for (key, value) in changes {
        config = config
            .lines()
            .map(|line| {
                if line
                    .split_once('=')
                    .is_some_and(|(name, _)| name.trim() == *key)
                {
                    format!("{key} = {value}")
                } else {
                    line.to_owned()
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
    }
    let path = directory.path("engine.conf");
    fs::write(&path, config)?;
    let config = si_engine::resources::SiConfig::open(&path)?.engine;
    fs::remove_file(path)?;
    Ok(config)
}

#[test]
fn configured_model_pool_context_and_candidate_token_limits_are_used() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for text in ["树", "数", "书", "输"] {
        add(&mut lexicon, ZH, "shu", text, 100);
    }
    for text in ["你好", "你号"] {
        add(&mut lexicon, ZH, "ni'hao", text, 100);
    }
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let model_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Data/RerankerSmall");
    let convert = |input: &str, preceding: Option<&str>, model: &SmallReranker| {
        engine.convert_with_options(
            input,
            CHINESE,
            false,
            &[],
            ConversionPreferences::default(),
            preceding,
            ConversionOptions {
                correction: None,
                reranker: Some(model),
            },
        )
    };
    let config = engine_config(
        &directory,
        &[
            ("model_candidate_limit", "2"),
            ("model_context_token_limit", "0"),
        ],
    )?;
    let model = SmallReranker::open_with_config(&model_path, config.local_model_ranking)?;
    let baseline = engine.candidates("shu", CHINESE);
    assert_eq!(
        convert("shu", Some("院子里种几棵"), &model),
        convert("shu", None, &model)
    );

    let config = engine_config(&directory, &[("model_candidate_limit", "2")])?;
    let model = SmallReranker::open_with_config(&model_path, config.local_model_ranking)?;
    let rows = convert("shu", Some("院子里种几棵"), &model);
    assert!(rows.iter().any(|row| row.reranking_bonus < 0.0));
    let worst = rows
        .iter()
        .filter(|row| baseline[..2].iter().any(|base| base.text == row.text))
        .map(|row| row.reranking_bonus)
        .reduce(f64::min)
        .unwrap();
    for row in &rows {
        if !baseline[..2].iter().any(|base| base.text == row.text) {
            let expected = if row.language == CandidateLanguage::Literal {
                0.0
            } else {
                worst
            };
            assert_eq!(row.reranking_bonus, expected);
        }
    }
    for (tokens, adjusted) in [("1", false), ("2", true)] {
        let config = engine_config(&directory, &[("model_candidate_token_limit", tokens)])?;
        let model = SmallReranker::open_with_config(&model_path, config.local_model_ranking)?;
        let rows = convert("nihao", Some("朋友见面先说"), &model);
        assert_eq!(rows.iter().any(|row| row.reranking_bonus < 0.0), adjusted);
        assert_literal(rows.last().unwrap(), "nihao");
    }
    Ok(())
}

#[test]
fn configured_search_widths_include_sixty_four_path_completion_masks() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for i in 0..70 {
        add(&mut lexicon, EN, "a", &format!("token{i:02}"), 100);
    }
    add(&mut lexicon, EN, "hello", "hello", 100);
    add(&mut lexicon, EN, "ahello", "ahello", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    for width in [1, 31, 32, 33, 63, 64] {
        let width_text = width.to_string();
        let config = engine_config(
            &directory,
            &[
                ("full_search_beam_width", &width_text),
                ("preview_search_beam_width", &width_text),
                ("correction_search_beam_width", &width_text),
            ],
        )?;
        let engine = CandidateEngine::new_with_config(&resources, None, config);
        let full = engine.candidates("aahell", ENGLISH);
        let whole = full
            .iter()
            .filter(|row| !row.verbatim && row.completion && row.consumed_bytes == 6)
            .count();
        assert_eq!(whole, width, "search width {width}");
        assert_eq!(full, engine.candidates("aahell", ENGLISH));
        assert_eq!(full, engine.preview("aahell", ENGLISH));
        assert_literal(full.last().unwrap(), "aahell");
    }
    Ok(())
}

#[test]
fn configured_completion_costs_and_limits_change_only_their_scored_spelling() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for (reading, text) in [("hello", "hello"), ("help", "help"), ("helm", "helm")] {
        add(&mut lexicon, EN, reading, text, 100);
    }
    let resources = directory.resources(&mut lexicon, None)?;
    let baseline = CandidateEngine::new(&resources, None).candidates("hel", ENGLISH);
    for (key, value, expected_delta) in [
        ("completion_base_cost_bits", "2", 2.0),
        ("completion_missing_letter_cost_bits", "3", -4.0),
    ] {
        let config = engine_config(&directory, &[(key, value)])?;
        let engine = CandidateEngine::new_with_config(&resources, None, config);
        let rows = engine.candidates("hel", ENGLISH);
        let old = find(&baseline, "hello", CandidateLanguage::English, 3)
            .score_bits
            .unwrap();
        let new = find(&rows, "hello", CandidateLanguage::English, 3)
            .score_bits
            .unwrap();
        assert!((new - old - expected_delta).abs() < 1e-12, "{key}");
        assert!(!engine.candidates("hello", ENGLISH)[0].completion);
        assert_literal(rows.last().unwrap(), "hel");
    }
    let config = engine_config(&directory, &[("direct_completion_limit_per_language", "1")])?;
    let rows =
        CandidateEngine::new_with_config(&resources, None, config).candidates("hel", ENGLISH);
    assert_eq!(rows.iter().filter(|row| row.completion).count(), 1);
    let config = engine_config(&directory, &[("completion_missing_letter_limit", "1")])?;
    let rows =
        CandidateEngine::new_with_config(&resources, None, config).candidates("hel", ENGLISH);
    assert!(!rows.iter().any(|row| row.text == "hello"));
    assert!(rows.iter().any(|row| row.text == "help"));
    let config = engine_config(&directory, &[("completion_missing_letter_limit", "0")])?;
    let engine = CandidateEngine::new_with_config(&resources, None, config);
    assert!(
        engine
            .candidates("hel", ENGLISH)
            .iter()
            .all(|row| !row.completion)
    );
    assert_eq!(engine.candidates("hello", ENGLISH)[0].text, "hello");
    Ok(())
}

#[test]
fn configured_correction_edit_costs_and_confidence_margins_reach_search_and_pruning()
-> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    for (input, key, cost, kind) in [
        (
            "niho",
            "missing_key_correction_cost_bits",
            3.0,
            si_engine::CorrectionKind::MissingKey,
        ),
        (
            "nihoa",
            "adjacent_swap_correction_cost_bits",
            5.0,
            si_engine::CorrectionKind::AdjacentSwap,
        ),
        (
            "nigao",
            "neighbor_key_correction_cost_bits",
            7.0,
            si_engine::CorrectionKind::NeighborKey,
        ),
    ] {
        let cost_text = cost.to_string();
        let config = engine_config(&directory, &[(key, &cost_text)])?;
        let engine =
            CandidateEngine::new_with_config(&resources, None, config).with_pinyin_correction(true);
        for rows in [
            engine.candidates(input, CHINESE),
            engine.preview(input, CHINESE),
        ] {
            let row = rows
                .iter()
                .find(|row| row.text == "你好")
                .expect("configured edit remains available");
            assert_eq!(row.correction.unwrap().kind, kind);
            assert_eq!(row.score_bits, Some(-cost));
            assert_literal(rows.last().unwrap(), input);
        }
    }
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "duo'jiu", "多久", 600);
    add(&mut lexicon, ZH, "duo'ju", "多聚", 1);
    let resources = directory.resources(&mut lexicon, None)?;
    for (lead, expected) in [("2", "多聚"), ("1", "多久")] {
        let config = engine_config(
            &directory,
            &[("conservative_correction_minimum_lead_bits", lead)],
        )?;
        let engine =
            CandidateEngine::new_with_config(&resources, None, config).with_pinyin_correction(true);
        assert_eq!(engine.candidates("duoju", CHINESE)[0].text, expected);
    }
    let config = engine_config(&directory, &[("missing_key_correction_cost_bits", "7")])?;
    let engine =
        CandidateEngine::new_with_config(&resources, None, config).with_pinyin_correction(true);
    assert_eq!(engine.candidates("duoju", CHINESE)[0].text, "多久");
    let config = engine_config(
        &directory,
        &[("higher_recall_correction_minimum_lead_bits", "2")],
    )?;
    let engine = CandidateEngine::new_with_config(&resources, None, config)
        .with_correction_sensitivity(Some(si_engine::CorrectionSensitivity::HigherRecall));
    assert_eq!(engine.candidates("duoju", CHINESE)[0].text, "多聚");
    Ok(())
}

#[test]
fn configured_abbreviation_cost_reaches_exact_and_composed_paths() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    add(&mut lexicon, ZH, "ma", "吗", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let base = CandidateEngine::new(&resources, None);
    let config = engine_config(&directory, &[("pinyin_abbreviation_cost_bits", "3")])?;
    let custom = CandidateEngine::new_with_config(&resources, None, config);
    for input in ["nh", "nhma"] {
        let baseline = base.candidates(input, CHINESE);
        let rows = custom.candidates(input, CHINESE);
        let text = if input == "nh" { "你好" } else { "你好吗" };
        let before = find(&baseline, text, CandidateLanguage::Chinese, input.len())
            .score_bits
            .unwrap();
        let after = find(&rows, text, CandidateLanguage::Chinese, input.len())
            .score_bits
            .unwrap();
        assert!((after - before - 4.0).abs() < 1e-12);
    }
    Ok(())
}

#[test]
fn small_reranker_uses_loaded_configuration_without_reading_it_during_conversion() -> io::Result<()>
{
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "shu", "树", 100);
    add(&mut lexicon, ZH, "shu", "数", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let baseline = engine.candidates("shu", CHINESE);
    let model = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Data/RerankerSmall");
    let config_path = directory.path("si.conf");
    let bundled = include_str!("../../../config/si.conf");
    for model_score_weight in [0.5, 0.0] {
        fs::write(
            &config_path,
            bundled
                .replace(
                    "model_score_weight = 0.8",
                    &format!("model_score_weight = {model_score_weight}"),
                )
                .replace(
                    "model_score_gap_limit_bits = 8",
                    "model_score_gap_limit_bits = 4",
                ),
        )?;
        let config = si_engine::resources::SiConfig::open(&config_path)?;
        let reranker = SmallReranker::open_with_config(&model, config.engine.local_model_ranking)?;
        fs::remove_file(&config_path)?;
        let ranked = engine.convert_with_options(
            "shu",
            CHINESE,
            false,
            &[],
            ConversionPreferences::default(),
            Some("院子里种几棵"),
            ConversionOptions {
                correction: None,
                reranker: Some(&reranker),
            },
        );
        let minimum = ranked
            .iter()
            .map(|row| row.reranking_bonus)
            .reduce(f64::min)
            .unwrap();
        assert_eq!(minimum, -model_score_weight * 4.0);
        assert!(ranked.iter().all(|row| row.reranking_bonus <= 0.0));
        if model_score_weight == 0.0 {
            assert_eq!(ranked, baseline);
        }
    }
    Ok(())
}

#[test]
fn small_reranker_scores_twelve_homophones_and_penalizes_the_thirteenth() -> io::Result<()> {
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
    let context = "你说的这个人就";
    let ranked = engine.convert_with_options(
        "shi",
        CHINESE,
        false,
        &[],
        ConversionPreferences::default(),
        Some(context),
        ConversionOptions {
            correction: None,
            reranker: Some(&reranker),
        },
    );
    assert_eq!(baseline.len(), 14);
    assert_eq!(ranked.len(), baseline.len());
    let texts: Vec<_> = baseline[..12].iter().map(|row| row.text.as_str()).collect();
    let neural = si_neural::Reranker::open(&model)?;
    let with = neural
        .bounded_sequence_scores(context, &texts, 16, 12)?
        .unwrap()
        .scores;
    let bits: Vec<_> = with
        .iter()
        .map(|score| score * std::f64::consts::LOG2_E)
        .collect();
    let highest = bits.iter().copied().reduce(f64::max).unwrap();
    for (text, score) in texts.iter().zip(bits) {
        let expected = 0.8 * (score - highest).max(-8.0);
        let row = ranked.iter().find(|row| row.text == *text).unwrap();
        assert!((row.reranking_bonus - expected).abs() < 1e-6);
    }
    let unscored = ranked
        .iter()
        .position(|row| row.text == baseline[12].text)
        .unwrap();
    let worst = ranked
        .iter()
        .map(|row| row.reranking_bonus)
        .reduce(f64::min)
        .unwrap();
    assert!(worst < 0.0);
    assert_eq!(ranked[unscored].reranking_bonus, worst);
    for pair in ranked[..ranked.len() - 1].windows(2) {
        let score = |row: &Candidate| {
            row.score_bits.unwrap() + row.context_adjustment + row.reranking_bonus
        };
        assert!(score(&pair[0]) >= score(&pair[1]));
    }
    assert_eq!(ranked.last(), baseline.last());
    Ok(())
}

#[test]
fn small_reranker_penalizes_unscored_completions_and_reuses_identical_scored_text() -> io::Result<()>
{
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "ni'hao", "你好", 100);
    add(&mut lexicon, ZH, "ni'hao", "拟好", 90);
    add(&mut lexicon, ZH, "ni'hao'ma", "你好吗", 60);
    add(&mut lexicon, ZH, "ni", "你", 50);
    add(&mut lexicon, EN, "nihao", "你好", 1);
    let resources = directory.resources(&mut lexicon, None)?;
    let config = engine_config(&directory, &[("model_candidate_limit", "2")])?;
    let engine = CandidateEngine::new(&resources, None);
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Data/RerankerSmall");
    let model = SmallReranker::open_with_config(&path, config.local_model_ranking)?;
    let source = "nihao";
    let phrases = [PersonalPhrase {
        spelling: source,
        text: "私人问候",
        language: CandidateLanguage::Chinese,
        pinned: false,
    }];
    for context in [None, Some("见面时说")] {
        let baseline = engine.convert_with_options(
            source,
            BILINGUAL,
            false,
            &phrases,
            ConversionPreferences::default(),
            context,
            ConversionOptions::default(),
        );
        let rows = engine.convert_with_options(
            source,
            BILINGUAL,
            false,
            &phrases,
            ConversionPreferences::default(),
            context,
            ConversionOptions {
                correction: None,
                reranker: Some(&model),
            },
        );
        let chinese = find(&rows, "你好", CandidateLanguage::Chinese, source.len());
        let english = find(&rows, "你好", CandidateLanguage::English, source.len());
        assert_eq!(english.reranking_bonus, chinese.reranking_bonus);
        let worst = rows
            .iter()
            .map(|row| row.reranking_bonus)
            .reduce(f64::min)
            .unwrap();
        assert!(worst < 0.0);
        let completion = find(&rows, "你好吗", CandidateLanguage::Chinese, source.len());
        assert!(completion.completion);
        assert_eq!(completion.reranking_bonus, worst);
        assert!(rows.iter().any(|row| row.personal));
        assert!(rows.iter().any(|row| row.consumed_bytes < source.len()));
        for row in &rows {
            if row.personal
                || row.verbatim
                || row.language == CandidateLanguage::Literal
                || row.consumed_bytes < source.len()
            {
                assert_eq!(row.reranking_bonus, 0.0);
            }
            let original = find(&baseline, &row.text, row.language, row.consumed_bytes);
            assert_eq!(row.score_bits, original.score_bits);
            assert_eq!(row.source_boundaries, original.source_boundaries);
        }
    }
    Ok(())
}

#[test]
fn small_reranker_limits_conditional_probability_gaps_and_uses_bos_for_empty_fragments()
-> io::Result<()> {
    let directory = Scratch::new()?;
    let model = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Data/RerankerSmall");
    let reranker = SmallReranker::open(&model)?;
    for (leader_count, expected_first) in [(390, "树"), (410, "树"), (1_000_000, "数")] {
        let mut lexicon = Lexicon::new();
        add(&mut lexicon, ZH, "shu", "数", leader_count);
        add(&mut lexicon, ZH, "shu", "树", 100);
        let resources = directory.resources(&mut lexicon, None)?;
        let engine = CandidateEngine::new(&resources, None);
        let baseline = engine.candidates("shu", CHINESE);
        assert_eq!(baseline[0].text, "数");
        let convert = |context| {
            engine.convert_with_options(
                "shu",
                CHINESE,
                false,
                &[],
                ConversionPreferences::default(),
                context,
                ConversionOptions {
                    correction: None,
                    reranker: Some(&reranker),
                },
            )
        };
        let bos = convert(None);
        for context in [Some(""), Some("上一句话。")] {
            assert_eq!(convert(context), bos);
        }
        assert!(
            bos.iter()
                .all(|row| row.reranking_bonus >= -6.4 && row.reranking_bonus <= 0.0)
        );
        let ranked = convert(Some("院子里种几棵"));
        assert_eq!(ranked[0].text, expected_first);
        let tree = ranked.iter().find(|row| row.text == "树").unwrap();
        assert_eq!(tree.score_bits, baseline[1].score_bits);
        assert_eq!(tree.reranking_bonus, 0.0);
        let other = ranked.iter().find(|row| row.text == "数").unwrap();
        assert!(other.reranking_bonus < -2.0 && other.reranking_bonus >= -8.0);
    }
    Ok(())
}

#[test]
fn small_reranker_applies_bounded_bos_adjustments_without_changing_lexical_evidence()
-> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "chi'you'shi'jian", "吃有时间", 100);
    add(&mut lexicon, ZH, "chi'you'shi'jian", "持有时间", 100);
    add(&mut lexicon, ZH, "chi", "吃", 10);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Data/RerankerSmall");
    let model = SmallReranker::open(&path)?;
    let source = "chiyoushijian";
    let baseline = engine.candidates(source, BILINGUAL);
    assert_eq!(baseline[0].text, "吃有时间");
    let convert = |model: &SmallReranker, context, preview| {
        engine.convert_with_options(
            source,
            BILINGUAL,
            preview,
            &[],
            ConversionPreferences::default(),
            context,
            ConversionOptions {
                correction: None,
                reranker: Some(model),
            },
        )
    };
    let rows = convert(&model, None, false);
    assert_eq!(rows[0].text, "持有时间");
    assert_eq!(rows, convert(&model, Some(""), false));
    assert_eq!(rows, convert(&model, Some("上一句话。"), false));
    assert_eq!(baseline, convert(&model, None, true));
    let config = engine_config(
        &directory,
        &[
            ("model_context_token_limit", "1"),
            ("model_score_gap_limit_bits", "0"),
        ],
    )?;
    let truncated = SmallReranker::open_with_config(&path, config.local_model_ranking)?;
    assert_eq!(rows, convert(&truncated, Some("\u{10ffff}"), false));
    for row in &rows {
        let before = find(&baseline, &row.text, row.language, row.consumed_bytes);
        assert_eq!(row.score_bits, before.score_bits);
        assert_eq!(row.source_boundaries, before.source_boundaries);
        assert_eq!(row.confirmation_boundaries, before.confirmation_boundaries);
        assert!(row.reranking_bonus >= -6.4 && row.reranking_bonus <= 0.0);
        if row.consumed_bytes < source.len()
            || row.language == CandidateLanguage::Literal
            || row.verbatim
        {
            assert_eq!(row.reranking_bonus, 0.0);
        }
    }
    assert_literal(rows.last().unwrap(), source);
    for changes in [
        vec![("model_sentence_reward_cap_bits", "0")],
        vec![("model_score_weight", "0")],
        vec![("model_candidate_token_limit", "1")],
    ] {
        let config = engine_config(&directory, &changes)?;
        let model = SmallReranker::open_with_config(&path, config.local_model_ranking)?;
        assert_eq!(baseline, convert(&model, None, false));
    }
    Ok(())
}

#[test]
fn small_reranker_uses_whole_sentence_gaps_to_overcome_homophone_frequency() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let source = "nirenweizhezhongfangshihaoma";
    let reading = "ni'ren'wei'zhe'zhong'fang'shi'hao'ma";
    let correct = "你认为这种方式好吗";
    let incorrect = "你认为这种方式号码";
    add(&mut lexicon, ZH, reading, incorrect, 2_663_317);
    add(&mut lexicon, ZH, reading, correct, 668_208);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let baseline = engine.candidates(source, CHINESE);
    assert_eq!(baseline[0].text, incorrect);
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Data/RerankerSmall");
    let model = SmallReranker::open(&path)?;
    let rows = engine.convert_with_options(
        source,
        CHINESE,
        false,
        &[],
        ConversionPreferences::default(),
        None,
        ConversionOptions {
            correction: None,
            reranker: Some(&model),
        },
    );
    assert_eq!(rows[0].text, correct);
    assert_eq!(rows[0].reranking_bonus, 0.0);
    let incorrect_row = find(&rows, incorrect, CandidateLanguage::Chinese, source.len());
    assert_eq!(incorrect_row.reranking_bonus, -6.4);
    let window = si_engine::presentation::conversion_window(source, CHINESE, &rows);
    assert_eq!(rows[window[0]].text, correct);
    assert_eq!(rows.last(), baseline.last());
    Ok(())
}

#[test]
fn small_reranker_prefers_probable_question_over_rare_high_lift_homophone() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for (text, count) in [("号码", 2_663_317), ("好吗", 668_208), ("号吗", 19_684)] {
        add(&mut lexicon, ZH, "hao'ma", text, count);
    }
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let source = "haoma";
    let baseline = engine.candidates(source, CHINESE);
    assert_eq!(baseline[0].text, "号码");
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Data/RerankerSmall");
    let model = SmallReranker::open(&path)?;
    let neural = si_neural::Reranker::open(&path)?;
    let texts = ["好吗", "号码", "号吗"];
    let unconditional = neural
        .bounded_sequence_scores("", &texts, 0, 16)?
        .unwrap()
        .scores;
    for context in ["方式", "你认为这种方式"] {
        let conditional = neural
            .bounded_sequence_scores(context, &texts, 16, 16)?
            .unwrap()
            .scores;
        // The rare candidate has higher lift despite its lower conditional probability.
        assert!(conditional[2] - unconditional[2] > conditional[0] - unconditional[0]);
        assert!(conditional[0] > conditional[2]);
        let bonuses = model.bonuses(context, &texts).unwrap();
        assert_eq!(bonuses[0], 0.0);
        assert_eq!(bonuses[2], -6.4);
        let rows = engine.convert_with_options(
            source,
            CHINESE,
            false,
            &[],
            ConversionPreferences::default(),
            Some(context),
            ConversionOptions {
                correction: None,
                reranker: Some(&model),
            },
        );
        assert_eq!(rows[0].text, "好吗");
        for row in &rows {
            let original = find(&baseline, &row.text, row.language, row.consumed_bytes);
            assert_eq!(row.score_bits, original.score_bits);
            assert_eq!(row.source_boundaries, original.source_boundaries);
        }
        assert_eq!(rows.last(), baseline.last());
    }
    Ok(())
}

#[test]
fn small_reranker_promotes_tree_after_planting_context() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for (text, count) in [
        ("数", 4_473_854),
        ("书", 3_193_779),
        ("输", 1_099_171),
        ("树", 830_603),
        ("熟", 430_235),
        ("丨", 156_384),
    ] {
        add(&mut lexicon, ZH, "shu", text, count);
    }
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let baseline = engine.candidates("shu", CHINESE);
    assert_eq!(baseline[0].text, "数");
    let model = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Data/RerankerSmall");
    let reranker = SmallReranker::open(&model)?;
    let convert = || {
        engine.convert_with_options(
            "shu",
            CHINESE,
            false,
            &[],
            ConversionPreferences::default(),
            Some("院子太晒，最好沿着围墙多种几棵"),
            ConversionOptions {
                correction: None,
                reranker: Some(&reranker),
            },
        )
    };
    let ranked = convert();
    assert_eq!(ranked[0].text, "树");
    assert_eq!(ranked, convert());
    assert_eq!(ranked.len(), baseline.len());
    for row in &ranked {
        let original = baseline.iter().find(|old| old.text == row.text).unwrap();
        assert_eq!(row.score_bits, original.score_bits);
        assert_eq!(row.consumed_bytes, original.consumed_bytes);
    }
    assert_eq!(ranked.last(), baseline.last());
    let window = si_engine::presentation::conversion_window("shu", CHINESE, &ranked);
    assert_eq!(ranked[window[0]].text, "树");
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
    let reward = |count: f64, mass: f64, discount: f64| {
        (count / mass / unigram).log2().clamp(0.0, 5.0) * count / (count + 10.0) * discount
    };
    let mixed_bigram = reward(64.0, 96.0, 0.7);
    let same_language_bigram = reward(32.0, 96.0, 0.7);
    let mixed_trigram = reward(512.0, 512.0, 1.0);
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
        assert!(
            (find(&rows, "try 有", CandidateLanguage::Mixed, 6)
                .score_bits
                .unwrap()
                - (2.0 * unigram.log2() + mixed_bigram))
                .abs()
                < 1e-12
        );
        assert!(
            (find(&rows, "try you", CandidateLanguage::English, 6)
                .score_bits
                .unwrap()
                - (2.0 * unigram.log2() + same_language_bigram))
                .abs()
                < 1e-12
        );
        let rows = convert("you", "Try ");
        assert_eq!(rows[0].text, "有");
        assert!((rows[0].context_adjustment - mixed_bigram).abs() < 1e-12);
        let rows = convert("shu", "Try 有");
        assert!((rows[0].context_adjustment - mixed_trigram).abs() < 1e-12);
        let rows = convert("you", "Try 有");
        let absent = find(&rows, "you", CandidateLanguage::English, 3);
        assert_eq!(absent.context_adjustment, 0.0);
    }
    Ok(())
}

#[test]
fn base_grams_use_one_trigram_or_discounted_bigram_and_sparse_missing_matches_are_neutral()
-> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let first = add(&mut lexicon, ZH, "xian", "先", 100);
    let look = add(&mut lexicon, ZH, "kan", "看", 100);
    let book = add(&mut lexicon, ZH, "shu", "书", 100);
    let tree = add(&mut lexicon, ZH, "shu", "树", 100);
    let again = add(&mut lexicon, ZH, "zai", "再", 100);
    let mut grams = GramBuilder::new();
    grams.add(&[look, book], 900).unwrap();
    grams.add(&[look, tree], 100).unwrap();
    grams.add(&[first, look, book], 1).unwrap();
    grams.add(&[first, look, tree], 999).unwrap();
    // Higher stored orders must not change the fixed trigram ceiling.
    grams.add(&[again, first, look, book], 10_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let config = engine_config(&directory, &[("segmentation_history_limit", "1")])?;
    let engine = CandidateEngine::new_with_config(&resources, None, config);
    let base = 0.2_f64.log2();
    let bigram = (0.9_f64 / 0.2).log2() * 900.0 / 910.0 * 0.7;
    let trigram = (0.999_f64 / 0.2).log2() * 999.0 / 1_009.0;
    for preview in [false, true] {
        let convert = |input| {
            engine.convert(
                input,
                CHINESE,
                preview,
                &[],
                ConversionPreferences::default(),
            )
        };
        for (input, text, expected) in [
            ("kanshu", "看书", 2.0 * base + bigram),
            ("xiankanshu", "先看书", 3.0 * base),
            ("xiankanshu", "先看树", 3.0 * base + trigram),
            ("zaikanshu", "再看书", 3.0 * base + bigram),
            ("zaixiankanshu", "再先看书", 4.0 * base),
            ("xiankansh", "先看树", 3.0 * base + trigram - 5.0),
        ] {
            let rows = convert(input);
            let candidate = find(&rows, text, CandidateLanguage::Chinese, input.len());
            assert!(
                (candidate.score_bits.unwrap() - expected).abs() < 1e-12,
                "{input}: {text}"
            );
            assert_literal(rows.last().unwrap(), input);
        }
        let rows = convert("xiankanshuzai");
        assert!(
            (find(&rows, "先看树", CandidateLanguage::Chinese, 10)
                .score_bits
                .unwrap()
                - (3.0 * base + trigram))
                .abs()
                < 1e-12
        );
        for (preceding, text, expected) in [
            ("先看", "书", 0.0),
            ("先看", "树", trigram),
            ("再看", "书", bigram),
            ("再", "书", 0.0),
        ] {
            let rows = engine.convert_with_context(
                "shu",
                CHINESE,
                preview,
                &[],
                ConversionPreferences::default(),
                preceding,
            );
            assert!(
                (find(&rows, text, CandidateLanguage::Chinese, 3).context_adjustment - expected)
                    .abs()
                    < 1e-12,
                "{preceding}: {text}"
            );
        }
    }
    Ok(())
}

#[test]
fn unseen_base_bigrams_require_observed_history_and_successor_tokenization() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut last_penalty = 0.0;
    for (history_count, incoming_count) in [
        (10_000, 0),
        (32, 10_000),
        (10_000, 32),
        (100, 100),
        (10_000, 10_000),
    ] {
        let mut lexicon = Lexicon::new();
        let look = add(&mut lexicon, ZH, "kan", "看", 100);
        let book = add(&mut lexicon, ZH, "shu", "书", 100);
        let tree = add(&mut lexicon, ZH, "shu", "树", 100);
        let again = add(&mut lexicon, ZH, "zai", "再", 100);
        let mut grams = GramBuilder::new();
        grams.add(&[look, tree], history_count).unwrap();
        grams.add(&[again, book], incoming_count).unwrap();
        let resources = directory.resources(&mut lexicon, Some(grams))?;
        let enabled = CandidateEngine::new(&resources, None);
        let config = engine_config(
            &directory,
            &[("base_word_gram_backoff_penalty_cap_bits", "0")],
        )?;
        let disabled = CandidateEngine::new_with_config(&resources, None, config);
        for preview in [false, true] {
            let convert = |engine: &CandidateEngine<'_>, input| {
                engine.convert(
                    input,
                    CHINESE,
                    preview,
                    &[],
                    ConversionPreferences::default(),
                )
            };
            let rows = convert(&enabled, "kanshu");
            assert_eq!(rows, convert(&enabled, "kanshu"));
            let baseline = convert(&disabled, "kanshu");
            let score = |rows: &[Candidate], text| {
                find(rows, text, CandidateLanguage::Chinese, 6)
                    .score_bits
                    .unwrap()
            };
            let penalty = score(&baseline, "看书") - score(&rows, "看书");
            if history_count <= 32 || incoming_count <= 32 {
                assert_eq!(penalty, 0.0);
            } else {
                assert!(penalty > 0.0 && penalty < 1.0);
                if !preview {
                    assert!(penalty > last_penalty);
                    last_penalty = penalty;
                }
            }
            // Seen bigrams, the first word, and direct words retain their scores.
            assert_eq!(score(&baseline, "看树"), score(&rows, "看树"));
            assert_eq!(convert(&enabled, "shu"), convert(&disabled, "shu"));
            let longer = convert(&enabled, "kanshuzai");
            assert_eq!(score(&rows, "看书"), score(&longer, "看书"));
            let field = enabled.convert_with_context(
                "shu",
                CHINESE,
                preview,
                &[],
                ConversionPreferences::default(),
                "看",
            );
            let adjustment = find(&field, "书", CandidateLanguage::Chinese, 3).context_adjustment;
            assert!((adjustment + penalty).abs() < 1e-12);
            assert_literal(rows.last().unwrap(), "kanshu");
        }
    }
    Ok(())
}

#[test]
fn confident_unseen_bigram_backoff_can_overturn_a_high_frequency_word_stack() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let eat = add(&mut lexicon, ZH, "chi", "吃", 18_329_161);
    let have_time = add(&mut lexicon, ZH, "you'shi'jian", "有时间", 2_068_444);
    let hold = add(&mut lexicon, ZH, "chi'you", "持有", 321_058);
    let time = add(&mut lexicon, ZH, "shi'jian", "时间", 35_561_296);
    let other = add(&mut lexicon, ZH, "qi'ta", "其他", 23_374_649_933);
    let mut grams = GramBuilder::new();
    grams.add(&[eat, other], 24_414).unwrap();
    grams.add(&[other, have_time], 1_062).unwrap();
    grams.add(&[hold, time], 5).unwrap();
    grams.add(&[hold, other], 142).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let config = engine_config(
        &directory,
        &[("base_word_gram_backoff_penalty_cap_bits", "0")],
    )?;
    let disabled = CandidateEngine::new_with_config(&resources, None, config);
    let baseline = disabled.candidates("chiyoushijian", BILINGUAL);
    assert_eq!(baseline[0].text, "吃有时间");
    for correction in [false, true] {
        let enabled = CandidateEngine::new(&resources, None).with_pinyin_correction(correction);
        let rows = enabled.candidates("chiyoushijian", BILINGUAL);
        assert_eq!(rows[0].text, "持有时间");
        assert_eq!(
            rows[0].score_bits,
            find(&baseline, "持有时间", CandidateLanguage::Chinese, 13).score_bits
        );
        assert!(
            find(&rows, "吃有时间", CandidateLanguage::Chinese, 13)
                .score_bits
                .unwrap()
                < rows[0].score_bits.unwrap()
        );
        assert_literal(rows.last().unwrap(), "chiyoushijian");
    }
    Ok(())
}

#[test]
fn preceding_field_uses_only_the_last_fragment_and_resets_at_punctuation() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let previous = add(&mut lexicon, ZH, "he'shui", "喝水", 20);
    let terminal = add(&mut lexicon, ZH, "guo", "过", 10);
    let river = add(&mut lexicon, ZH, "he", "河", 5);
    let together = add(&mut lexicon, ZH, "he", "和", 40);
    let the = add(&mut lexicon, EN, "the", "the", 15);
    let english = add(&mut lexicon, EN, "he", "he", 15);
    let mut grams = GramBuilder::new();
    grams.add(&[previous, together], 1_000).unwrap();
    grams.add(&[terminal, river], 1_000).unwrap();
    grams.add(&[previous, terminal, river], 1_000).unwrap();
    grams.add(&[the, english], 1_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let config = engine_config(&directory, &[("segmentation_history_limit", "1")])?;
    let engine = CandidateEngine::new_with_config(&resources, None, config);
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
        let latest = convert("he", "过", preview);
        assert_eq!(latest, convert("he", "喝水！过", preview));
        assert_eq!(latest, convert("he", "喝水\n过", preview));
        for context in ["过。", "喝水！过。 ” ", "喝水。过，", "喝水\n"] {
            assert_eq!(baseline, convert("he", context, preview));
        }
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
        // Both exact word IDs have ample corpus evidence, but this bilingual
        // transition is absent. The last fragment applies bounded backoff.
        assert!(
            (find(&latest, "he", CandidateLanguage::English, 2).context_adjustment + 0.88).abs()
                < 1e-12
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
                &convert("he'guo", "过", preview),
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
fn exact_pool_recovers_a_gram_winner_without_pruning_its_intermediate_history() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for ch in '\u{4e00}'..='\u{4e1d}' {
        add(&mut lexicon, ZH, "ji", &ch.to_string(), 100);
    }
    let tie = add(&mut lexicon, ZH, "ji", "系", 99);
    let good = add(&mut lexicon, ZH, "hao", "好", 100);
    let shoelace = add(&mut lexicon, ZH, "xie'dai", "鞋带", 100);
    let mut grams = GramBuilder::new();
    grams.add(&[tie, good], 10_000).unwrap();
    grams.add(&[tie, good, shoelace], 10_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    let source = "jihaoxiedai";
    let original = engine.candidates(source, CHINESE);
    assert!(!original.iter().any(|row| row.text == "系好鞋带"));
    let inspector = CandidatePoolInspector::new(&engine).unwrap();
    let pool = inspector
        .inspect(source, CHINESE, None, None, PoolOptions::default())
        .unwrap();
    assert!(pool.complete);
    assert_eq!(pool.native, original);
    let target = pool
        .entries
        .iter()
        .find(|row| row.candidate.text == "系好鞋带")
        .unwrap();
    assert_eq!(target.k_best_rank, Some(1));
    assert!(target.selected);
    assert_eq!(target.tokens.len(), 3);
    let sum: f64 = target
        .tokens
        .iter()
        .map(|token| {
            token.unigram_bits + token.gram_bits + token.context_bits + token.spelling_bits
        })
        .sum();
    assert!(
        (sum - target.candidate.score_bits.unwrap() - target.candidate.context_adjustment).abs()
            < 1e-10
    );
    assert_eq!(original, engine.candidates(source, CHINESE));
    let interrupted = inspector
        .inspect(
            source,
            CHINESE,
            None,
            None,
            PoolOptions {
                search_budget: 1,
                ..PoolOptions::default()
            },
        )
        .unwrap();
    assert!(!interrupted.complete);
    assert_eq!(interrupted.certified, 0);
    assert_eq!(interrupted.stop, "expansion-limit");
    assert_eq!(interrupted.native, original);
    for row in original.iter().filter(|row| {
        row.consumed_bytes == source.len() && row.language != CandidateLanguage::Literal
    }) {
        assert!(
            interrupted
                .entries
                .iter()
                .any(|entry| entry.candidate.text == row.text
                    && entry.candidate.language == row.language)
        );
    }
    Ok(())
}

#[test]
fn exact_pool_matches_complete_small_lattices_and_filters_only_after_search() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let mut variants = Vec::new();
    for text in ["及", "机", "级", "寄"] {
        variants.push(add(&mut lexicon, ZH, "ji", text, 100));
    }
    let good = add(&mut lexicon, ZH, "hao", "好", 100);
    add(&mut lexicon, ZH, "hao", "号", 100);
    add(&mut lexicon, ZH, "ji'hao", "系好", 5);
    let shoe = add(&mut lexicon, ZH, "xie'dai", "鞋带", 100);
    add(&mut lexicon, ZH, "xie'dai", "携带", 100);
    add(&mut lexicon, EN, "jihaoxiedai", "及好携带", 100);
    let previous = add(&mut lexicon, ZH, "wo", "我", 100);
    let start = lexicon.add_word("<s>", 0).unwrap();
    let mut grams = GramBuilder::new();
    grams.add(&[variants[3], good], 1000).unwrap();
    grams.add(&[variants[3], good, shoe], 1000).unwrap();
    grams.add(&[previous, variants[0]], 500).unwrap();
    grams.add(&[start, variants[3]], 500).unwrap();
    grams.add(&[start, variants[3], good], 500).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    let inspector = CandidatePoolInspector::new(&engine).unwrap();
    let source = "jihaoxiedai";
    let options = PoolOptions {
        pool_size: 64,
        multiword_limit: 64,
        ..PoolOptions::default()
    };
    let all = inspector
        .inspect(source, BILINGUAL, None, None, options)
        .unwrap();
    assert!(all.complete);
    let expected: Vec<_> = all
        .native
        .iter()
        .filter(|row| {
            row.consumed_bytes == source.len()
                && row.language != CandidateLanguage::Literal
                && !row.completion
        })
        .collect();
    let mut actual: Vec<_> = all
        .entries
        .iter()
        .filter(|row| row.k_best_rank.is_some())
        .collect();
    actual.sort_by_key(|row| row.k_best_rank);
    assert_eq!(actual.len(), expected.len());
    for (row, expected) in actual.iter().zip(expected) {
        assert_eq!(
            (&row.candidate.text, row.candidate.language),
            (&expected.text, expected.language)
        );
        assert!((row.candidate.score_bits.unwrap() - expected.score_bits.unwrap()).abs() < 1e-10);
    }
    let limited = inspector
        .inspect(
            source,
            BILINGUAL,
            None,
            None,
            PoolOptions {
                multiword_limit: 1,
                ..options
            },
        )
        .unwrap();
    assert_eq!(limited.native, all.native);
    assert_eq!(
        limited
            .entries
            .iter()
            .filter(|row| row.quota_kept && row.tokens.len() >= 3)
            .count(),
        1
    );
    assert!(
        limited
            .entries
            .iter()
            .any(|row| row.exclusion == "word-quota")
    );
    assert!(
        limited
            .entries
            .iter()
            .any(|row| row.exclusion == "structure" && row.blocked_by.len() == 2)
    );
    let duplicate: Vec<_> = all
        .entries
        .iter()
        .filter(|row| row.candidate.text == "及好携带")
        .collect();
    assert_eq!(duplicate.len(), 2);
    assert_ne!(
        duplicate[0].candidate.language,
        duplicate[1].candidate.language
    );
    for preceding in [Some("我"), Some("")] {
        let contextual = inspector
            .inspect(source, BILINGUAL, preceding, None, options)
            .unwrap();
        assert!(contextual.complete);
        let expected: Vec<_> = contextual
            .native
            .iter()
            .filter(|row| {
                row.consumed_bytes == source.len()
                    && row.language != CandidateLanguage::Literal
                    && !row.completion
            })
            .collect();
        let mut actual: Vec<_> = contextual
            .entries
            .iter()
            .filter(|row| row.k_best_rank.is_some())
            .collect();
        actual.sort_by_key(|row| row.k_best_rank);
        assert_eq!(actual.len(), expected.len());
        for (row, expected) in actual.iter().zip(expected) {
            assert_eq!(
                (&row.candidate.text, row.candidate.language),
                (&expected.text, expected.language)
            );
            let total = |row: &Candidate| row.score_bits.unwrap() + row.context_adjustment;
            assert!((total(&row.candidate) - total(expected)).abs() < 1e-10);
        }
    }
    assert!(
        CandidatePoolInspector::new(&CandidateEngine::new(&resources, Some(&resources))).is_err()
    );
    for short in ["ji", "jihao"] {
        let choices = inspector
            .inspect(short, CHINESE, None, None, options)
            .unwrap();
        assert!(choices.complete);
        assert!(
            choices
                .entries
                .iter()
                .all(|row| row.exclusion != "structure")
        );
    }
    let top = inspector
        .inspect(
            source,
            BILINGUAL,
            None,
            None,
            PoolOptions {
                k_best: 1,
                ..options
            },
        )
        .unwrap();
    assert!(top.complete);
    assert_eq!(
        top.entries
            .iter()
            .find(|row| row.k_best_rank == Some(1))
            .unwrap()
            .candidate,
        actual[0].candidate
    );
    Ok(())
}

#[test]
fn exact_pool_preserves_alias_offsets_disabled_languages_and_empty_input() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "lü", "绿", 100);
    add(&mut lexicon, ZH, "hao", "好", 100);
    let resources = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&resources, None);
    let inspector = CandidatePoolInspector::new(&engine).unwrap();
    let source = "lu:'hao";
    let pool = inspector
        .inspect(source, CHINESE, Some(""), None, PoolOptions::default())
        .unwrap();
    assert!(pool.complete);
    let target = pool
        .entries
        .iter()
        .find(|row| row.candidate.text == "绿好")
        .unwrap();
    assert_eq!(target.tokens[0].source_end, 4);
    assert_eq!(target.tokens[1].source_start, 4);
    assert_eq!(target.candidate.consumed_bytes, source.len());
    for (source, languages) in [
        ("", CHINESE),
        (
            "Unknown_ID",
            EnabledLanguages {
                chinese: false,
                english: false,
            },
        ),
    ] {
        let pool = inspector
            .inspect(source, languages, None, None, PoolOptions::default())
            .unwrap();
        assert!(pool.complete);
        assert!(pool.entries.is_empty());
        assert_eq!(pool.native, engine.candidates(source, languages));
    }
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
        add(&mut lexicon, ZH, "xing'li", &format!("行李{index:02}"), 4);
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
    add(&mut lexicon, ZH, "wo", "我", 100);
    let want = add(&mut lexicon, ZH, "xiang", "想", 100);
    let look = add(&mut lexicon, ZH, "kan", "看", 100);
    let book = add(&mut lexicon, ZH, "shu", "书", 100);
    let tree = add(&mut lexicon, ZH, "shu", "树", 100);
    let mut grams = GramBuilder::new();
    grams.add(&[look, tree], 200).unwrap();
    grams.add(&[want, look, book], 2000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    assert_eq!(engine.candidates("kanshu", CHINESE)[0].text, "看树");
    assert_eq!(engine.candidates("xiangkanshu", CHINESE)[0].text, "想看书");
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
fn user_ingestion_keeps_known_english_and_filters_new_complete_pinyin_runs() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for text in ["alpha", "cloud", "an", "he", "woman", "banana"] {
        add(&mut lexicon, EN, text, text, 20);
    }
    // A lookup alias alone is not evidence that its spelling is an English word.
    let greeting = add(&mut lexicon, EN, "hello", "hello", 20);
    lexicon.add_key(EN, b"nihao", greeting).unwrap();
    add(&mut lexicon, ZH, "wo", "我", 20);
    add(&mut lexicon, ZH, "bu", "不", 20);
    add(&mut lexicon, ZH, "zhi'dao", "知道", 20);
    let base = directory.resources(&mut lexicon, None)?;
    let store = UserModelStore::new(directory.path("pinyin.si-user"));
    let existing = si_engine::resources::user::UserEntry {
        text: "zaijian".into(),
        reading: Some((1, b"zaijian".to_vec())),
        count: 7,
    };
    store.edit_entry(None, Some(&existing))?;
    for batch in ["first", "second"] {
        store.ingest(
            base.lexicon(),
            batch,
            [
                Ok("alpha wobuzhidao cloud"),
                Ok("alpha WOBUZHIDAO cloud"),
                Ok("alpha langui cloud"),
                Ok("alpha nihao cloud"),
                Ok("an he woman banana"),
                Ok("AN HE WOMAN BANANA"),
                Ok("alpha frobnitz cloud"),
                Ok("alpha wobuzhidaox cloud"),
                Ok("我不知道"),
            ],
        )?;
    }
    let user = store.load()?.unwrap();
    for text in ["wobuzhidao", "WOBUZHIDAO", "langui", "nihao"] {
        assert!(user.lexicon().find_word(text).is_none(), "{text}");
    }
    for text in [
        "an",
        "he",
        "woman",
        "banana",
        "AN",
        "HE",
        "WOMAN",
        "BANANA",
        "frobnitz",
        "wobuzhidaox",
        "我",
        "不",
        "知道",
    ] {
        let id = user.lexicon().find_word(text).unwrap();
        assert_eq!(user.lexicon().word(id).unwrap().count, 2, "{text}");
    }
    let existing_id = user.lexicon().find_word("zaijian").unwrap();
    assert_eq!(user.lexicon().word(existing_id).unwrap().count, 7);
    let alpha = user.lexicon().find_word("alpha").unwrap();
    let cloud = user.lexicon().find_word("cloud").unwrap();
    let unknown = user.lexicon().find_word("frobnitz").unwrap();
    let grams = user.grams().unwrap();
    assert_eq!(grams.count(&[alpha, cloud]), None);
    assert_eq!(grams.count(&[alpha, unknown, cloud]), Some(2));
    let engine = CandidateEngine::new(&base, Some(&user));
    let rows = engine.candidates("wobuzhidao", BILINGUAL);
    assert!(has(&rows, "我不知道", CandidateLanguage::Chinese, 10));
    assert!(!has(&rows, "wobuzhidao", CandidateLanguage::English, 10));
    assert_literal(rows.last().unwrap(), "wobuzhidao");
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
    let star = add(&mut base_lexicon, EN, "star", "star", 20);
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
fn base_trigram_ceiling_does_not_limit_user_fivegram_evidence() -> io::Result<()> {
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
        "今天我喝查"
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
    // K=1 retains the original single-best segmentation contract. Multi-history
    // scoring deliberately also considers alternate suffix cuts (covered below).
    let config = engine_config(&directory, &[("segmentation_history_limit", "1")])?;
    let engine = CandidateEngine::new_with_config(&base, None, config);
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
    let completed = engine.candidates("nihoa'shij", CHINESE);
    let suggestion = find(
        &completed,
        "你好世界",
        CandidateLanguage::Chinese,
        "nihoa'shij".len(),
    );
    assert!(suggestion.is_corrected() && suggestion.completion);
    assert!(suggestion.confirmation_boundaries.is_empty());
    assert_eq!(
        suggestion.source_boundaries.last(),
        Some(&"nihoa'shij".len())
    );
    let invalid_separators = "nihoa'shi'j'e";
    let rows = engine.candidates(invalid_separators, CHINESE);
    assert!(rows.iter().all(|row| !row.is_corrected()));
    assert_eq!(rows, baseline.candidates(invalid_separators, CHINESE));
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
                let mut surface = row.text.as_str();
                let mut reading = String::new();
                while !surface.is_empty() {
                    let (word, spelling) = readings
                        .iter()
                        .find(|(word, _)| surface.starts_with(word))
                        .unwrap_or_else(|| {
                            panic!("unknown corrected output for {input}: {}", row.text)
                        });
                    reading.push_str(spelling);
                    surface = &surface[word.len()..];
                }
                let target_lengths = if row.completion {
                    input.len().saturating_sub(1)..=(input.len() + 1).min(reading.len())
                } else {
                    reading.len()..=reading.len()
                };
                assert!(
                    target_lengths
                        .into_iter()
                        .any(|end| one_key_edit(input.as_bytes(), &reading.as_bytes()[..end])),
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
    for amplified in [false, true] {
        let changes: &[(&str, &str)] = if amplified {
            &[
                ("base_word_gram_reward_cap_bits", "32"),
                ("base_word_gram_backoff_discount", "1"),
            ]
        } else {
            &[]
        };
        let config = engine_config(&directory, changes)?;
        let ordinary = CandidateEngine::new_with_config(&resources, None, config);
        let correction =
            CandidateEngine::new_with_config(&resources, None, config).with_pinyin_correction(true);

        for preview in [false, true] {
            for (context, should_suggest) in [("", false), ("想。找", false), ("找。想", true)]
            {
                let should_suggest = amplified && should_suggest;
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
        add(&mut lexicon, ZH, "ni'hao", text, 100);
    }
    let target = add(&mut lexicon, ZH, "ni'hao", "拟好", 20);
    add(&mut lexicon, ZH, "shi'jie", "世界", 100);
    let mut grams = GramBuilder::new();
    grams.add(&[want, unrelated], 100_000).unwrap();
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
fn missing_gram_records_are_neutral_in_both_correction_modes() -> io::Result<()> {
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
        assert_eq!(corrected(&conservative), 0.0);
        assert_eq!(corrected(&recall), 0.0);
        assert!(
            conservative
                .iter()
                .filter(|row| !row.is_corrected())
                .eq(recall.iter().filter(|row| !row.is_corrected()))
        );
    }
    Ok(())
}

#[test]
fn earlier_pinyin_correction_survives_an_unfinished_final_word() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "wo'bu'zhi'dao", "我不知道", 10_000);
    add(&mut lexicon, ZH, "wo", "我", 1_000);
    add(&mut lexicon, ZH, "bu", "不", 1_000);
    add(&mut lexicon, ZH, "zhi'hui", "只会", 1_000);
    add(&mut lexicon, ZH, "dao", "到", 1_000);
    add(
        &mut lexicon,
        ZH,
        "ni'shi'bu'shi'yi'ge",
        "你是不是一个",
        1_000,
    );
    add(&mut lexicon, ZH, "xin", "新", 1_000);
    add(&mut lexicon, ZH, "xiao", "小", 900);
    let base = directory.resources(&mut lexicon, None)?;
    let ordinary = CandidateEngine::new(&base, None);
    let engine = CandidateEngine::new(&base, None).with_pinyin_correction(true);
    let stem = "wobuzhdaonishibushiyige";
    for preview in [false, true] {
        for (tail, expected, completion) in [
            ("", "我不知道你是不是一个", false),
            ("x", "我不知道你是不是一个新", true),
            ("xi", "我不知道你是不是一个新", true),
            ("xin", "我不知道你是不是一个新", false),
        ] {
            let input = format!("{stem}{tail}");
            let rows = engine.convert(
                &input,
                CHINESE,
                preview,
                &[],
                ConversionPreferences::default(),
            );
            let best = &rows[0];
            assert_eq!(best.text, expected, "{input}");
            assert!(best.is_corrected());
            assert_eq!(best.completion, completion, "{input}");
            assert_eq!(best.consumed_bytes, input.len());
            assert_eq!(best.source_boundaries.last(), Some(&input.len()));
            let edit = best.correction.unwrap();
            assert_eq!(edit.word_start_bytes, 0);
            assert_eq!(edit.word_end_bytes, "wobuzhdao".len());
            assert_eq!(edit.kind, si_engine::CorrectionKind::MissingKey);
            assert!(best.confirmation_boundaries.is_empty());
            assert_eq!(best.token_bonus, 0.0);
            let regular = ordinary.convert(
                &input,
                CHINESE,
                preview,
                &[],
                ConversionPreferences::default(),
            );
            assert!(
                regular
                    .iter()
                    .eq(rows.iter().filter(|row| !row.is_corrected())),
                "{input}"
            );
            assert_literal(rows.last().unwrap(), &input);
            let window = si_engine::presentation::conversion_window(&input, CHINESE, &rows);
            assert_eq!(rows[window[0]].text, expected);
        }
    }
    Ok(())
}

#[test]
fn corrected_completion_uses_its_own_history_and_preserves_bounded_alternatives() -> io::Result<()>
{
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let first = add(&mut lexicon, ZH, "wo'bu'zhi'dao", "我不知道", 10_000);
    add(&mut lexicon, ZH, "wo", "我", 1_000);
    add(&mut lexicon, ZH, "bu", "不", 1_000);
    add(&mut lexicon, ZH, "zhi'hui", "只会", 1_000);
    add(&mut lexicon, ZH, "dao", "到", 1_000);
    let previous = add(
        &mut lexicon,
        ZH,
        "ni'shi'bu'shi'yi'ge",
        "你是不是一个",
        1_000,
    );
    for i in 0..40 {
        let output = char::from_u32(0x4e00 + i).unwrap().to_string();
        add(&mut lexicon, ZH, "xin", &output, 1_000);
    }
    let rare = add(&mut lexicon, ZH, "xin", "新", 50);
    let mut grams = GramBuilder::new();
    grams.add(&[first, previous, rare], 10_000).unwrap();
    let base = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&base, None).with_pinyin_correction(true);
    let ordinary = CandidateEngine::new(&base, None);
    let input = "wobuzhdaonishibushiyigex";
    for preview in [false, true] {
        let rows = engine.convert(
            input,
            CHINESE,
            preview,
            &[],
            ConversionPreferences::default(),
        );
        assert_eq!(rows[0].text, "我不知道你是不是一个新");
        assert!(rows[0].is_corrected() && rows[0].completion);
        assert!(rows.iter().filter(|row| row.is_corrected()).count() <= 4);
        assert!(
            ordinary
                .convert(
                    input,
                    CHINESE,
                    preview,
                    &[],
                    ConversionPreferences::default()
                )
                .iter()
                .eq(rows.iter().filter(|row| !row.is_corrected()))
        );
    }
    Ok(())
}

#[test]
fn corrected_completion_requires_a_lead_over_ordinary_completions() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "wo'bu'zhi'dao", "我不知道", 1);
    add(&mut lexicon, ZH, "wo", "我", 10_000);
    add(&mut lexicon, ZH, "bu", "不", 10_000);
    add(&mut lexicon, ZH, "zhi'hui", "只会", 10_000);
    add(&mut lexicon, ZH, "dao", "到", 10_000);
    add(
        &mut lexicon,
        ZH,
        "ni'shi'bu'shi'yi'ge",
        "你是不是一个",
        10_000,
    );
    add(&mut lexicon, ZH, "xin", "新", 10_000);
    let base = directory.resources(&mut lexicon, None)?;
    let input = "wobuzhdaonishibushiyigex";
    for mode in [
        si_engine::CorrectionSensitivity::Conservative,
        si_engine::CorrectionSensitivity::HigherRecall,
    ] {
        let engine = CandidateEngine::new(&base, None).with_correction_sensitivity(Some(mode));
        for preview in [false, true] {
            let rows = engine.convert(
                input,
                CHINESE,
                preview,
                &[],
                ConversionPreferences::default(),
            );
            assert!(rows.iter().all(|row| !row.is_corrected()));
            assert!(
                rows.iter()
                    .any(|row| row.completion && row.consumed_bytes == input.len())
            );
        }
    }
    Ok(())
}

#[test]
fn corrected_completion_preserves_atomic_alias_spans_and_literal_acceptance() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    add(&mut lexicon, ZH, "lv'se", "绿色", 100);
    add(&mut lexicon, ZH, "xin", "新", 100);
    let base = directory.resources(&mut lexicon, None)?;
    let engine = CandidateEngine::new(&base, None).with_pinyin_correction(true);
    for alias in ["lv", "lü", "lu:", "lu\u{308}"] {
        let stem = format!("{alias}'es");
        let input = format!("{stem}x");
        let rows = engine.candidates(&input, CHINESE);
        let corrected = find(&rows, "绿色新", CandidateLanguage::Chinese, input.len());
        assert!(corrected.is_corrected() && corrected.completion);
        let edit = corrected.correction.unwrap();
        assert_eq!(edit.kind, si_engine::CorrectionKind::AdjacentSwap);
        assert_eq!(edit.word_start_bytes, 0);
        assert_eq!(edit.word_end_bytes, stem.len());
        assert_eq!(corrected.source_boundaries.last(), Some(&input.len()));
        assert!(
            corrected
                .source_boundaries
                .iter()
                .all(|&offset| input.is_char_boundary(offset))
        );
        assert!(corrected.confirmation_boundaries.is_empty());
        assert!(
            !Candidate::default_for_whole_input(&rows, input.len())
                .unwrap()
                .is_corrected()
        );
        assert_literal(rows.last().unwrap(), &input);
        assert!(
            !engine
                .candidates(&format!("{stem}x'"), CHINESE)
                .iter()
                .any(|r| r.is_corrected())
        );
        assert!(
            !engine
                .candidates(&format!("{stem}x_"), CHINESE)
                .iter()
                .any(|r| r.is_corrected())
        );
    }
    Ok(())
}

#[test]
fn sentence_start_rewards_the_longest_countable_prefix_without_penalizing_unseen_paths()
-> io::Result<()> {
    let directory = Scratch::new()?;
    let resources = sentence_start_resources(&directory)?;
    let engine = CandidateEngine::new(&resources, None);
    for preview in [false, true] {
        let baseline = engine.convert(
            "bawomen",
            CHINESE,
            preview,
            &[],
            ConversionPreferences::default(),
        );
        let start = engine.convert_with_context(
            "bawomen",
            CHINESE,
            preview,
            &[],
            ConversionPreferences::default(),
            "",
        );
        assert_eq!(start[0].text, "把我们");
        for (text, first, whole_count, first_count) in
            [("把我们", "把", 24.0, 96.0), ("吧我们", "吧", 0.0, 4.0)]
        {
            let plain = find(&baseline, text, CandidateLanguage::Chinese, 7);
            let candidate = find(&start, text, CandidateLanguage::Chinese, 7);
            let x = (whole_count / 24.0_f64).min(1.0);
            let expected = 2.0 * x * x * (3.0 - 2.0 * x);
            assert!((candidate.context_adjustment - expected).abs() < 1e-12);
            assert_eq!(candidate.score_bits, plain.score_bits);
            assert!((0.0..=2.0).contains(&candidate.context_adjustment));
            assert_eq!(candidate.context_adjustment > 0.0, text == "把我们");
            let short = engine.convert_with_context(
                "ba",
                CHINESE,
                preview,
                &[],
                ConversionPreferences::default(),
                "",
            );
            let prefix = find(&start, first, CandidateLanguage::Chinese, 2);
            assert_eq!(
                prefix.context_adjustment,
                find(&short, first, CandidateLanguage::Chinese, 2).context_adjustment
            );
            let x = (first_count / 96.0_f64).min(1.0);
            let first_reward = 2.0 * x * x * (3.0 - 2.0 * x);
            assert!((prefix.context_adjustment - first_reward).abs() < 1e-12);
        }
        let longer = engine.convert_with_context(
            "bawomenbawomen",
            CHINESE,
            preview,
            &[],
            ConversionPreferences::default(),
            "",
        );
        assert_eq!(
            find(&longer, "把我们把我们", CandidateLanguage::Chinese, 14).context_adjustment,
            find(&start, "把我们", CandidateLanguage::Chinese, 7).context_adjustment
        );
        assert_literal(start.last().unwrap(), "bawomen");
    }
    Ok(())
}

#[test]
fn sentence_start_requires_a_known_boundary_and_never_reuses_text_before_it() -> io::Result<()> {
    let directory = Scratch::new()?;
    let resources = sentence_start_resources(&directory)?;
    let engine = CandidateEngine::new(&resources, None);
    for preview in [false, true] {
        let convert = |context| {
            engine.convert_with_context(
                "ba",
                BILINGUAL,
                preview,
                &[],
                ConversionPreferences::default(),
                context,
            )
        };
        let unknown = engine.convert(
            "ba",
            BILINGUAL,
            preview,
            &[],
            ConversionPreferences::default(),
        );
        let start = convert("");
        assert_ne!(start, unknown);
        for context in [
            " ",
            "我今天?",
            "我今天?  ",
            "我们，",
            "我们。”, ",
            "我们\n ",
            "我们\u{2028}",
            "他说：“",
            "你好。”",
            "“",
            "（ [《 ",
            "我们!!!",
        ] {
            assert_eq!(convert(context), start, "{context:?}");
        }
        for context in [
            "Mystery",
            "我今天",
            "我们?Mystery",
            "我们。陌",
            "我们/",
            "（/）",
            "/。$",
        ] {
            assert_eq!(convert(context), unknown, "{context:?}");
        }
        let continued = convert("我们 ");
        assert_ne!(continued, start);
        assert_ne!(continued, unknown);
        assert_eq!(continued, convert("我今天?我们 "));
        assert_eq!(continued, convert("我们,我们 "));
        // Empty output from disabled languages remains the exact literal.
        let disabled = engine.convert_with_context(
            "ba",
            EnabledLanguages {
                chinese: false,
                english: false,
            },
            preview,
            &[],
            ConversionPreferences::default(),
            "",
        );
        assert_eq!(disabled.len(), 1);
        assert_literal(&disabled[0], "ba");
    }
    Ok(())
}

#[test]
fn sentence_start_applies_to_direct_words_but_excludes_personal_and_verbatim_paths()
-> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let good = add(&mut lexicon, ZH, "ba'wo'men", "把我们", 100);
    add(&mut lexicon, ZH, "ba'wo'men", "吧我们", 100);
    let marker = lexicon.add_word("<s>", 0).unwrap();
    let mut grams = GramBuilder::new();
    grams.add(&[marker, good], 100).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    let direct = engine.convert_with_context(
        "bawomen",
        CHINESE,
        false,
        &[],
        ConversionPreferences::default(),
        "",
    );
    assert_eq!(direct[0].text, "把我们");
    assert_eq!(direct[0].lexical_tokens, 1);
    assert_eq!(
        find(&direct, "吧我们", CandidateLanguage::Chinese, 7).context_adjustment,
        0.0
    );
    let phrases = [PersonalPhrase {
        spelling: "bawomen",
        text: "吧我们",
        language: CandidateLanguage::Chinese,
        pinned: true,
    }];
    let personal = engine.convert_with_context(
        "bawomen",
        CHINESE,
        false,
        &phrases,
        ConversionPreferences::default(),
        "",
    );
    let pinned = find(&personal, "吧我们", CandidateLanguage::Chinese, 7);
    assert!(pinned.preferred && pinned.personal);
    assert_eq!(pinned.context_adjustment, 0.0);

    let directory = Scratch::new()?;
    let resources = sentence_start_resources(&directory)?;
    let engine = CandidateEngine::new(&resources, None);
    let spelling = "baXYZwomen";
    let mixed = engine.convert_with_context(
        spelling,
        BILINGUAL,
        false,
        &[],
        ConversionPreferences::default(),
        "",
    );
    let candidate = find(
        &mixed,
        "把XYZ我们",
        CandidateLanguage::Mixed,
        spelling.len(),
    );
    assert!(candidate.verbatim);
    assert_eq!(candidate.context_adjustment, 0.0);
    Ok(())
}

#[test]
fn sentence_start_without_marker_or_observations_uses_the_existing_score() -> io::Result<()> {
    for marker_present in [false, true] {
        let directory = Scratch::new()?;
        let mut lexicon = Lexicon::new();
        let ba = add(&mut lexicon, ZH, "ba", "把", 100);
        let women = add(&mut lexicon, ZH, "wo'men", "我们", 100);
        if marker_present {
            lexicon.add_word("<s>", 0).unwrap();
        }
        let mut grams = GramBuilder::new();
        grams.add(&[ba, women], 100).unwrap();
        let resources = directory.resources(&mut lexicon, Some(grams))?;
        let engine = CandidateEngine::new(&resources, None);
        assert_eq!(
            engine.candidates("bawomen", CHINESE),
            engine.convert_with_context(
                "bawomen",
                CHINESE,
                false,
                &[],
                ConversionPreferences::default(),
                ""
            )
        );
    }
    Ok(())
}

fn sentence_start_resources(directory: &Scratch) -> io::Result<EngineResources> {
    let mut lexicon = Lexicon::new();
    let good = add(&mut lexicon, ZH, "ba", "把", 100);
    let bad = add(&mut lexicon, ZH, "ba", "吧", 100);
    let women = add(&mut lexicon, ZH, "wo'men", "我们", 100);
    let marker = lexicon.add_word("<s>", 0).unwrap();
    let mut grams = GramBuilder::new();
    for (words, count) in [
        (vec![marker, good], 96),
        (vec![marker, bad], 4),
        (vec![marker, women], 900),
        (vec![good, women], 100),
        (vec![bad, women], 100),
        (vec![women, bad], 100),
        (vec![marker, good, women], 24),
    ] {
        grams.add(&words, count).unwrap();
    }
    directory.resources(&mut lexicon, Some(grams))
}

#[test]
fn sentence_start_high_order_winner_survives_dense_terminal_completion_pruning() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let good = add(&mut lexicon, ZH, "ba", "把", 100);
    let bad = add(&mut lexicon, ZH, "ba", "吧", 100);
    let tails: Vec<_> = (0..40)
        .map(|offset| {
            let text = char::from_u32(0x4e00 + offset).unwrap().to_string();
            let count = if offset == 39 { 99 } else { 100 };
            (add(&mut lexicon, ZH, "wen", &text, count), text, count)
        })
        .collect();
    let marker = lexicon.add_word("<s>", 0).unwrap();
    let mut grams = GramBuilder::new();
    grams.add(&[marker, good], 50).unwrap();
    grams.add(&[marker, bad], 50).unwrap();
    for (tail, _, count) in &tails {
        grams.add(&[good, *tail], *count).unwrap();
        grams.add(&[bad, *tail], *count).unwrap();
    }
    grams
        .add(&[marker, good, tails.last().unwrap().0], 50)
        .unwrap();
    let expected = format!("把{}", tails.last().unwrap().1);
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    for preview in [false, true] {
        let convert = |input| {
            engine.convert_with_context(
                input,
                CHINESE,
                preview,
                &[],
                ConversionPreferences::default(),
                "",
            )
        };
        let exact = convert("bawen");
        let completion = convert("bawe");
        assert_eq!(exact[0].text, expected);
        assert_eq!(completion[0].text, expected);
        assert!(completion[0].completion);
        assert_eq!(
            exact[0].context_adjustment,
            completion[0].context_adjustment
        );
        assert_eq!(exact[0].context_adjustment, 2.0);
    }
    Ok(())
}

#[test]
fn sentence_start_uses_base_boundaries_with_an_unmarked_user_model() -> io::Result<()> {
    let directory = Scratch::new()?;
    let resources = sentence_start_resources(&directory)?;
    let store = UserModelStore::new(directory.path("profile.si-user"));
    store.ingest(
        resources.lexicon(),
        "synthetic",
        (0..20).map(|_| Ok("吧我们")),
    )?;
    let user = store.load()?.unwrap();
    assert!(user.lexicon().find_word("<s>").is_none());
    assert!(user.lexicon().find_word("</s>").is_none());
    let base = CandidateEngine::new(&resources, None);
    let personalized = CandidateEngine::new(&resources, Some(&user));
    let convert = |engine: &CandidateEngine<'_>| {
        engine.convert_with_context(
            "bawomen",
            CHINESE,
            false,
            &[],
            ConversionPreferences::default(),
            "",
        )
    };
    let base = convert(&base);
    let with_user = convert(&personalized);
    for text in ["把我们", "吧我们"] {
        let base = find(&base, text, CandidateLanguage::Chinese, 7);
        let candidate = find(&with_user, text, CandidateLanguage::Chinese, 7);
        assert!(candidate.context_adjustment.abs() <= 2.0);
        assert!(
            candidate.score_bits.unwrap() + candidate.context_adjustment
                >= base.score_bits.unwrap() + base.context_adjustment - 1e-12
        );
    }
    Ok(())
}

#[test]
fn sentence_start_reward_uses_competing_probability_and_is_invariant_to_corpus_scaling()
-> io::Result<()> {
    for frequency in [1, 100, 1_000_000_000] {
        for scale in [1, 7] {
            for (count, expected) in [
                (0, 0.0),
                (1, 0.000596),
                (25, 0.3125),
                (50, 1.0),
                (75, 1.6875),
                (100, 2.0),
                (200, 2.0),
            ] {
                let directory = Scratch::new()?;
                let mut lexicon = Lexicon::new();
                let target = add(&mut lexicon, ZH, "ba", "把", frequency);
                let other = add(&mut lexicon, ZH, "ba", "吧", 100);
                let unrelated = add(&mut lexicon, ZH, "wo", "我", 100);
                let marker = lexicon.add_word("<s>", 0).unwrap();
                let mut grams = GramBuilder::new();
                grams.add(&[marker, unrelated], 1_000_000).unwrap();
                grams.add(&[marker, other], 100 * scale).unwrap();
                grams.add(&[marker, target], count * scale).unwrap();
                let resources = directory.resources(&mut lexicon, Some(grams))?;
                let engine = CandidateEngine::new(&resources, None);
                let rows = engine.convert_with_context(
                    "ba",
                    CHINESE,
                    false,
                    &[],
                    ConversionPreferences::default(),
                    "",
                );
                let candidate = find(&rows, "把", CandidateLanguage::Chinese, 2);
                assert!((candidate.context_adjustment - expected).abs() < 1e-12);
                if count == 100 {
                    assert_eq!(
                        find(&rows, "吧", CandidateLanguage::Chinese, 2).context_adjustment,
                        2.0
                    );
                }
                let baseline = engine.candidates("ba", CHINESE);
                assert_eq!(
                    candidate.score_bits,
                    find(&baseline, "把", CandidateLanguage::Chinese, 2).score_bits
                );
            }
        }
    }
    Ok(())
}

#[test]
fn quoted_titles_and_parentheses_keep_previous_words_without_creating_sentence_starts()
-> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let ba = add(&mut lexicon, ZH, "ba", "吧", 100);
    let good = add(&mut lexicon, ZH, "ba", "把", 100);
    let seen = add(&mut lexicon, ZH, "kan'guo", "看过", 100);
    let snake = add(&mut lexicon, ZH, "qing'she", "青蛇", 100);
    let war = add(&mut lexicon, ZH, "zhan'zheng'zhi'wang", "战争之王", 100);
    let movie = add(
        &mut lexicon,
        ZH,
        "tang'bo'hu'dian'qiu'xiang",
        "唐伯虎点秋香",
        100,
    );
    let nomination = add(&mut lexicon, ZH, "ti'ming", "提名", 100);
    add(&mut lexicon, ZH, "kan'guo'qing'she", "看过青蛇", 1_000_000);
    let decimal = add(&mut lexicon, EN, "decimal", "3.14", 100);
    let domain = add(&mut lexicon, EN, "example", "example.com", 100);
    let node = add(&mut lexicon, EN, "node", "Node.js", 100);
    let marker = lexicon.add_word("<s>", 0).unwrap();
    let mut grams = GramBuilder::new();
    grams.add(&[marker, good], 100).unwrap();
    for previous in [snake, war, movie, nomination, decimal, domain, node] {
        grams.add(&[previous, ba], 1_000).unwrap();
    }
    grams.add(&[seen, snake, ba], 1_000).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    for preview in [false, true] {
        let convert = |context| {
            engine.convert_with_context(
                "ba",
                CHINESE,
                preview,
                &[],
                ConversionPreferences::default(),
                context,
            )
        };
        let start = convert("");
        assert_eq!(start[0].text, "把");
        for context in [
            "看过《青蛇》",
            "你看过《战争之王》",
            "看过《唐伯虎点秋香》",
            "第78届奥斯卡金像奖最佳动画长片(提名)",
            "3.14",
            "example.com",
            "Node.js",
        ] {
            let rows = convert(context);
            assert_eq!(rows[0].text, "吧", "{context:?}");
            assert!(rows[0].context_adjustment > 0.0);
            assert_ne!(rows, start, "{context:?}");
        }
        assert_eq!(convert("看过《青蛇》"), convert("看过 青蛇"));
        let previous = convert("青蛇");
        for context in [
            "《青蛇》",
            "〈青蛇〉",
            "“青蛇”",
            "‘青蛇’",
            "「青蛇」",
            "『青蛇』",
            "（青蛇）",
            "(青蛇)",
            "【青蛇】",
            "[青蛇]",
            "\"青蛇\"",
            "'青蛇'",
        ] {
            assert_eq!(convert(context), previous, "{context:?}");
        }
        for context in [
            "他说：“",
            "你好。”",
            "看过《青蛇》？",
            "(提名)。",
            "(提名).",
            "“",
            "（ [《 ",
        ] {
            assert_eq!(convert(context), start, "{context:?}");
        }
    }
    Ok(())
}

#[test]
fn relative_sentence_start_probabilities_compare_enabled_languages_and_matching_spans()
-> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let good = add(&mut lexicon, ZH, "ba", "把", 40);
    let bad = add(&mut lexicon, ZH, "ba", "吧", 100);
    let english = add(&mut lexicon, EN, "ba", "ba", 40);
    let unrelated = add(&mut lexicon, ZH, "wo", "我", 1_000_000);
    let completion = add(&mut lexicon, ZH, "bao", "包", 1);
    let women = add(&mut lexicon, ZH, "wo'men", "我们", 100);
    let english_women = add(&mut lexicon, EN, "women", "women", 100);
    let corrected_opening = add(&mut lexicon, ZH, "da", "打", 100);
    let direct = add(&mut lexicon, ZH, "ba'wo'men", "巴沃门", 1);
    let start = lexicon.add_word("<s>", 0).unwrap();
    let mut grams = GramBuilder::new();
    for (ids, count) in [
        (vec![start, good], 100),
        (vec![start, bad], 1),
        (vec![start, english], 50),
        (vec![start, unrelated], 1_000_000),
        (vec![start, completion], 1_000_000),
        (vec![start, good, women], 100),
        (vec![start, good, english_women], 50),
        (vec![start, corrected_opening], 1_000_000),
        (vec![start, direct], 50),
    ] {
        grams.add(&ids, count).unwrap();
    }
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    for preview in [false, true] {
        let convert = |input, languages| {
            engine.convert_with_context(
                input,
                languages,
                preview,
                &[],
                ConversionPreferences::default(),
                "",
            )
        };
        let rows = convert("ba", BILINGUAL);
        assert_eq!(rows[0].text, "把");
        assert_eq!(
            find(&rows, "把", CandidateLanguage::Chinese, 2).context_adjustment,
            2.0
        );
        assert!(
            (find(&rows, "吧", CandidateLanguage::Chinese, 2).context_adjustment - 0.000596).abs()
                < 1e-12
        );
        assert_eq!(
            find(&rows, "ba", CandidateLanguage::English, 2).context_adjustment,
            1.0
        );
        assert_eq!(
            find(&convert("ba", ENGLISH), "ba", CandidateLanguage::English, 2).context_adjustment,
            2.0
        );
        // High-count completions and unrelated spellings cannot dilute exact openings.
        assert_eq!(
            find(&rows, "包", CandidateLanguage::Chinese, 2).context_adjustment,
            2.0
        );
        let longer = convert("bawomen", BILINGUAL);
        assert_eq!(
            find(&longer, "把", CandidateLanguage::Chinese, 2).context_adjustment,
            2.0
        );
        assert_eq!(
            find(&longer, "把我们", CandidateLanguage::Chinese, 7).context_adjustment,
            2.0
        );
        assert_eq!(
            find(&longer, "巴沃门", CandidateLanguage::Chinese, 7).context_adjustment,
            1.0
        );
        assert_eq!(
            find(&longer, "把 women", CandidateLanguage::Mixed, 7).context_adjustment,
            1.0
        );
        assert_eq!(
            find(&longer, "吧我们", CandidateLanguage::Chinese, 7).context_adjustment,
            0.0
        );
        assert_literal(rows.last().unwrap(), "ba");
        assert_eq!(rows, convert("ba", BILINGUAL));
        let corrected = CandidateEngine::new(&resources, None)
            .with_pinyin_correction(true)
            .convert_with_context(
                "bawomen",
                BILINGUAL,
                preview,
                &[],
                ConversionPreferences::default(),
                "",
            );
        assert_eq!(
            find(&corrected, "把", CandidateLanguage::Chinese, 2).context_adjustment,
            2.0
        );
    }
    Ok(())
}

#[test]
fn relative_sentence_start_winner_is_found_before_dense_lexical_beam_pruning() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let words: Vec<_> = (0..80)
        .map(|offset| {
            let text = char::from_u32(0x4e00 + offset).unwrap().to_string();
            let count = if offset == 79 { 50 } else { 100 };
            (add(&mut lexicon, ZH, "ba", &text, count), text)
        })
        .collect();
    let women = add(&mut lexicon, ZH, "wo'men", "我们", 100);
    let start = lexicon.add_word("<s>", 0).unwrap();
    let mut grams = GramBuilder::new();
    for (i, (word, _)) in words.iter().enumerate() {
        let count = if i == 79 { 10_000 } else { 1 };
        grams.add(&[start, *word], count).unwrap();
        grams.add(&[start, *word, women], count).unwrap();
        grams.add(&[*word, women], 100).unwrap();
    }
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    let expected = format!("{}我们", words.last().unwrap().1);
    for preview in [false, true] {
        let rows = engine.convert_with_context(
            "bawomen",
            CHINESE,
            preview,
            &[],
            ConversionPreferences::default(),
            "",
        );
        assert_eq!(rows[0].text, expected);
        assert_eq!(rows[0].context_adjustment, 2.0);
        assert!(
            rows.iter()
                .filter(|row| row.score_bits.is_some())
                .all(|row| (0.0..=2.0).contains(&row.context_adjustment))
        );
    }
    Ok(())
}

#[test]
fn relative_sentence_start_budget_exhaustion_keeps_completed_prefixes_and_neutralizes_later_spans()
-> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let mut ids = Vec::new();
    for offset in 0..8_200 {
        let text = char::from_u32(0x4e00 + offset).unwrap().to_string();
        ids.push(add(&mut lexicon, ZH, "ba", &text, 100));
    }
    let start = lexicon.add_word("<s>", 0).unwrap();
    let mut grams = GramBuilder::new();
    for (i, id) in ids.into_iter().enumerate() {
        grams.add(&[start, id], i as u64 + 1).unwrap();
    }
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    let rows = engine.convert_with_context(
        "baba",
        CHINESE,
        true,
        &[],
        ConversionPreferences::default(),
        "",
    );
    let short = engine.convert_with_context(
        "ba",
        CHINESE,
        true,
        &[],
        ConversionPreferences::default(),
        "",
    );
    for row in rows.iter().filter(|row| row.consumed_bytes == 2) {
        let original = find(&short, &row.text, row.language, 2);
        assert_eq!(row.context_adjustment, original.context_adjustment);
    }
    assert!(
        rows.iter()
            .filter(|row| row.consumed_bytes == 4)
            .all(|row| row.context_adjustment == 0.0)
    );
    assert!(rows.iter().any(|row| row.context_adjustment == 2.0));
    assert_literal(rows.last().unwrap(), "baba");
    Ok(())
}

#[test]
fn relative_sentence_start_uses_current_span_competitors_after_the_opening_count_freezes()
-> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let ba = add(&mut lexicon, ZH, "ba", "把", 100);
    add(&mut lexicon, ZH, "wo", "我", 100);
    let direct = add(&mut lexicon, ZH, "ba'wo", "巴沃", 1);
    let start = lexicon.add_word("<s>", 0).unwrap();
    let mut grams = GramBuilder::new();
    grams.add(&[start, ba], 100).unwrap();
    grams.add(&[start, direct], 200).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    for preview in [false, true] {
        let rows = engine.convert_with_context(
            "bawo",
            CHINESE,
            preview,
            &[],
            ConversionPreferences::default(),
            "",
        );
        assert_eq!(
            find(&rows, "把", CandidateLanguage::Chinese, 2).context_adjustment,
            2.0
        );
        assert_eq!(
            find(&rows, "巴沃", CandidateLanguage::Chinese, 4).context_adjustment,
            2.0
        );
        assert_eq!(
            find(&rows, "把我", CandidateLanguage::Chinese, 4).context_adjustment,
            1.0
        );
    }
    Ok(())
}

#[test]
fn relative_sentence_start_preserves_umlaut_aliases_and_explicit_source_separators()
-> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let good = add(&mut lexicon, ZH, "lv", "绿", 100);
    let other = add(&mut lexicon, ZH, "lv", "旅", 100);
    let women = add(&mut lexicon, ZH, "wo'men", "我们", 100);
    let start = lexicon.add_word("<s>", 0).unwrap();
    let mut grams = GramBuilder::new();
    grams.add(&[start, good], 100).unwrap();
    grams.add(&[start, other], 50).unwrap();
    grams.add(&[start, good, women], 100).unwrap();
    grams.add(&[start, other, women], 50).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let engine = CandidateEngine::new(&resources, None);
    for input in ["lvwomen", "lüwomen", "lu:women", "lv'wo'men"] {
        for preview in [false, true] {
            let rows = engine.convert_with_context(
                input,
                CHINESE,
                preview,
                &[],
                ConversionPreferences::default(),
                "",
            );
            assert_eq!(
                find(&rows, "绿我们", CandidateLanguage::Chinese, input.len()).context_adjustment,
                2.0
            );
            assert_eq!(
                find(&rows, "旅我们", CandidateLanguage::Chinese, input.len()).context_adjustment,
                1.0
            );
            assert_literal(rows.last().unwrap(), input);
        }
    }
    Ok(())
}

#[test]
fn preceding_top_k_mixes_probabilities_and_temperature_changes_homophone_ranking() -> io::Result<()>
{
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    for (text, reading, count) in [
        ("最好", "zui'hao", 1_000),
        ("最", "zui", 900),
        ("好", "hao", 900),
        ("多种", "duo'zhong", 100),
        ("多", "duo", 80),
        ("种", "zhong", 80),
        ("几棵", "ji'ke", 100),
        ("几", "ji", 90),
        ("棵", "ke", 90),
        ("树", "shu", 10),
        ("数", "shu", 11),
        ("书", "shu", 9),
        ("大树", "da'shu", 10),
    ] {
        add(&mut lexicon, ZH, reading, text, count);
    }
    add(&mut lexicon, EN, "padding", "padding", 1_000_000_000);
    let id = |text| lexicon.find_word(text).unwrap();
    let mut grams = GramBuilder::new();
    grams.add(&[id("几棵"), id("大树")], 2).unwrap();
    grams
        .add(&[id("多种"), id("几棵"), id("大树")], 32)
        .unwrap();
    grams.add(&[id("棵"), id("树")], 2).unwrap();
    grams.add(&[id("几"), id("棵"), id("树")], 32).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let total = resources
        .lexicon()
        .words()
        .map(|w| w.count as f64)
        .sum::<f64>();
    let segmentation_total = total + resources.lexicon().len() as f64 + 0.5;
    let word = |count: f64| ((count + 1.0) / segmentation_total).ln() - std::f64::consts::LN_2;
    let scores = [
        word(100.0) + word(100.0),
        word(100.0) + word(90.0) + word(90.0),
        word(80.0) + word(80.0) + word(100.0),
    ];
    let cache = si_engine::PrecedingTextCache::default();
    for (k, temperature) in [(1, 4), (3, 1), (3, 4)] {
        let config = engine_config(
            &directory,
            &[
                ("segmentation_history_limit", &k.to_string()),
                ("segmentation_temperature", &temperature.to_string()),
            ],
        )?;
        let engine = CandidateEngine::new_with_config(&resources, None, config);
        let q = scores.map(|s| ((s - scores[0]) / temperature as f64).exp());
        let mass: f64 = if k == 1 { q[0] } else { q.iter().sum() };
        let weights = if k == 1 {
            [1.0, 0.0, 0.0]
        } else {
            q.map(|p| p / mass)
        };
        for preview in [false, true] {
            let convert = |cache| {
                engine.convert_with_cached_context(
                    "shu",
                    CHINESE,
                    preview,
                    &[],
                    ConversionPreferences::default(),
                    Some("最好多种几棵"),
                    ConversionOptions::default(),
                    cache,
                )
            };
            let rows = convert(None);
            assert_eq!(rows, convert(Some(&cache)));
            assert_eq!(rows, convert(Some(&cache)));
            assert_eq!(
                rows[0].text,
                if k == 3 && temperature == 4 {
                    "树"
                } else {
                    "数"
                }
            );
            for (text, count) in [("树", 10.0), ("数", 11.0), ("书", 9.0)] {
                let prior = count / total;
                // A/B have no matching record. C uses only the observed trigram,
                // capped before its joint-count confidence; no bigram is added.
                let a = prior;
                let b = prior;
                let c = if text == "树" {
                    prior * (5.0_f64 * 32.0 / 42.0).exp2()
                } else {
                    prior
                };
                let expected = (weights[0] * a + weights[1] * c + weights[2] * b).log2();
                let row = find(&rows, text, CandidateLanguage::Chinese, 3);
                assert!(
                    (row.score_bits.unwrap() + row.context_adjustment - expected).abs() < 1e-10,
                    "weighted probability for {text}"
                );
                assert_eq!(row.reranking_bonus, 0.0);
                assert_eq!(row.token_bonus, 0.0);
                assert_eq!(row.score_bits, Some(prior.log2()));
            }
            assert_eq!(rows.last().unwrap().text, "shu");
        }
    }
    Ok(())
}

#[test]
fn cached_context_matches_fresh_decoding_across_edits_languages_and_resources() -> io::Result<()> {
    let directory = Scratch::new()?;
    let mut lexicon = Lexicon::new();
    let want = add(&mut lexicon, EN, "want", "want", 100);
    let books = add(&mut lexicon, EN, "books", "books", 50);
    add(&mut lexicon, EN, "book", "book", 50);
    add(&mut lexicon, ZH, "shu", "树", 50);
    add(&mut lexicon, ZH, "shu", "书", 50);
    let mut grams = GramBuilder::new();
    grams.add(&[want, books], 100).unwrap();
    let resources = directory.resources(&mut lexicon, Some(grams))?;
    let cache = si_engine::PrecedingTextCache::default();
    for temperature in [1, 4] {
        let config = engine_config(
            &directory,
            &[("segmentation_temperature", &temperature.to_string())],
        )?;
        let engine =
            CandidateEngine::new_with_config(&resources, None, config).with_pinyin_correction(true);
        for preceding in [
            None,
            Some(""),
            Some("want "),
            Some("old. want "),
            Some("want"),
            Some("want。"),
            Some("🦉"),
            Some("书"),
        ] {
            for source in ["b", "bo", "boo", "books", "shu"] {
                for preview in [false, true] {
                    for languages in [
                        CHINESE,
                        ENGLISH,
                        BILINGUAL,
                        EnabledLanguages {
                            chinese: false,
                            english: false,
                        },
                    ] {
                        let options = ConversionOptions {
                            correction: Some(si_engine::CorrectionSensitivity::Conservative),
                            reranker: None,
                        };
                        let expected = engine.convert_with_options(
                            source,
                            languages,
                            preview,
                            &[],
                            ConversionPreferences::default(),
                            preceding,
                            options,
                        );
                        let actual = engine.convert_with_cached_context(
                            source,
                            languages,
                            preview,
                            &[],
                            ConversionPreferences::default(),
                            preceding,
                            options,
                            Some(&cache),
                        );
                        assert_eq!(actual, expected);
                    }
                }
            }
        }
    }
    let engines = [
        CandidateEngine::new(&resources, None),
        CandidateEngine::new_with_config(
            &resources,
            None,
            engine_config(&directory, &[("segmentation_history_limit", "1")])?,
        ),
    ];
    std::thread::scope(|scope| {
        for (index, (source, preceding)) in [
            ("books", "want "),
            ("shu", "书"),
            ("boo", "want "),
            ("books", ""),
        ]
        .into_iter()
        .enumerate()
        {
            let engine = &engines[index % engines.len()];
            let cache = &cache;
            scope.spawn(move || {
                let expected = engine.convert_with_context(
                    source,
                    BILINGUAL,
                    false,
                    &[],
                    ConversionPreferences::default(),
                    preceding,
                );
                for _ in 0..8 {
                    assert_eq!(
                        engine.convert_with_cached_context(
                            source,
                            BILINGUAL,
                            false,
                            &[],
                            ConversionPreferences::default(),
                            Some(preceding),
                            ConversionOptions::default(),
                            Some(cache)
                        ),
                        expected
                    );
                }
            });
        }
    });

    Ok(())
}
