use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

use si_engine::IndexId;
use si_engine::resources::EngineResources;

#[test]
fn corpus_progress_is_cumulative_across_files_and_keeps_stdout_for_the_summary() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("seed.csv", "text,reading,weight\n甲,jia,1\n乙,yi,1\n")?;
    scratch.run(&["lexicon", "build", "seed.silex", "0", "seed.csv"])?;
    scratch.write("first.txt", "\u{feff}甲乙\r\n\r\n")?;
    scratch.write("second.txt", "乙陌")?;
    scratch.write("words.sigram.lock", "")?;

    for (args, final_summary) in [
        (
            &[
                "corpus",
                "ingest",
                "seed.silex",
                "words.sigram",
                "first.txt",
                "second.txt",
            ][..],
            "Imported 2 paragraphs with 3 matched words",
        ),
        (
            &[
                "corpus",
                "build",
                "--han",
                "seed.silex",
                "progress.sigram",
                "first.txt",
                "second.txt",
            ][..],
            "Read 2 sentences and skipped 1 unknown tokens",
        ),
    ] {
        let output = scratch.run(args)?;
        let progress = String::from_utf8_lossy(&output.stderr);
        let lines: Vec<_> = progress.lines().collect();
        assert_eq!(
            lines,
            [
                "Preparing to import 2 corpus files.",
                "Reading corpus file 1/2 (0.0%) | 0 records processed | 0 matched tokens | 0 unknown | 0 unresolved",
                "Finished corpus file 1/2 (100.0%) | 1 records processed | 2 matched tokens | 0 unknown | 0 unresolved",
                "Reading corpus file 2/2 (0.0%) | 1 records processed | 2 matched tokens | 0 unknown | 0 unresolved",
                "Finished corpus file 2/2 (100.0%) | 2 records processed | 3 matched tokens | 1 unknown | 0 unresolved",
                "Building gram tables.",
                "Saving corpus results.",
            ]
        );
        let summary = String::from_utf8_lossy(&output.stdout);
        assert!(summary.contains(final_summary));
        assert!(!summary.contains("corpus file"));
    }
    Ok(())
}

#[test]
fn learning_force_count_accepts_multiple_frequent_continuations() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "seed.csv",
        concat!(
            "text,reading,weight\n在,zai,1\n这,zhe,1\n那,na,1\n外,wai,1\n",
            "深,shen,1\n海,hai,1\n探,tan,1\n测,ce,1\n",
            "𠼞,a,1\n茶,cha,1\n"
        ),
    )?;
    let corpus = [
        "在这\n".repeat(7),
        "在那\n".repeat(6),
        "在外\n".repeat(5),
        "深海探测\n".repeat(6),
        "𠼞茶\n".repeat(6),
    ]
    .concat();
    scratch.write("corpus.txt", &corpus)?;
    scratch.run(&["lexicon", "build", "seed.silex", "0", "seed.csv"])?;
    scratch.run(&[
        "corpus",
        "build",
        "--han",
        "seed.silex",
        "chars.sigram",
        "corpus.txt",
    ])?;
    scratch.learning_config(0, [9; 3], [50; 3])?;
    let command = [
        "lexicon",
        "learn",
        "seed.silex",
        "chars.sigram",
        "learning.conf",
    ];
    let path = scratch.0.join("seed.silex");
    let before = fs::read(&path)?;
    scratch.run(&command)?;
    assert_eq!(fs::read(&path)?, before);

    let config = fs::read_to_string(scratch.0.join("learning.conf"))?;
    scratch.write("learning.conf", &format!("{config}force_count = 5\n"))?;
    scratch.run(&command)?;
    let resources = EngineResources::open(&path, None)?;
    let lexicon = resources.lexicon();
    for (key, text, count) in [
        ("zai'zhe", "在这", 7),
        ("zai'na", "在那", 6),
        ("shen'hai'tan", "深海探", 6),
        ("shen'hai'tan'ce", "深海探测", 6),
    ] {
        let word = lexicon.exact(IndexId(0), key.as_bytes()).next().unwrap();
        assert_eq!((word.text, word.count), (text, count));
    }
    assert!(lexicon.find_word("在外").is_none());
    assert!(lexicon.find_word("𠼞茶").is_none());
    assert_eq!(
        fs::read_to_string(scratch.0.join("seed.silex.review-1.csv"))?,
        "text,reading,weight\n𠼞茶,,6\n"
    );
    Ok(())
}

#[test]
fn learning_requires_both_count_and_same_order_prefix_share() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "seed.csv",
        concat!(
            "text,reading,weight\n重,chong,1\n重,zhong,1\n庆,qing,1\n心,xin,1\n力,li,1\n",
            "江,jiang,1\n海,hai,1\n山,shan,1\n水,shui,1\n白,bai,1\n云,yun,1\n",
            "深,shen,1\n探,tan,1\n测,ce,1\n明,ming,1\n查,cha,1\n观,guan,1\n",
            "青,qing,1\n绿,lv,1\n树,shu,1\n"
        ),
    )?;
    let mut corpus = String::new();
    for (text, count) in [
        ("重庆\n", 6),
        ("重心\n", 4),
        ("重力\n", 2),
        ("江海\n", 4),
        ("江山\n", 3),
        ("江水\n", 2),
        ("白云\n", 3),
        ("深海探测\n", 6),
        ("深海探明\n", 4),
        ("深海探查\n", 2),
        ("深海观测\n", 3),
        ("青山绿水\n", 5),
        ("青山绿树\n", 3),
    ] {
        corpus.push_str(&text.repeat(count));
    }
    scratch.write("corpus.txt", &corpus)?;
    scratch.run(&["lexicon", "build", "seed.silex", "5", "seed.csv"])?;
    scratch.run(&[
        "corpus",
        "build",
        "--han",
        "seed.silex",
        "chars.sigram",
        "corpus.txt",
    ])?;
    scratch.learning_config(5, [4, 6, 5], [50, 80, 60])?;
    let learn = [
        "lexicon",
        "learn",
        "seed.silex",
        "chars.sigram",
        "learning.conf",
    ];
    let gram_path = scratch.0.join("chars.sigram");
    let gram_bytes = fs::read(&gram_path)?;
    scratch.run(&learn)?;

    let path = scratch.0.join("seed.silex");
    let resources = EngineResources::open(&path, None)?;
    let lexicon = resources.lexicon();
    assert!(!scratch.0.join("seed.silex.review-1.csv").exists());
    for text in ["重心", "江海", "白云", "海探测", "深海探测"] {
        assert!(lexicon.find_word(text).is_none(), "{text}");
    }
    for (key, expected_count) in [
        ("chong'qing", 6),
        ("shen'hai'tan", 12),
        ("qing'shan'lv'shui", 5),
    ] {
        let word = lexicon.exact(IndexId(5), key.as_bytes()).next().unwrap();
        assert_eq!(word.count, expected_count);
    }
    assert_eq!(fs::read(&gram_path)?, gram_bytes);

    let valid = fs::read_to_string(scratch.0.join("learning.conf"))?;
    let learned = fs::read(&path)?;
    for (invalid, expected) in [
        (
            valid.replace("min_prefix_percent_2 = 50", "min_prefix_percent_2 = 101"),
            "min_prefix_percent_2",
        ),
        (
            valid.replace("min_count_3 = 6\n", ""),
            "missing learning setting min_count_3",
        ),
        (
            format!("{valid}pinyin_index = 5\n"),
            "duplicate learning setting",
        ),
        (
            format!("{valid}min_count_5 = 1\n"),
            "unknown learning setting",
        ),
    ] {
        scratch.write("learning.conf", &invalid)?;
        let rejected = scratch.command(&learn).output()?;
        assert!(!rejected.status.success());
        assert!(String::from_utf8_lossy(&rejected.stderr).contains(expected));
        assert_eq!(fs::read(&path)?, learned);
        assert!(!scratch.0.join("seed.silex.review-1.csv").exists());
    }
    Ok(())
}

