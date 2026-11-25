use super::*;
use crate::resources::{EngineConfig, EngineResources};
use si_gram::GramBuilder;
use si_lexicon::{IndexId, Lexicon};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

struct Fixture {
    directory: PathBuf,
    resources: EngineResources,
}

impl Fixture {
    fn new(mut lexicon: Lexicon, grams: GramBuilder) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let directory = std::env::temp_dir().join(format!(
            "si-field-context-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&directory).unwrap();
        let lexicon_path = directory.join("base.silex");
        lexicon.save(&lexicon_path).unwrap();
        let mut grams = grams.finish().unwrap();
        grams.bind_lexicon(&lexicon).unwrap();
        let gram_path = directory.join("base.sigram");
        grams.save(&gram_path).unwrap();
        let resources = EngineResources::open(&lexicon_path, Some(&gram_path)).unwrap();
        Self {
            directory,
            resources,
        }
    }

    fn vocabulary() -> Lexicon {
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
            ("数", "shu", 1_000),
            ("大树", "da'shu", 10),
        ] {
            lexicon
                .add_reading(IndexId(0), reading.as_bytes(), text, count)
                .unwrap();
        }
        lexicon
            .add_reading(IndexId(1), b"padding", "padding", 1_000_000_000)
            .unwrap();
        lexicon
    }

