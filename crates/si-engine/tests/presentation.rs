use std::borrow::Cow;

use si_engine::presentation::{self, Order, PresentationCandidate};
use si_engine::{CandidateLanguage, EnabledLanguages};

fn row<'a>(identity: &'a str, text: &'a str, score: f64) -> PresentationCandidate<'a> {
    PresentationCandidate {
        identity: Cow::Borrowed(identity),
        text,
        language: CandidateLanguage::English,
        consumed_bytes: None,
        lexical_tokens: 1,
        lexical_score: score,
        statistical_score: None,
        reranking_bonus: 0.0,
        preferred: false,
        remembered: false,
        personal: false,
        punctuation: false,
        completion: false,
        verbatim: false,
        corrected: false,
        chinese_sentence: false,
    }
}

fn indices(input: &str, candidates: &[PresentationCandidate<'_>], order: Order) -> Vec<usize> {
    presentation::merge(input, EnabledLanguages::default(), candidates, order)
        .iter()
        .map(|r| r.index)
        .collect()
}

#[test]
fn whole_then_prefix_span_then_fractional_score_with_policy_priorities() {
    let whole = row("en:whole", "whole", -100.25);
    let mut short = row("prefix1:en:short", "short", 50.0);
    short.consumed_bytes = Some(1);
    let mut long = row("prefix4:en:long", "long", -200.0);
    long.consumed_bytes = Some(4);
    let mut remembered = row("en:remembered", "remembered", -1000.0);
    remembered.remembered = true;
    let mut pin = row("zh-Hans:pin", "pin", -2000.0);
    pin.preferred = true;
    pin.personal = true;
    let rows = [short, long, whole, remembered, pin];
    for order in [Order::Statistical, Order::CoverageAdjusted] {
        assert_eq!(indices("synthetic", &rows, order), [4, 3, 2, 1, 0]);
    }
    let mut forbidden = rows[0].clone();
    forbidden.remembered = true;
    assert!(
        !presentation::merge(
            "synthetic",
            EnabledLanguages::default(),
            &[forbidden],
            Order::Statistical
        )[0]
        .remembered
    );
}

#[test]
fn identity_ties_preserve_swift_canonical_equivalence_and_winning_bytes() {
    let decomposed = row("en:e\u{301}", "e\u{301}", -10.0);
    let composed = row("en:é", "é", -9.5);
    let mut chinese = row("zh-Hans:é", "é", -9.5);
    chinese.language = CandidateLanguage::Chinese;
    let mut compatibility = row("en:\u{f900}", "\u{f900}", -11.0);
    compatibility.language = CandidateLanguage::English;
    let unified = row("en:\u{8c48}", "\u{8c48}", -10.0);
    let rows = [decomposed, composed, chinese, compatibility, unified];
    assert_eq!(indices("synthetic", &rows, Order::Statistical), [1, 2, 4]);
    assert_eq!(rows[1].text.as_bytes(), "é".as_bytes());
    assert_eq!(rows[0].text.as_bytes(), "e\u{301}".as_bytes());
    assert_eq!(
        indices(
            "synthetic",
            &[row("en:é", "é", 0.0), row("en:f", "f", 0.0)],
            Order::Statistical
        ),
        [1, 0]
    );
}

#[test]
fn a_regular_derivation_beats_a_correction_and_retains_direct_word_evidence() {
    let mut direct = row("zh-Hans:你好", "你好", -20.0);
    direct.language = CandidateLanguage::Chinese;
    let mut composed = direct.clone();
    composed.lexical_score = -10.0;
    composed.lexical_tokens = 2;
    composed.chinese_sentence = true;
    let mut correction = direct.clone();
    correction.lexical_score = 100.0;
    correction.corrected = true;
    let rows = [correction, direct, composed];
    let result = presentation::merge(
        "nihao",
        EnabledLanguages::default(),
        &rows,
        Order::Statistical,
    );
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].index, 2);
    assert_eq!(result[0].lexical_tokens, 1);
    assert!(!result[0].chinese_sentence);
}

#[test]
fn exact_literal_disabled_languages_and_empty_input_keep_their_contract() {
    let mut literal = row("literal:Original\0É", "Original\0É", 0.0);
    literal.language = CandidateLanguage::Literal;
    let mut chinese = row("zh-Hans:he", "he", 3.0);
    chinese.language = CandidateLanguage::Chinese;
    let mut mixed = row("zh-Hans+en:he", "he", 5.0);
    mixed.language = CandidateLanguage::Mixed;
    let rows = [literal, chinese, mixed, row("en:he", "he", 2.0)];
    for (chinese, english, expected) in [
        (false, false, vec![0]),
        (true, false, vec![1, 0]),
        (false, true, vec![3, 0]),
        (true, true, vec![2, 1, 3, 0]),
    ] {
        let actual: Vec<_> = presentation::merge(
            "Original\0É",
            EnabledLanguages { chinese, english },
            &rows,
            Order::Statistical,
        )
        .iter()
        .map(|r| r.index)
        .collect();
        assert_eq!(actual, expected);
    }
    assert!(indices("", &rows, Order::Statistical).is_empty());
}