#[test]
fn paragraph_ingest_counts_longest_words_and_grams_together() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "chinese.csv",
        concat!(
            "text,reading,weight\n深,shen,20\n海,hai,30\n深海,shen'hai,10\n",
            "探测,tan'ce,40\n图,tu,0\n重,chong,6\n重,tong,7\n"
        ),
    )?;
    scratch.write("english.csv", "text,reading,weight\nRust,rust,3\n")?;
    scratch.run(&[
        "lexicon",
        "build",
        "seed.silex",
        "0",
        "chinese.csv",
        "1",
        "english.csv",
    ])?;
    scratch.write(
        "paragraphs.txt",
        "深海探测图Rust\n深海探测 Rust\n\n深海。Rust\n深海重Rust\n深海陌Rust\n深海\nRust\n陌重。陌\n",
    )?;
    let seed_path = scratch.0.join("seed.silex");
    let seed = EngineResources::open(&seed_path, None)?;
    let first = [
        "corpus",
        "ingest",
        "seed.silex",
        "words.sigram",
        "paragraphs.txt",
    ];
    let output = scratch.run(&first)?;
    let summary = String::from_utf8_lossy(&output.stdout);
    assert!(summary.contains("Imported 8 paragraphs with 15 matched words"));
    assert!(summary.contains("Skipped 3 unknown characters and 2 unresolved matches"));
    assert!(
        summary.contains("Exported 2 entries for manual review")
            && summary.contains("words.sigram.review.csv")
    );
    let header = "kind,text,count,candidate_readings,first_file,first_line\n";
    let review_path = scratch.0.join("words.sigram.review.csv");
    let review = fs::read_to_string(&review_path)?;
    assert_eq!(
        review,
        format!(
            "{header}unmatched,陌,3,,paragraphs.txt,6\nunresolved,重,2,0:chong | 0:tong,paragraphs.txt,5\n"
        ),
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&review_path)?.permissions().mode() & 0o077, 0);
    }

    let grams_path = scratch.0.join("words.sigram");
    let updated = EngineResources::open(&seed_path, Some(&grams_path))?;
    let lexicon = updated.lexicon();
    let grams = updated.grams().unwrap();
    let [sea, detect, map, rust] =
        ["深海", "探测", "图", "Rust"].map(|text| seed.lexicon().find_word(text).unwrap());
    for (word, count) in [(sea, 16), (detect, 42), (map, 1), (rust, 9)] {
        assert_eq!(lexicon.word(word).unwrap().count, count);
    }
    for text in ["深", "海"] {
        let id = seed.lexicon().find_word(text).unwrap();
        assert_eq!(lexicon.word(id), seed.lexicon().word(id));
    }
    assert!(
        lexicon
            .words_for_text("重")
            .eq(seed.lexicon().words_for_text("重"))
    );
    assert!(lexicon.find_word("陌").is_none());
    assert_eq!(grams.count(&[sea, detect]), Some(2));
    assert_eq!(grams.count(&[detect, map, rust]), Some(1));
    assert_eq!(grams.count(&[sea, detect, rust]), Some(1));
    assert_eq!(grams.count(&[sea, detect, map, rust]), Some(1));
    assert_eq!(grams.count(&[sea, rust]), None);
    scratch.write("later.txt", "深海探测图Rust\n")?;
    scratch.run(&[
        "corpus",
        "ingest",
        "seed.silex",
        "words.sigram",
        "later.txt",
    ])?;
    let second = EngineResources::open(&seed_path, Some(&grams_path))?;
    assert_eq!(fs::read_to_string(&review_path)?, header);
    assert_eq!(second.lexicon().find_word("深海"), Some(sea));
    assert_eq!(second.lexicon().word(sea).unwrap().count, 17);
    assert_eq!(second.grams().unwrap().count(&[sea, detect]), Some(3));
    assert_eq!(
        second.grams().unwrap().count(&[sea, detect, map, rust]),
        Some(2)
    );
    assert!(fs::read_dir(&scratch.0)?.all(|entry| entry.is_ok_and(|entry| entry.path().is_file())));
    Ok(())
}

