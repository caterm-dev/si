use si_engine::segmentation::{SegmentKind, Segmenter};
use si_lexicon::{IndexId, Lexicon};

#[test]
fn maximum_matching_preserves_original_byte_ranges() {
    let mut lexicon = Lexicon::new();
    let short = lexicon.add_reading(IndexId(0), b"a", "𠼞", 10).unwrap();
    let long = lexicon
        .add_reading(IndexId(0), b"a'cha", "𠼞茶", 1)
        .unwrap();
    let english = lexicon
        .add_reading(IndexId(1), b"rustlang", "Rust-lang", 5)
        .unwrap();
    lexicon.add_reading(IndexId(0), b"chong", "重", 3).unwrap();
    lexicon.add_reading(IndexId(0), b"tong", "重", 9).unwrap();
    let segmenter = Segmenter::new(&lexicon);
    let text = "𠼞茶 Rust-lang。重未知";
    let parts: Vec<_> = segmenter
        .segment(text)
        .map(|part| (&text[part.range], part.kind))
        .collect();
    assert_eq!(
        parts,
        [
            ("𠼞茶", SegmentKind::Word(long)),
            (" ", SegmentKind::Space),
            ("Rust-lang", SegmentKind::Word(english)),
            ("。", SegmentKind::Boundary),
            ("重", SegmentKind::Ambiguous),
            ("未", SegmentKind::Unknown),
            ("知", SegmentKind::Unknown),
        ]
    );
    assert_eq!(
        segmenter.segment("𠼞").next().unwrap().kind,
        SegmentKind::Word(short)
    );
}

#[test]
fn pinyin_uses_selected_word_boundaries_and_preserves_spans() {
    let mut lexicon = Lexicon::new();
    lexicon.add_reading(IndexId(0), b"hang", "行", 1).unwrap();
    let xing = lexicon.add_reading(IndexId(0), b"xing", "行", 1).unwrap();
    let chongqing = lexicon
        .add_reading(IndexId(0), b"chong'qing", "重庆", 1)
        .unwrap();
    lexicon
        .add_reading(IndexId(0), b"zhong'qing", "重庆", 1)
        .unwrap();
    lexicon.add_reading(IndexId(0), b"chong", "重", 1).unwrap();
    lexicon.add_reading(IndexId(0), b"tong", "重", 1).unwrap();
    let segmenter = Segmenter::new(&lexicon);
    let text = "𠼞银行 PR 行走。重庆。重量";
    let actual: Vec<_> = segmenter
        .segment(text)
        .map(|segment| (&text[segment.range], segment.kind))
        .collect();
    assert_eq!(
        actual,
        [
            ("𠼞", SegmentKind::Unknown),
            ("银", SegmentKind::Unknown),
            ("行", SegmentKind::Word(xing)),
            (" ", SegmentKind::Space),
            ("PR", SegmentKind::NewEnglishWord),
            (" ", SegmentKind::Space),
            ("行", SegmentKind::Word(xing)),
            ("走", SegmentKind::Unknown),
            ("。", SegmentKind::Boundary),
            ("重庆", SegmentKind::Word(chongqing)),
            ("。", SegmentKind::Boundary),
            ("重", SegmentKind::Ambiguous),
            ("量", SegmentKind::Unknown),
        ]
    );
}

#[test]
fn consecutive_ascii_letters_stay_together() {
    let mut lexicon = Lexicon::new();
    lexicon.add_reading(IndexId(1), b"r", "R", 5).unwrap();
    lexicon.add_reading(IndexId(1), b"forty", "40", 5).unwrap();
    let revert = lexicon
        .add_reading(IndexId(1), b"revert", "revert", 5)
        .unwrap();
    let segmenter = Segmenter::new(&lexicon);
    let text = "PR R revert Revert P 404 7G";
    let parts: Vec<_> = segmenter
        .segment(text)
        .filter(|part| part.kind != SegmentKind::Space)
        .map(|part| (&text[part.range], part.kind))
        .collect();
    assert_eq!(
        parts,
        [
            ("PR", SegmentKind::NewEnglishWord),
            ("R", SegmentKind::Letter),
            ("revert", SegmentKind::Word(revert)),
            ("Revert", SegmentKind::NewEnglishWord),
            ("P", SegmentKind::Letter),
            ("404", SegmentKind::Number),
            ("7", SegmentKind::Number),
            ("G", SegmentKind::Letter),
        ]
    );
}