#[test]
fn consumption_must_end_at_an_original_grapheme_boundary() {
    let mut split_scalar = row("prefix1:en:split", "split", 100.0);
    split_scalar.consumed_bytes = Some(1);
    let mut split_grapheme = split_scalar.clone();
    split_grapheme.consumed_bytes = Some(2);
    let mut valid = row("prefix3:en:whole", "whole", 0.0);
    valid.consumed_bytes = Some(3);
    // é is one scalar (two bytes); the combining mark extends its grapheme to four bytes.
    assert!(
        indices(
            "é\u{301}x",
            &[split_scalar.clone(), split_grapheme, valid],
            Order::Statistical
        )
        .is_empty()
    );
    split_scalar.consumed_bytes = Some(4);
    assert_eq!(
        indices("é\u{301}x", &[split_scalar], Order::Statistical),
        [0]
    );
}

#[test]
fn coverage_uses_only_consumed_spelling_and_never_literal_or_verbatim() {
    assert_eq!(
        presentation::coverage_bonus("lü'lu:lv'3", false, false),
        35.0
    );
    assert_eq!(presentation::coverage_bonus("LÜ'3", false, false), 15.0);
    assert_eq!(presentation::coverage_bonus("abc", true, false), 0.0);
    assert_eq!(presentation::coverage_bonus("abc", false, true), 0.0);
    let mut prefix = row("prefix4:en:word", "word", -20.0);
    prefix.consumed_bytes = Some(4);
    for input in ["wordtail", "wordanotherlongertail"] {
        assert_eq!(
            presentation::merge(
                input,
                EnabledLanguages::default(),
                &[prefix.clone()],
                Order::Statistical
            )[0]
            .presentation_score,
            0.0
        );
    }
}

#[test]
fn model_rewards_change_order_but_statistical_leader_is_independent() {
    let mut first = row("en:first", "first", -10.0);
    first.statistical_score = Some(-10.0);
    let mut second = row("en:second", "second", -10.5);
    second.statistical_score = Some(-10.5);
    second.reranking_bonus = 1.0;
    assert_eq!(
        indices(
            "synthetic",
            &[first.clone(), second.clone()],
            Order::Statistical
        ),
        [1, 0]
    );
    assert_eq!(presentation::statistical_leader(&[first, second]), Some(0));
    assert_eq!(presentation::statistical_leader(&[]), None);
}

#[test]
fn shortlist_preserves_ranked_head_nine_words_all_characters_and_literal() {
    let identities: Vec<_> = (0..60).map(|i| format!("id:{i}")).collect();
    let characters: Vec<_> = (0..35)
        .map(|i| char::from_u32(0x4e00 + i).unwrap().to_string())
        .collect();
    let mut rows: Vec<_> = (0..4)
        .map(|i| {
            let mut row = row(&identities[i], "constructed", 100.0 - i as f64);
            row.lexical_tokens = 3;
            row
        })
        .collect();
    for identity in &identities[4..19] {
        rows.push(row(identity, "word", 0.0));
    }
    for (identity, text) in identities[19..54].iter().zip(&characters) {
        let mut candidate = row(identity, text, 0.0);
        candidate.language = CandidateLanguage::Chinese;
        candidate.consumed_bytes = Some(1);
        rows.push(candidate);
    }
    let mut completion = row(&identities[54], "字", 0.0);
    completion.language = CandidateLanguage::Chinese;
    completion.completion = true;
    rows.push(completion);
    let mut literal = row(&identities[55], "synthetic", 0.0);
    literal.language = CandidateLanguage::Literal;
    rows.push(literal);
    let expected: Vec<_> = (0..13).chain(19..54).chain([55]).collect();
    assert_eq!(presentation::shortlist(&rows), expected);
}

#[test]
fn statistical_leaders_survive_a_model_promoted_head_without_reordering() {
    let ids: Vec<_> = (0..8).map(|i| format!("id:{i}")).collect();
    let rows: Vec<_> = ids
        .iter()
        .enumerate()
        .map(|(i, id)| {
            let mut row = row(id, "sentence", i as f64);
            row.lexical_tokens = 2;
            row.statistical_score = Some(i as f64);
            row
        })
        .collect();
    assert_eq!(presentation::shortlist(&rows), [0, 1, 2, 3, 6, 7]);
}

#[test]
fn punctuation_does_not_use_word_slots_and_completions_share_the_head() {
    let ids: Vec<_> = (0..50).map(|i| format!("id:{i}")).collect();
    let rows: Vec<_> = ids
        .iter()
        .enumerate()
        .map(|(i, id)| {
            let mut row = row(id, "punctuation", 0.0);
            if i < 4 {
                row.completion = true;
            } else if i < 14 {
                row.punctuation = true;
            }
            row
        })
        .collect();
    assert_eq!(presentation::shortlist(&rows), (0..23).collect::<Vec<_>>());
}

#[test]
fn shortlisting_retains_equivalent_derivations_of_a_pageable_character() {
    let ids = ["head:0", "head:1", "head:2", "head:3"];
    let mut rows: Vec<_> = ids
        .iter()
        .map(|id| {
            let mut row = row(id, "sentence", 0.0);
            row.lexical_tokens = 2;
            row
        })
        .collect();
    let mut completion = row("zh-Hans:é", "é", 0.0);
    completion.language = CandidateLanguage::Chinese;
    completion.completion = true;
    let mut character = row("zh-Hans:e\u{301}", "e\u{301}", 0.0);
    character.language = CandidateLanguage::Chinese;
    rows.extend([completion, character]);
    assert_eq!(presentation::shortlist(&rows), [0, 1, 2, 3, 4, 5]);
}