#[test]
fn paragraph_ingest_uses_contextual_pinyin_in_word_and_gram_counts() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "words.csv",
        "text,reading,weight\n银,yin,0\n行,hang,10\n行,xing,20\n走,zou,0\n",
    )?;
    scratch.run(&["lexicon", "build", "seed.silex", "0", "words.csv"])?;
    scratch.write("paragraphs.txt", "银行。行走。银行\n")?;
    let output = scratch.run(&[
        "corpus",
        "ingest",
        "seed.silex",
        "words.sigram",
        "paragraphs.txt",
    ])?;
    assert!(String::from_utf8_lossy(&output.stdout).contains("and 0 unresolved matches"));
    let resources = EngineResources::open(
        &scratch.0.join("seed.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    let lexicon = resources.lexicon();
    let yin = lexicon.find_word("银").unwrap();
    let zou = lexicon.find_word("走").unwrap();
    let hang = lexicon.find_reading(IndexId(0), b"hang", "行").unwrap();
    let xing = lexicon.find_reading(IndexId(0), b"xing", "行").unwrap();
    assert_eq!(lexicon.word(hang).unwrap().count, 12);
    assert_eq!(lexicon.word(xing).unwrap().count, 21);
    let grams = resources.grams().unwrap();
    assert_eq!(grams.count(&[yin, hang]), Some(2));
    assert_eq!(grams.count(&[xing, zou]), Some(1));
    assert_eq!(grams.count(&[yin, xing]), None);
    assert_eq!(grams.count(&[hang, zou]), None);
    Ok(())
}

#[test]
fn paragraph_ingest_adds_complete_english_words_to_counts_and_grams() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "chinese.csv",
        "text,reading,weight\n完,wan,1\n说明,shuo'ming,1\n",
    )?;
    scratch.write("english.csv", "text,reading,weight\nrevert,revert,2\n")?;
    scratch.run(&[
        "lexicon",
        "build",
        "seed.silex",
        "0",
        "chinese.csv",
        "1",
        "english.csv",
    ])?;
    scratch.write("paragraphs.txt", "revert完PR说明\nPR 说明\nR。PR\n")?;
    let output = scratch.run(&[
        "corpus",
        "ingest",
        "seed.silex",
        "words.sigram",
        "paragraphs.txt",
    ])?;
    let summary = String::from_utf8_lossy(&output.stdout);
    assert!(summary.contains("Skipped 0 unknown characters"));
    assert!(summary.contains("Added 1 new English words"));
    assert!(summary.contains("Counted 1 <char> and 0 <num> placeholders"));

    let first_lexicon = scratch.0.join("seed.silex");
    let grams_path = scratch.0.join("words.sigram");
    let updated = EngineResources::open(&first_lexicon, Some(&grams_path))?;
    let lexicon = updated.lexicon();
    let [revert, wan, pr, explain] =
        ["revert", "完", "PR", "说明"].map(|text| lexicon.find_word(text).unwrap());
    assert_eq!(lexicon.find_reading(IndexId(1), b"pr", "PR"), Some(pr));
    assert_eq!(lexicon.word(pr).unwrap().count, 3);
    assert!(lexicon.find_word("P").is_none());
    assert!(lexicon.find_word("R").is_none());
    let grams = updated.grams().unwrap();
    assert_eq!(grams.count(&[pr, explain]), Some(2));
    assert_eq!(grams.count(&[revert, wan, pr, explain]), Some(1));

    scratch.write("more.txt", "PR完\n")?;
    let output = scratch.run(&["corpus", "ingest", "seed.silex", "words.sigram", "more.txt"])?;
    assert!(String::from_utf8_lossy(&output.stdout).contains("Added 0 new English words"));
    let next = EngineResources::open(&first_lexicon, Some(&grams_path))?;
    assert_eq!(next.lexicon().find_word("PR"), Some(pr));
    assert_eq!(next.lexicon().word(pr).unwrap().count, 4);
    assert_eq!(next.grams().unwrap().count(&[pr, wan]), Some(1));
    Ok(())
}