    fn ambiguous() -> Self {
        let lexicon = Self::vocabulary();
        let id = |text| lexicon.find_word(text).unwrap();
        let mut grams = GramBuilder::new();
        grams.add(&[id("几棵"), id("大树")], 2).unwrap();
        grams.add(&[id("棵"), id("树")], 2).unwrap();
        grams.add(&[id("几"), id("棵"), id("树")], 32).unwrap();
        Self::new(lexicon, grams)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[test]
fn temperature_weights_use_only_the_best_path_for_each_distinct_effective_history() {
    let fixture = Fixture::ambiguous();
    let config = EngineConfig::default();
    assert_eq!(config.field_context.segmentation_history_limit, 3);
    assert_eq!(config.field_context.segmentation_temperature, 4.0);
    let lexicon = fixture.resources.lexicon();
    let scoring = Scoring::new(&fixture.resources, None, config);
    let context = Context::new(lexicon, None, config.field_context);
    let field = context.history(Some("最好多种几棵"), &scoring, None);
    assert_eq!(field.base.len(), 3);
    let total = 0.5 + lexicon.words().map(|w| w.count as f64 + 1.0).sum::<f64>();
    let score = |words: &[&str]| {
        words
            .iter()
            .map(|text| {
                let count = lexicon.words_for_text(text).map(|w| w.count).sum::<u64>();
                ((count as f64 + 1.0) / total).ln() - std::f64::consts::LN_2
            })
            .sum::<f64>()
    };
    let words: [&[&str]; 3] = [&["多种", "几棵"], &["几", "棵"], &["种", "几棵"]];
    let scores = [
        score(&["多种", "几棵"]),
        score(&["多种", "几", "棵"]),
        score(&["多", "种", "几棵"]),
    ];
    let q = scores.map(|s| ((s - scores[0]) / 4.0).exp());
    let mass: f64 = q.iter().sum();
    for ((row, words), q) in field.base.iter().zip(words).zip(q) {
        let mut expected = History::default();
        for text in words {
            expected = scoring.extend_history(
                expected,
                Language::Chinese,
                WordIds {
                    base: lexicon.find_word(text),
                    user: None,
                },
            );
        }
        assert_eq!(row.history, scoring.field_history(expected, false));
        assert!((row.weight - q / mass).abs() < 1e-12);
    }
    assert!(field.user.is_empty());
}

#[test]
fn cache_reuses_exact_fragments_but_rejects_other_contexts_configs_and_resource_owners() {
    let fixture = Fixture::ambiguous();
    let config = EngineConfig::default();
    let scoring = Scoring::new(&fixture.resources, None, config);
    let context = Context::new(fixture.resources.lexicon(), None, config.field_context);
    let cache = PrecedingTextCache::default();
    let first = context.history(Some("最好多种几棵"), &scoring, Some(&cache));
    let reused = context.history(Some("上一句。最好多种几棵"), &scoring, Some(&cache));
    assert!(Arc::ptr_eq(&first, &reused));
    assert_eq!(first, context.history(Some("最好多种几棵"), &scoring, None));
    let changed = context.history(Some("几棵"), &scoring, Some(&cache));
    assert!(!Arc::ptr_eq(&first, &changed));
    let unknown = context.history(None, &scoring, Some(&cache));
    assert!(unknown.base.is_empty() && unknown.user.is_empty());
    let mut single = config;
    single.field_context.segmentation_history_limit = 1;
    let other = Context::new(fixture.resources.lexicon(), None, single.field_context);
    let prepared = other.history(Some("几棵"), &scoring, Some(&cache));
    assert!(!Arc::ptr_eq(&prepared, &changed));
    assert_eq!(prepared.base.len(), 1);
    let replacement = Fixture::ambiguous();
    let other = Context::new(replacement.resources.lexicon(), None, config.field_context);
    let scoring = Scoring::new(&replacement.resources, None, config);
    let replaced = other.history(Some("几棵"), &scoring, Some(&cache));
    assert!(!Arc::ptr_eq(&replaced, &prepared));
    assert_eq!(replaced, other.history(Some("几棵"), &scoring, None));
}

#[test]
fn shared_cache_is_safe_for_concurrent_transient_queries() {
    let fixture = Fixture::ambiguous();
    let config = EngineConfig::default();
    let scoring = Scoring::new(&fixture.resources, None, config);
    let context = Context::new(fixture.resources.lexicon(), None, config.field_context);
    let cache = PrecedingTextCache::default();
    std::thread::scope(|scope| {
        for text in ["最好多种几棵", "几棵", "多种几", "。 "] {
            let (context, scoring, cache) = (&context, &scoring, &cache);
            scope.spawn(move || {
                let expected = context.history(Some(text), scoring, None);
                for _ in 0..12 {
                    assert_eq!(context.history(Some(text), scoring, Some(cache)), expected);
                }
            });
        }
    });
}

#[test]
fn base_and_user_deduplicate_by_their_own_saved_gram_orders() {
    let base = Fixture::ambiguous();
    let lexicon = Fixture::vocabulary();
    let id = |text| lexicon.find_word(text).unwrap();
    let mut grams = GramBuilder::new();
    grams
        .add(&[id("最好"), id("多种"), id("几棵"), id("树"), id("数")], 2)
        .unwrap();
    let user = Fixture::new(lexicon, grams);
    let config = EngineConfig::default();
    let scoring = Scoring::new(&base.resources, Some(&user.resources), config);
    let context = Context::new(
        base.resources.lexicon(),
        Some(user.resources.lexicon()),
        config.field_context,
    );
    let field = context.history(Some("最好多种几棵"), &scoring, None);
    let history = |words: &[&str], user_only| {
        let mut h = History::default();
        for text in words {
            h = scoring.extend_history(
                h,
                Language::Chinese,
                WordIds {
                    base: base.resources.lexicon().find_word(text),
                    user: user.resources.lexicon().find_word(text),
                },
            );
        }
        scoring.field_history(h, user_only)
    };
    let whole = ["最好", "多种", "几棵"];
    let split = ["最", "好", "多种", "几棵"];
    assert_eq!(history(&whole, false), history(&split, false));
    assert_ne!(history(&whole, true), history(&split, true));
    assert_eq!(field.user[0].history, history(&whole, true));
    assert_eq!(field.user[1].history, history(&split, true));
    assert_eq!(field.base.len(), 3);
    assert_eq!(field.user.len(), 3);
}

#[test]
fn exhausted_search_uses_the_complete_single_best_history_and_large_keys_are_not_retained() {
    let mut lexicon = Lexicon::new();
    for length in 1..=7 {
        let reading = std::iter::repeat_n("jia", length)
            .collect::<Vec<_>>()
            .join("'");
        lexicon
            .add_reading(IndexId(0), reading.as_bytes(), &"甲".repeat(length), 100)
            .unwrap();
    }
    let id = lexicon.find_word("甲").unwrap();
    let mut grams = GramBuilder::new();
    grams.add(&[id; 5], 1).unwrap();
    let fixture = Fixture::new(lexicon, grams);
    let config = EngineConfig::default();
    let scoring = Scoring::new(&fixture.resources, None, config);
    let context = Context::new(fixture.resources.lexicon(), None, config.field_context);
    let cache = PrecedingTextCache::default();
    let dense = "甲".repeat(96);
    let field = context.history(Some(&dense), &scoring, Some(&cache));
    let mut single = config.field_context;
    single.segmentation_history_limit = 1;
    let ordinary = Context::new(fixture.resources.lexicon(), None, single);
    assert_eq!(field.base.len(), 1);
    assert_eq!(field, ordinary.history(Some(&dense), &scoring, None));
    let large = "z".repeat(MAX_CACHE_BYTES + 1);
    context.history(Some(&large), &scoring, Some(&cache));
    let stored = cache.0.lock().unwrap();
    assert_eq!(stored.as_ref().unwrap().fragment, dense);
}