#[test]
fn paragraph_ingest_counts_letter_and_number_placeholders_only_in_grams() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "chinese.csv",
        "text,reading,weight\n银,yin,0\n行,hang,0\n行,xing,0\n走,zou,0\n",
    )?;
    scratch.write(
        "english.csv",
        "text,reading,weight\nA,a,3\n404,fourzerofour,5\nPR,pr,0\n",
    )?;
    scratch.run(&[
        "lexicon",
        "build",
        "seed.silex",
        "0",
        "chinese.csv",
        "1",
        "english.csv",
    ])?;
    scratch.write("paragraphs.txt", "银行 404 PR A 行走\nG 2 PR\n")?;
    let output = scratch.run(&[
        "corpus",
        "ingest",
        "seed.silex",
        "words.sigram",
        "paragraphs.txt",
    ])?;
    let summary = String::from_utf8_lossy(&output.stdout);
    assert!(summary.contains("Skipped 0 unknown characters and 0 unresolved matches"));
    assert!(summary.contains("Counted 2 <char> and 2 <num> placeholders"));

    let resources = EngineResources::open(
        &scratch.0.join("seed.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    let lexicon = resources.lexicon();
    let [letter, number, pr] =
        ["<char>", "<num>", "PR"].map(|text| lexicon.find_word(text).unwrap());
    let hang = lexicon.find_reading(IndexId(0), b"hang", "行").unwrap();
    let xing = lexicon.find_reading(IndexId(0), b"xing", "行").unwrap();
    for placeholder in [letter, number] {
        let word = lexicon.word(placeholder).unwrap();
        assert_eq!(word.count, 0);
        assert!(word.reading.is_none());
        assert!(!lexicon.lookup_keys().any(|(_, id)| id == placeholder));
    }
    assert_eq!(
        lexicon.word(lexicon.find_word("A").unwrap()).unwrap().count,
        3
    );
    assert_eq!(
        lexicon
            .word(lexicon.find_word("404").unwrap())
            .unwrap()
            .count,
        5
    );
    assert!(lexicon.find_word("G").is_none());
    assert!(lexicon.find_word("2").is_none());
    assert_eq!(lexicon.word(pr).unwrap().count, 2);
    let grams = resources.grams().unwrap();
    assert_eq!(grams.count(&[number, pr]), Some(2));
    assert_eq!(grams.count(&[letter, xing]), Some(1));
    assert_eq!(grams.count(&[hang, number, pr, letter]), Some(1));
    assert_eq!(grams.count(&[letter, number, pr]), Some(1));

    scratch.write("more.txt", "X 13 PR\n")?;
    scratch.run(&["corpus", "ingest", "seed.silex", "words.sigram", "more.txt"])?;
    let next = EngineResources::open(
        &scratch.0.join("seed.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    assert_eq!(next.lexicon().len(), lexicon.len());
    assert_eq!(next.lexicon().find_word("<char>"), Some(letter));
    assert_eq!(next.lexicon().find_word("<num>"), Some(number));
    assert_eq!(next.grams().unwrap().count(&[letter, number, pr]), Some(2));
    Ok(())
}

#[test]
fn paragraph_ingest_creates_missing_snapshots_and_protects_existing_gram_ids() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("paragraphs.txt", "Rust engine。甲\n")?;
    let ingest = [
        "corpus",
        "ingest",
        "lexicons/main.silex",
        "models/words.sigram",
        "paragraphs.txt",
    ];
    scratch.run(&ingest)?;
    let lexicon_path = scratch.0.join("lexicons/main.silex");
    let grams_path = scratch.0.join("models/words.sigram");
    let saved = EngineResources::open(&lexicon_path, Some(&grams_path))?;
    let [rust, engine] = ["Rust", "engine"].map(|word| saved.lexicon().find_word(word).unwrap());
    assert_eq!(saved.lexicon().word(rust).unwrap().count, 1);
    assert!(saved.lexicon().find_word("甲").is_none());
    assert_eq!(saved.grams().unwrap().count(&[rust, engine]), Some(1));
    assert!(
        fs::read_to_string(scratch.0.join("models/words.sigram.review.csv"))?
            .contains("unmatched,甲,1")
    );

    let before = fs::read(&grams_path)?;
    let failed = scratch
        .command(&[
            "corpus",
            "ingest",
            "lexicons/missing.silex",
            "models/words.sigram",
            "paragraphs.txt",
        ])
        .output()?;
    assert!(!failed.status.success());
    assert!(String::from_utf8_lossy(&failed.stderr).contains("compatible lexicon"));
    assert!(!scratch.0.join("lexicons/missing.silex").exists());
    assert_eq!(fs::read(&grams_path)?, before);

    scratch.run(&ingest)?;
    let repeated = EngineResources::open(&lexicon_path, Some(&grams_path))?;
    assert_eq!(repeated.lexicon().word(rust).unwrap().count, 2);
    assert_eq!(repeated.grams().unwrap().count(&[rust, engine]), Some(2));
    Ok(())
}

#[test]
fn failed_paragraph_ingest_does_not_publish_either_snapshot() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "seed.csv",
        "text,reading,weight\n甲,jia,18446744073709551615\n乙,yi,1\n丙,bing,1\n",
    )?;
    scratch.run(&["lexicon", "build", "seed.silex", "0", "seed.csv"])?;
    scratch.write("known.txt", "乙丙\n")?;
    scratch.write("overflow.txt", "甲乙\n")?;
    fs::write(scratch.0.join("malformed.txt"), b"\xff\n")?;
    scratch.run(&[
        "corpus",
        "ingest",
        "seed.silex",
        "words.sigram",
        "known.txt",
    ])?;
    scratch.run(&[
        "corpus",
        "build",
        "--han",
        "seed.silex",
        "characters.sigram",
        "known.txt",
    ])?;
    let seed_path = scratch.0.join("seed.silex");
    let grams_path = scratch.0.join("words.sigram");
    let review_path = scratch.0.join("words.sigram.review.csv");
    let before = fs::read(&seed_path)?;
    let grams_before = fs::read(&grams_path)?;
    let review_before = fs::read(&review_path)?;
    for source in ["overflow.txt", "malformed.txt"] {
        let failed = scratch
            .command(&[
                "corpus",
                "ingest",
                "seed.silex",
                "words.sigram",
                "known.txt",
                source,
            ])
            .output()?;
        assert!(!failed.status.success());
        assert_eq!(fs::read(&seed_path)?, before);
        assert_eq!(fs::read(&grams_path)?, grams_before);
        assert_eq!(fs::read(&review_path)?, review_before);
    }
    let characters = scratch.0.join("characters.sigram");
    let characters_before = fs::read(&characters)?;
    let failed = scratch
        .command(&[
            "corpus",
            "ingest",
            "seed.silex",
            "characters.sigram",
            "known.txt",
        ])
        .output()?;
    assert!(!failed.status.success());
    assert!(String::from_utf8_lossy(&failed.stderr).contains("surface character grams"));
    assert_eq!(fs::read(&characters)?, characters_before);
    assert_eq!(fs::read(&seed_path)?, before);
    Ok(())
}

#[test]
fn snapshot_csv_round_trip_preserves_ids_keys_and_gram_compatibility() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    // Word rows and aliases may appear in any order in a reviewed CSV.
    scratch.write(
        "fixture.csv",
        concat!(
            "kind,id,text,weight,index,reading,key_hex\n",
            "alias,0,,,4294967295,,00ff\n",
            "word,4,裸,9,,,\n",
            "word,2,庆,120,0,qing,\n",
            "word,0,重,7,0,chong,\n",
            "word,3,\"a, \"\"title\"\"\r\n第二行\",18446744073709551615,1,,0080\n",
            "word,1,重,3,0,zhong,\n",
            "alias,0,,,2,cz,\n",
            "alias,4,,,2,luo,\n",
        ),
    )?;
    scratch.run(&["lexicon", "restore", "fixture.csv", "original.silex"])?;
    scratch.write("tokens.txt", "重|0|chong 庆 重|0|zhong\n")?;
    scratch.run(&[
        "corpus",
        "build",
        "original.silex",
        "words.sigram",
        "tokens.txt",
    ])?;
    scratch.run(&["lexicon", "export", "original.silex", "original.silex.csv"])?;
    scratch.run(&["lexicon", "restore", "original.silex.csv", "restored.silex"])?;

    let original_path = scratch.0.join("original.silex");
    let restored_path = scratch.0.join("restored.silex");
    let grams_path = scratch.0.join("words.sigram");
    let original = EngineResources::open(&original_path, Some(&grams_path))?;
    let restored = EngineResources::open(&restored_path, Some(&grams_path))?;
    let lexicon = restored.lexicon();
    assert!(original.lexicon().words().eq(lexicon.words()));
    assert!(original.lexicon().lookup_keys().eq(lexicon.lookup_keys()));
    assert_eq!(fs::read(restored_path)?, fs::read(original_path)?);
    let chong = lexicon.exact(IndexId(0), b"chong").next().unwrap();
    let zhong = lexicon.exact(IndexId(0), b"zhong").next().unwrap();
    let qing = lexicon.exact(IndexId(0), b"qing").next().unwrap();
    assert_eq!((chong.id.0, zhong.id.0, qing.id.0), (0, 1, 2));
    assert_eq!((chong.count, zhong.count, qing.count), (7, 3, 120));
    assert_eq!(
        restored
            .grams()
            .unwrap()
            .count(&[chong.id, qing.id, zhong.id]),
        Some(1)
    );
    let title = lexicon.exact(IndexId(1), b"\0\x80").next().unwrap();
    assert_eq!(title.text, "a, \"title\"\r\n第二行");
    assert_eq!(title.count, u64::MAX);
    assert_eq!(
        lexicon.exact(IndexId(u32::MAX), b"\0\xff").next(),
        Some(chong)
    );
    let surface = lexicon.exact(IndexId(2), b"luo").next().unwrap();
    assert_eq!(surface.id.0, 4);
    assert_eq!(surface.reading, None);

    let exported_path = scratch.0.join("original.silex.csv");
    let exported = fs::read_to_string(&exported_path)?;
    assert!(exported.contains("word,0,重,7,0,chong,\n"));
    assert!(exported.contains("word,1,重,3,0,zhong,\n"));
    assert!(exported.contains("alias,0,,,2,cz,\n"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&exported_path)?.permissions().mode() & 0o077,
            0
        );
    }
    let repeat_export = scratch
        .command(&["lexicon", "export", "original.silex", "original.silex.csv"])
        .output()?;
    assert!(!repeat_export.status.success());
    assert_eq!(fs::read_to_string(exported_path)?, exported);

    scratch.write("increment.csv", "text,reading,weight\n深,shen,1\n")?;
    scratch.run(&["lexicon", "add", "restored.silex", "0", "increment.csv"])?;
    let extended = EngineResources::open(&scratch.0.join("restored.silex"), Some(&grams_path))?;
    assert_eq!(extended.lexicon().find_word("深").unwrap().0, 5);
    assert_eq!(extended.lexicon().find_word("庆"), Some(qing.id));
    Ok(())
}

#[test]
fn restore_rejects_inconsistent_ids_and_aliases_without_publishing_a_snapshot() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    let header = "kind,id,text,weight,index,reading,key_hex\n";
    for rows in [
        "word,0,甲,1,0,jia,\nword,2,乙,2,0,yi,\n",
        "word,0,甲,1,0,jia,\nword,0,乙,2,0,yi,\n",
        "word,0,甲,1,0,jia,\nword,1,甲,2,0,jia,\n",
        "word,0,甲,1,0,jia,\nalias,1,,,1,j,\n",
        "word,0,甲,1,0,jia,\nalias,0,,,0,jia,\n",
        "word,0,甲,1,0,,a\n",
    ] {
        scratch.write("invalid.csv", &format!("{header}{rows}"))?;
        let result = scratch
            .command(&["lexicon", "restore", "invalid.csv", "invalid.silex"])
            .output()?;
        assert!(!result.status.success(), "{rows}");
        assert!(!scratch.0.join("invalid.silex").exists());
    }
    Ok(())
}

#[test]
fn build_and_add_lexicon_sources_preserve_counts_and_word_ids() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    fs::create_dir(scratch.0.join("chinese"))?;
    scratch.write("chinese/b.csv", "text,reading,weight\n重,zhong,3\n")?;
    scratch.write("chinese/a.csv", "text,reading,weight\n重,chong,7\n")?;
    scratch.write(
        "english.csv",
        "\u{feff}\"text\",reading,weight\r\n\"a, \"\"title\"\"\",atitle,9\r\n",
    )?;
    scratch.run(&[
        "lexicon",
        "build",
        "base.silex",
        "0",
        "chinese",
        "1",
        "english.csv",
    ])?;
    let path = scratch.0.join("base.silex");
    let resources = EngineResources::open(&path, None)?;
    let lexicon = resources.lexicon();
    let word = lexicon.exact(IndexId(0), b"chong").next().unwrap();
    assert_eq!(word.id.0, 0);
    assert_eq!(word.count, 7);
    let zhong = lexicon.exact(IndexId(0), b"zhong").next().unwrap();
    assert_eq!(zhong.count, 3);
    assert_ne!(zhong.id, word.id);
    assert!(lexicon.find_word("重").is_none());
    let title = lexicon.exact(IndexId(1), b"atitle").next().unwrap();
    assert_eq!(title.text, "a, \"title\"");
    assert_eq!(title.count, 9);
    assert!(lexicon.exact(IndexId(0), b"atitle").next().is_none());

    scratch.write(
        "delta.csv",
        "text,reading,weight\n重,chong,2\n重,chung,1\n茶,cha,8\n",
    )?;
    scratch.run(&["lexicon", "add", "base.silex", "0", "delta.csv"])?;
    let updated = EngineResources::open(&path, None)?;
    let lexicon = updated.lexicon();
    assert_eq!(
        lexicon.find_reading(IndexId(0), b"chong", "重"),
        Some(word.id)
    );
    assert_eq!(lexicon.word(word.id).unwrap().count, 9);
    assert_eq!(lexicon.word(zhong.id).unwrap().count, 3);
    let chung = lexicon.exact(IndexId(0), b"chung").next().unwrap();
    assert_eq!(chung.count, 1);
    assert_ne!(chung.id, word.id);
    assert_ne!(chung.id, zhong.id);
    assert_eq!(lexicon.exact(IndexId(0), b"cha").next().unwrap().count, 8);
    Ok(())
}

#[test]
fn corpus_imports_accumulate_only_within_known_word_runs() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "words.csv",
        "text,reading,weight\n我,wo,2\n喜欢,xihuan,3\n喝,he,4\n茶,cha,5\n",
    )?;
    scratch.write("first.txt", "我 喜欢 喝 茶\n我 未收录 茶\n茶 我\n")?;
    scratch.write("second.txt", "我 喜欢 喝 茶\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "words.csv"])?;
    let output = scratch.run(&["corpus", "build", "base.silex", "base.sigram", "first.txt"])?;
    assert!(String::from_utf8_lossy(&output.stdout).contains("skipped 1 unknown tokens"));
    scratch.run(&["corpus", "add", "base.silex", "base.sigram", "second.txt"])?;

    let lexicon_path = scratch.0.join("base.silex");
    let gram_path = scratch.0.join("base.sigram");
    let resources = EngineResources::open(&lexicon_path, Some(&gram_path))?;
    let lexicon = resources.lexicon();
    let [a, b, c, d] = ["我", "喜欢", "喝", "茶"].map(|text| lexicon.find_word(text).unwrap());
    let grams = resources.grams().unwrap();
    assert_eq!(grams.count(&[a, b]), Some(2));
    assert_eq!(grams.count(&[b, c, d]), Some(2));
    assert_eq!(grams.count(&[a, b, c, d]), Some(2));
    assert_eq!(grams.count(&[d, a]), Some(1));
    assert_eq!(grams.count(&[a, d]), None);
    assert_eq!(grams.count(&[c, d, a]), None);
    assert_eq!(lexicon.word(a).unwrap().count, 2);

    let before = fs::read(&gram_path)?;
    fs::write(scratch.0.join("malformed.txt"), b"known line\n\xff\n")?;
    assert!(
        !scratch
            .command(&[
                "corpus",
                "add",
                "base.silex",
                "base.sigram",
                "second.txt",
                "malformed.txt"
            ])
            .output()?
            .status
            .success()
    );
    scratch.write(
        "reordered.csv",
        "text,reading,weight\n喜欢,xihuan,3\n我,wo,2\n喝,he,4\n茶,cha,5\n",
    )?;
    scratch.run(&["lexicon", "build", "other.silex", "0", "reordered.csv"])?;
    assert!(
        !scratch
            .command(&["corpus", "add", "other.silex", "base.sigram", "second.txt"])
            .output()?
            .status
            .success()
    );
    assert_eq!(fs::read(&gram_path)?, before);

    scratch.write("old.csv", "text,reading,weight\n我,wo,2\n")?;
    scratch.run(&["lexicon", "build", "old.silex", "0", "old.csv"])?;
    let older = scratch.0.join("old.silex");
    assert!(matches!(
        EngineResources::open(&older, Some(&gram_path)),
        Err(error) if error.kind() == io::ErrorKind::InvalidData
    ));
    Ok(())
}

#[test]
fn word_corpus_requires_an_explicit_reading_for_polyphonic_text() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "words.csv",
        "text,reading,weight\n重,zhong,3\n重,chong,7\n庆,qing,9\n",
    )?;
    scratch.write(
        "resolved.txt",
        "重|0|chong 庆\n重|0|chong 庆\n重|0|zhong 庆\n",
    )?;
    scratch.write("ambiguous.txt", "重 庆\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "words.csv"])?;
    scratch.run(&[
        "corpus",
        "build",
        "base.silex",
        "base.sigram",
        "resolved.txt",
    ])?;
    let gram_path = scratch.0.join("base.sigram");
    let resources = EngineResources::open(&scratch.0.join("base.silex"), Some(&gram_path))?;
    let lexicon = resources.lexicon();
    let chong = lexicon.find_reading(IndexId(0), b"chong", "重").unwrap();
    let zhong = lexicon.find_reading(IndexId(0), b"zhong", "重").unwrap();
    let qing = lexicon.find_word("庆").unwrap();
    let grams = resources.grams().unwrap();
    assert_eq!(grams.count(&[chong, qing]), Some(2));
    assert_eq!(grams.count(&[zhong, qing]), Some(1));

    let before = fs::read(&gram_path)?;
    let failure = scratch
        .command(&[
            "corpus",
            "add",
            "base.silex",
            "base.sigram",
            "ambiguous.txt",
        ])
        .output()?;
    assert!(!failure.status.success());
    assert!(
        String::from_utf8_lossy(&failure.stderr)
            .contains("ambiguous.txt:1: ambiguous corpus token")
    );
    assert_eq!(fs::read(&gram_path)?, before);

    // The output text at each ordinal is identical, but the readings have switched.
    scratch.write(
        "reordered.csv",
        "text,reading,weight\n重,chong,7\n重,zhong,3\n庆,qing,9\n",
    )?;
    scratch.run(&["lexicon", "build", "reordered.silex", "0", "reordered.csv"])?;
    assert!(matches!(
        EngineResources::open(&scratch.0.join("reordered.silex"), Some(&gram_path)),
        Err(error) if error.kind() == io::ErrorKind::InvalidData
    ));
    Ok(())
}

#[test]
fn missing_reading_rejects_the_entire_csv_import() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("words.csv", "text,reading,weight\n重,chong,7\n")?;
    scratch.write("missing.csv", "text,reading,weight\n重,chong,2\n重, ,3\n")?;
    let failure = scratch
        .command(&["lexicon", "build", "new.silex", "0", "missing.csv"])
        .output()?;
    assert!(!failure.status.success());
    assert!(String::from_utf8_lossy(&failure.stderr).contains("missing.csv:3: missing reading"));
    assert!(!scratch.0.join("new.silex").exists());

    scratch.run(&["lexicon", "build", "base.silex", "0", "words.csv"])?;
    let path = scratch.0.join("base.silex");
    let before = fs::read(&path)?;
    let failure = scratch
        .command(&["lexicon", "add", "base.silex", "0", "missing.csv"])
        .output()?;
    assert!(!failure.status.success());
    assert!(String::from_utf8_lossy(&failure.stderr).contains("missing.csv:3: missing reading"));
    assert_eq!(fs::read(path)?, before);
    Ok(())
}

#[test]
fn han_corpus_learns_two_three_and_four_character_words_with_exact_counts() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "seed.csv",
        "text,reading,weight\n深,shen,1\n海,hai,2\n探,tan,3\n测,ce,4\n重,chong,5\n重,zhong,0\n庆,qing,6\n",
    )?;
    scratch.write("english.csv", "text,reading,weight\nA,a,1\n")?;
    scratch.run(&[
        "lexicon",
        "build",
        "base.silex",
        "0",
        "seed.csv",
        "1",
        "english.csv",
    ])?;
    scratch.write("existing.csv", "text,reading,weight\n探测,tan'ce,99\n")?;
    scratch.run(&["lexicon", "add", "base.silex", "0", "existing.csv"])?;
    let lexicon_path = scratch.0.join("base.silex");
    let gram_path = scratch.0.join("base.sigram");
    let seed = EngineResources::open(&lexicon_path, None)?;
    let [deep, sea, existing] =
        ["深", "海", "探测"].map(|text| seed.lexicon().find_word(text).unwrap());

    scratch.write(
        "first.txt",
        "深海探测。深海探，深海\n深A测\n深未测\n深\n测\n重庆！重庆！重庆！重庆\n探测，探测\n",
    )?;
    scratch.write("more.txt", "深海探测\n")?;
    let output = scratch.run(&[
        "corpus",
        "build",
        "--han",
        "base.silex",
        "base.sigram",
        "first.txt",
    ])?;
    assert!(String::from_utf8_lossy(&output.stdout).contains("skipped 1 unknown tokens"));
    scratch.run(&[
        "corpus",
        "add",
        "--han",
        "base.silex",
        "base.sigram",
        "more.txt",
    ])?;
    let gram_bytes = fs::read(&gram_path)?;
    assert!(EngineResources::open(&lexicon_path, Some(&gram_path)).is_err());
    scratch.learning_config(0, [4, 3, 2], [0; 3])?;
    let learn = [
        "lexicon",
        "learn",
        "base.silex",
        "base.sigram",
        "learning.conf",
    ];
    let output = scratch.run(&learn)?;
    assert!(
        String::from_utf8_lossy(&output.stdout)
            .contains("Added 2 two-character, 1 three-character, and 1 four-character")
    );
    assert!(!scratch.0.join("base.silex.review-1.csv").exists());

    let resources = EngineResources::open(&lexicon_path, None)?;
    let lexicon = resources.lexicon();
    let pinyin = IndexId(0);
    for (key, expected_text, count) in [
        ("shen'hai", "深海", 4),
        ("shen'hai'tan", "深海探", 3),
        ("shen'hai'tan'ce", "深海探测", 2),
        ("chong'qing", "重庆", 4),
    ] {
        let word = lexicon.exact(pinyin, key.as_bytes()).next().unwrap();
        assert_eq!(word.text, expected_text);
        assert_eq!(word.count, count);
        assert_eq!(lexicon.find_word(expected_text), Some(word.id));
    }
    assert_eq!(lexicon.word(existing).unwrap().count, 99);
    assert_eq!(lexicon.word(deep).unwrap().count, 1);
    assert_eq!(lexicon.word(sea).unwrap().count, 2);
    assert!(lexicon.find_word("海探").is_none());
    assert!(lexicon.find_word("海探测").is_none());
    assert!(lexicon.exact(pinyin, b"zhong'qing").next().is_none());
    assert!(lexicon.exact(IndexId(1), b"chong'qing").next().is_none());
    assert_eq!(fs::read(&gram_path)?, gram_bytes);

    let before_retry = fs::read(&lexicon_path)?;
    let retry = scratch.run(&learn)?;
    assert!(
        String::from_utf8_lossy(&retry.stdout)
            .contains("Added 0 two-character, 0 three-character, and 0 four-character")
    );
    assert_eq!(fs::read(&lexicon_path)?, before_retry);
    assert!(!scratch.0.join("base.silex.review-1.csv").exists());

    scratch.write("later.txt", "深海探测！\n")?;
    scratch.run(&[
        "corpus",
        "add",
        "--han",
        "base.silex",
        "base.sigram",
        "later.txt",
    ])?;
    scratch.run(&learn)?;
    let expanded = EngineResources::open(&lexicon_path, None)?;
    let expanded = expanded.lexicon();
    let learned_sea = lexicon.find_word("深海").unwrap();
    assert_eq!(expanded.find_word("深海"), Some(learned_sea));
    assert_eq!(expanded.word(learned_sea).unwrap().count, 4);
    assert_eq!(expanded.exact(pinyin, b"hai'tan").next().unwrap().count, 4);
    assert_eq!(
        expanded.exact(pinyin, b"hai'tan'ce").next().unwrap().count,
        3
    );

    scratch.write(
        "reordered.csv",
        "text,reading,weight\n海,hai,2\n深,shen,1\n探,tan,3\n测,ce,4\n重,chong,5\n庆,qing,6\n",
    )?;
    scratch.run(&["lexicon", "build", "other.silex", "0", "reordered.csv"])?;
    let other = scratch.0.join("other.silex");
    let before_failure = fs::read(&other)?;
    let wrong_model = scratch
        .command(&[
            "lexicon",
            "learn",
            "other.silex",
            "base.sigram",
            "learning.conf",
        ])
        .output()?;
    assert!(!wrong_model.status.success());
    assert_eq!(fs::read(other)?, before_failure);
    Ok(())
}

#[test]
fn learning_exports_unresolved_pinyin_and_preserves_manual_readings() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("seed.csv", "text,reading,weight\n茶,cha,1\n𠼞,a,1\n")?;
    scratch.write("words.txt", "𠼞茶\n𠼞茶\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "seed.csv"])?;
    scratch.run(&[
        "corpus",
        "build",
        "--han",
        "base.silex",
        "base.sigram",
        "words.txt",
    ])?;
    scratch.learning_config(0, [1; 3], [0; 3])?;
    let learn = [
        "lexicon",
        "learn",
        "base.silex",
        "base.sigram",
        "learning.conf",
    ];
    let result = scratch.run(&learn)?;
    assert!(
        String::from_utf8_lossy(&result.stdout)
            .contains("Exported 1 candidates for reading review to base.silex.review-1.csv")
    );
    let report = "text,reading,weight\n𠼞茶,,2\n";
    let review_name = "base.silex.review-1.csv";
    let first = scratch.0.join(review_name);
    assert_eq!(fs::read_to_string(&first)?, report);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&first)?.permissions().mode() & 0o077, 0);
    }
    let path = scratch.0.join("base.silex");
    let resources = EngineResources::open(&path, None)?;
    assert!(resources.lexicon().find_word("𠼞茶").is_none());
    let before_review = fs::read(&path)?;
    let add_review = ["lexicon", "add", "base.silex", "0", review_name];
    assert!(!scratch.command(&add_review).output()?.status.success());
    assert_eq!(fs::read(&path)?, before_review);

    let edited = "text,reading,weight\n𠼞茶,a'cha,2\n";
    fs::write(&first, edited)?;
    scratch.run(&learn)?;
    assert_eq!(fs::read_to_string(first)?, edited);
    assert_eq!(
        fs::read_to_string(scratch.0.join("base.silex.review-2.csv"))?,
        report
    );

    scratch.run(&add_review)?;
    let reviewed = EngineResources::open(&path, None)?;
    let word = reviewed
        .lexicon()
        .exact(IndexId(0), b"a'cha")
        .next()
        .unwrap();
    assert_eq!(word.text, "𠼞茶");
    assert_eq!(word.count, 2);
    let saved = fs::read(&path)?;
    scratch.run(&learn)?;
    assert_eq!(fs::read(&path)?, saved);
    assert!(!scratch.0.join("base.silex.review-3.csv").exists());
    Ok(())
}

#[test]
fn malformed_csv_and_repeated_build_leave_the_existing_snapshot_intact() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("words.csv", "text,reading,weight\nalpha,alpha,1\n")?;
    scratch.write(
        "bad.csv",
        "text,reading,weight\nalpha,alpha,2\n\"synthetic payload,beta,invalid\n",
    )?;
    let build = ["lexicon", "build", "base.silex", "0", "words.csv"];
    scratch.run(&build)?;
    let path = scratch.0.join("base.silex");
    let before = fs::read(&path)?;

    let bad = scratch
        .command(&["lexicon", "add", "base.silex", "0", "bad.csv"])
        .output()?;
    assert!(!bad.status.success());
    let message = String::from_utf8_lossy(&bad.stderr);
    assert!(message.contains("bad.csv:3"));
    assert!(!message.contains("synthetic payload"));
    assert!(!scratch.command(&build).output()?.status.success());
    assert_eq!(fs::read(path)?, before);
    Ok(())
}

#[test]
fn legacy_files_keep_word_ordinals_and_counts_when_updated() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "words.csv",
        "text,reading,weight\nalpha,alpha,2\nbeta,beta,3\n",
    )?;
    scratch.write("words.txt", "alpha beta\n")?;
    scratch.run(&["lexicon", "build", "main.silex", "0", "words.csv"])?;
    scratch.run(&["corpus", "build", "main.silex", "main.sigram", "words.txt"])?;
    let lexicon_path = scratch.0.join("main.silex");
    let gram_path = scratch.0.join("main.sigram");

    // Recreate the previous layouts using the same rows and an old dictionary number.
    let old_number = 42_u64.to_le_bytes();
    let mut lexicon = fs::read(&lexicon_path)?;
    assert_eq!(&lexicon[..8], b"SILEX\0\x03\0");
    let length =
        |offset| u32::from_le_bytes(lexicon[offset..offset + 4].try_into().unwrap()) as usize;
    let reading_start = 32 + 16 * length(8) + length(12);
    let reading_end = reading_start + 8 * length(8) + length(28);
    lexicon.drain(reading_start..reading_end);
    lexicon.drain(28..32);
    lexicon[6] = 1;
    lexicon.splice(8..8, old_number);
    fs::write(&lexicon_path, lexicon)?;
    let mut grams = fs::read(&gram_path)?;
    assert_eq!(&grams[..8], b"SIGRAM\x03\0");
    grams[6] = 1;
    grams[8..16].copy_from_slice(&old_number);
    fs::write(&gram_path, grams)?;

    let resources = EngineResources::open(&lexicon_path, Some(&gram_path))?;
    let a = resources.lexicon().find_word("alpha").unwrap();
    let b = resources.lexicon().find_word("beta").unwrap();
    assert_eq!(resources.grams().unwrap().count(&[a, b]), Some(1));

    scratch.write(
        "delta.csv",
        "text,reading,weight\nalpha,alpha,4\ngamma,gamma,1\n",
    )?;
    scratch.run(&["lexicon", "add", "main.silex", "0", "delta.csv"])?;
    scratch.run(&["corpus", "add", "main.silex", "main.sigram", "words.txt"])?;
    let resources = EngineResources::open(&lexicon_path, Some(&gram_path))?;
    assert_eq!(resources.lexicon().find_word("alpha"), Some(a));
    assert_eq!(resources.lexicon().find_word("beta"), Some(b));
    assert_eq!(resources.lexicon().word(a).unwrap().count, 6);
    assert_eq!(resources.grams().unwrap().count(&[a, b]), Some(2));
    assert_eq!(&fs::read(&lexicon_path)?[..8], b"SILEX\0\x03\0");
    assert_eq!(&fs::read(&gram_path)?[..8], b"SIGRAM\x03\0");
    Ok(())
}

#[test]
fn simultaneous_adds_accumulate_both_deltas() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("initial.csv", "text,reading,weight\nalpha,alpha,1\n")?;
    scratch.write("one.csv", "text,reading,weight\nalpha,alpha,2\n")?;
    scratch.write("two.csv", "text,reading,weight\nalpha,alpha,3\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "initial.csv"])?;
    let mut one = scratch
        .command(&["lexicon", "add", "base.silex", "0", "one.csv"])
        .stdout(Stdio::null())
        .spawn()?;
    let mut two = scratch
        .command(&["lexicon", "add", "base.silex", "0", "two.csv"])
        .stdout(Stdio::null())
        .spawn()?;
    assert!(one.wait()?.success());
    assert!(two.wait()?.success());
    let resources = EngineResources::open(&scratch.0.join("base.silex"), None)?;
    assert_eq!(
        resources
            .lexicon()
            .exact(IndexId(0), b"alpha")
            .next()
            .unwrap()
            .count,
        6
    );
    Ok(())
}

struct ScratchDirectory(PathBuf);

impl ScratchDirectory {
    fn new() -> io::Result<Self> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        loop {
            let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("si-cli-{}-{sequence}", std::process::id()));
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error),
            }
        }
    }

    fn write(&self, relative: impl AsRef<Path>, contents: &str) -> io::Result<()> {
        fs::write(self.0.join(relative), contents)
    }

    fn learning_config(
        &self,
        index: u32,
        counts: [u64; 3],
        percentages: [u8; 3],
    ) -> io::Result<()> {
        use std::fmt::Write;

        let mut settings = format!("pinyin_index = {index}\n");
        for (order, (count, percent)) in (2..=4).zip(counts.into_iter().zip(percentages)) {
            writeln!(
                settings,
                "min_count_{order} = {count}\nmin_prefix_percent_{order} = {percent}"
            )
            .unwrap();
        }
        self.write("learning.conf", &settings)
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_si-cli"));
        command.current_dir(&self.0).args(args);
        command
    }

    fn run(&self, args: &[&str]) -> io::Result<Output> {
        let output = self.command(args).output()?;
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        Ok(output)
    }
}

impl Drop for ScratchDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
