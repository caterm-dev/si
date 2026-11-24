use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

use si_engine::IndexId;
use si_engine::resources::EngineResources;
use si_engine::resources::user::UserModelStore;

#[test]
fn user_and_base_imports_apply_independent_orders_to_new_batches() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    let config = TEST_CONFIG;
    scratch.write(
        "si.conf",
        &config.replace("[base]\nmax_order = 4", "[base]\nmax_order = 3"),
    )?;
    scratch.write("words.csv", "text,reading,weight\nalpha,alpha,1\nbeta,beta,1\ngamma,gamma,1\ndelta,delta,1\nepsilon,epsilon,1\n")?;
    scratch.write("words.txt", "alpha beta gamma delta epsilon\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "1", "words.csv"])?;
    scratch.run(&[
        "--config",
        "si.conf",
        "corpus",
        "build",
        "base.silex",
        "base.sigram",
        "words.txt",
    ])?;
    scratch.run(&[
        "--config",
        "si.conf",
        "corpus",
        "ingest",
        "base.silex",
        "paragraphs.sigram",
        "words.txt",
    ])?;
    let mut user_ingest = [
        "--config",
        "si.conf",
        "user",
        "ingest",
        "profile.si-user",
        "base.silex",
        "first",
        "words.txt",
    ];
    scratch.run(&user_ingest)?;

    let base_lexicon = scratch.0.join("base.silex");
    let base_grams = scratch.0.join("base.sigram");
    let profile = UserModelStore::new(scratch.0.join("profile.si-user"));
    let base = EngineResources::open(&base_lexicon, Some(&base_grams))?;
    assert_eq!(base.grams().unwrap().sizes(), [4, 3, 0, 0]);
    assert_eq!(
        profile.load()?.unwrap().grams().unwrap().sizes(),
        [4, 3, 2, 0]
    );

    scratch.write(
        "si.conf",
        &config.replace("[user]\nmax_order = 4", "[user]\nmax_order = 5"),
    )?;
    scratch.run(&[
        "--config",
        "si.conf",
        "corpus",
        "add",
        "base.silex",
        "base.sigram",
        "words.txt",
    ])?;
    scratch.run(&[
        "--config",
        "si.conf",
        "corpus",
        "ingest",
        "base.silex",
        "paragraphs.sigram",
        "words.txt",
    ])?;
    let duplicate = scratch.run(&user_ingest)?;
    assert!(String::from_utf8_lossy(&duplicate.stdout).contains("Batch was already applied"));
    user_ingest[6] = "second";
    let output = scratch.run(&user_ingest)?;
    assert!(String::from_utf8_lossy(&output.stdout).contains("1 five-grams"));

    for path in [base_grams, scratch.0.join("paragraphs.sigram")] {
        let base = EngineResources::open(&base_lexicon, Some(&path))?;
        let words = ["alpha", "beta", "gamma", "delta", "epsilon"]
            .map(|word| base.lexicon().find_word(word).unwrap());
        let grams = base.grams().unwrap();
        assert_eq!(grams.count(&words[..3]), Some(2));
        assert_eq!(grams.count(&words[..4]), Some(1));
        assert_eq!(grams.count(&words), None);
    }

    scratch.write("si.conf", config)?;
    user_ingest[6] = "third";
    scratch.run(&user_ingest)?;
    let user = profile.load()?.unwrap();
    let words = ["alpha", "beta", "gamma", "delta", "epsilon"]
        .map(|word| user.lexicon().find_word(word).unwrap());
    let grams = user.grams().unwrap();
    assert_eq!(grams.count(&words[..4]), Some(3));
    assert_eq!(grams.count(&words), Some(1));

    scratch.write(
        "si.conf",
        &config.replace("[user]\nmax_order = 4", "[user]\nmax_order = 6"),
    )?;
    user_ingest[6] = "invalid";
    let error = scratch.command(&user_ingest).output()?;
    assert!(!error.status.success());
    assert!(
        String::from_utf8_lossy(&error.stderr).contains("max_order must be an integer in 2..=5")
    );
    assert_eq!(
        profile.load()?.unwrap().grams().unwrap().count(&words[..4]),
        Some(3)
    );
    Ok(())
}

#[test]
fn candidates_stream_queries_with_optional_base_grams_and_user_profile() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("zh.csv", "text,reading,weight\n和,he,15\n好,hao,10\n")?;
    scratch.write("en.csv", "text,reading,weight\nhe,he,20\n")?;
    scratch.write("base.txt", "和 好\n")?;
    scratch.write("user.txt", "Beacon\n")?;
    scratch.run(&[
        "lexicon",
        "build",
        "base.silex",
        "0",
        "zh.csv",
        "1",
        "en.csv",
    ])?;
    scratch.run(&["corpus", "build", "base.silex", "base.sigram", "base.txt"])?;
    scratch.run(&[
        "user",
        "ingest",
        "profile.si-user",
        "base.silex",
        "query",
        "user.txt",
    ])?;
    let mut child = scratch
        .command(&[
            "candidates",
            "base.silex",
            "--grams",
            "base.sigram",
            "--user",
            "profile.si-user",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    child.stdin.take().unwrap().write_all(b"he\nbeacon\n\n")?;
    let output = child.wait_with_output()?;
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
    let stdout = String::from_utf8(output.stdout).map_err(io::Error::other)?;
    let (first, rest) = stdout.split_once("\n\n").unwrap();
    assert!(
        first
            .lines()
            .any(|row| row.starts_with("zh-Hans\t2\texact\t") && row.ends_with("\t和"))
    );
    assert!(
        first
            .lines()
            .any(|row| row.starts_with("en\t2\texact\t") && row.ends_with("\the"))
    );
    assert!(first.ends_with("literal\t2\tliteral\t\the"));
    let (second, empty) = rest.split_once("\n\n").unwrap();
    assert!(
        second
            .lines()
            .any(|row| row.starts_with("en\t6\texact\t") && row.ends_with("\tBeacon"))
    );
    assert!(second.ends_with("literal\t6\tliteral\t\tbeacon"));
    assert_eq!(empty, "\n");
    Ok(())
}

#[test]
fn window_candidates_use_the_shared_policy_without_truncating_full_results() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    let mut csv = String::from("text,reading,weight\n");
    for i in 0..15 {
        csv.push_str(&format!("Word{i},sample,{}\n", 100 - i));
    }
    scratch.write("words.csv", &csv)?;
    scratch.run(&["lexicon", "build", "base.silex", "1", "words.csv"])?;
    for (list, expected) in [("full", 16), ("window", 10)] {
        let mut child = scratch
            .command(&["candidates", "base.silex", "--list", list])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?;
        child.stdin.take().unwrap().write_all(b"sample\n")?;
        let output = child.wait_with_output()?;
        assert!(output.status.success());
        let stdout = String::from_utf8(output.stdout).map_err(io::Error::other)?;
        let rows: Vec<_> = stdout.lines().filter(|line| !line.is_empty()).collect();
        assert_eq!(rows.len(), expected);
        assert!(rows[0].ends_with("\tWord0"));
        assert_eq!(*rows.last().unwrap(), "literal\t6\tliteral\t\tsample");
    }
    Ok(())
}

#[test]
fn candidates_accept_preceding_text_for_pinyin_correction() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "zh.csv",
        "text,reading,weight\n想,xiang,100\n找,zhao,100\n告诉,gao'su,100\n高旭,gao'xu,100\n知道,zhi'dao,2000000\n",
    )?;
    scratch.write("sentences.txt", &"想 告诉\n找 高旭\n".repeat(1_000))?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "zh.csv"])?;
    scratch.run(&[
        "corpus",
        "build",
        "base.silex",
        "base.sigram",
        "sentences.txt",
    ])?;
    for (preceding, suggest) in [("", false), ("想。找", false), ("找。想", true)] {
        let mut child = scratch
            .command(&[
                "candidates",
                "base.silex",
                "--grams",
                "base.sigram",
                "--search",
                "preview",
                "--pinyin-correction",
                "on",
                "--preceding",
                preceding,
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?;
        child.stdin.take().unwrap().write_all(b"gaoxu\n")?;
        let output = child.wait_with_output()?;
        assert!(output.status.success());
        let stdout = String::from_utf8(output.stdout).map_err(io::Error::other)?;
        let rows: Vec<_> = stdout.lines().collect();
        assert!(rows[0].ends_with(if suggest { "\t告诉" } else { "\t高旭" }));
        assert!(
            rows.iter()
                .any(|row| row.starts_with("zh-Hans\t5\texact\t") && row.ends_with("\t高旭"))
        );
        assert_eq!(
            rows.iter()
                .any(|row| row.starts_with("zh-Hans\t5\tcorrection\t") && row.ends_with("\t告诉")),
            suggest,
            "{preceding:?}"
        );
        assert!(stdout.ends_with("literal\t5\tliteral\t\tgaoxu\n\n"));
    }
    Ok(())
}

#[test]
fn user_sentences_grow_an_independent_model_and_learn_words() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "base.csv",
        "text,reading,weight\n白茶,bai'cha,900\n鹤,he,600\n云,yun,500\n星光,xing'guang,30\n塔,ta,25\n",
    )?;
    scratch.write("base.txt", "云 鹤 白茶\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "base.csv"])?;
    scratch.run(&["corpus", "build", "base.silex", "base.sigram", "base.txt"])?;
    let base_lexicon = fs::read(scratch.0.join("base.silex"))?;
    let base_grams = fs::read(scratch.0.join("base.sigram"))?;

    let profile = "profile.si-user";
    let store = UserModelStore::new(scratch.0.join(profile));
    assert!(store.load()?.is_none());
    scratch.write("sentences.txt", &"云鹤 Beacon Rust Beta。白茶\n".repeat(5))?;
    let ingest = [
        "user",
        "ingest",
        profile,
        "base.silex",
        "batch-1",
        "sentences.txt",
    ];
    let first = scratch.run(&ingest)?;
    assert!(String::from_utf8_lossy(&first.stdout).contains("Imported 5 sentences"));
    assert!(first.stderr.is_empty());
    assert!(!String::from_utf8_lossy(&first.stdout).contains("Beacon"));
    assert!(String::from_utf8_lossy(&scratch.run(&ingest)?.stdout).contains("already applied"));

    let initial = store.load()?.unwrap();
    let lexicon = initial.lexicon();
    let cloud = lexicon.find_word("云").unwrap();
    let crane = lexicon.find_word("鹤").unwrap();
    let beacon = lexicon.find_word("Beacon").unwrap();
    let rust = lexicon.find_word("Rust").unwrap();
    let beta = lexicon.find_word("Beta").unwrap();
    let tea = lexicon.find_word("白茶").unwrap();
    assert_ne!(
        cloud,
        si_engine::resources::EngineResources::open(&scratch.0.join("base.silex"), None,)?
            .lexicon()
            .find_word("云")
            .unwrap()
    );
    assert_eq!(lexicon.word(cloud).unwrap().count, 5);
    assert_eq!(
        lexicon.exact(IndexId(1), b"beacon").next().unwrap().text,
        "Beacon"
    );
    let grams = initial.grams().unwrap();
    assert_eq!(grams.count(&[cloud, crane]), Some(5));
    assert_eq!(grams.count(&[cloud, crane, beacon]), Some(5));
    assert_eq!(grams.count(&[crane, beacon, rust, beta]), Some(5));
    assert_eq!(grams.count(&[beta, tea]), None);
    assert_eq!(grams.count(&[tea, cloud]), None);
    assert!(lexicon.find_word("云鹤").is_none());

    let learn = ["user", "learn", profile, "base.silex"];
    assert!(String::from_utf8_lossy(&scratch.run(&learn)?.stdout).contains("Added 1 user words"));
    let learned = store.load()?.unwrap();
    let word = learned
        .lexicon()
        .exact(IndexId(0), b"yun'he")
        .next()
        .unwrap();
    assert_eq!((word.text, word.count), ("云鹤", 5));
    assert_eq!(learned.grams().unwrap().count(&[word.id, beacon]), None);
    assert!(String::from_utf8_lossy(&scratch.run(&learn)?.stdout).contains("Added 0 user words"));

    scratch.write("sentences.txt", "云鹤 Beacon\n")?;
    scratch.run(&[
        "user",
        "ingest",
        profile,
        "base.silex",
        "batch-2",
        "sentences.txt",
    ])?;
    let updated = store.load()?.unwrap();
    // A newly discovered low-count compound remains available, but no longer
    // overrides the more probable component path just because it is longer.
    assert_eq!(updated.lexicon().word(word.id).unwrap().count, 5);
    assert_eq!(updated.grams().unwrap().count(&[word.id, beacon]), None);
    assert_eq!(updated.grams().unwrap().count(&[cloud, crane]), Some(6));

    let base = EngineResources::open(&scratch.0.join("base.silex"), None)?;
    store.ingest(
        base.lexicon(),
        "compound",
        (0..5).flat_map(|_| [Ok("星光塔"), Ok("星光。塔")]),
    )?;
    let observed = store.load()?.unwrap();
    let starlight = observed.lexicon().find_word("星光").unwrap();
    let tower = observed.lexicon().find_word("塔").unwrap();
    assert_eq!(
        observed.grams().unwrap().count(&[starlight, tower]),
        Some(5)
    );
    assert!(observed.lexicon().find_word("星光塔").is_none());
    assert!(String::from_utf8_lossy(&scratch.run(&learn)?.stdout).contains("Added 1 user words"));
    let compound = store.load()?.unwrap();
    let word = compound
        .lexicon()
        .exact(IndexId(0), b"xing'guang'ta")
        .next()
        .unwrap();
    assert_eq!((word.text, word.count), ("星光塔", 5));
    assert!(compound.lexicon().find_word("光塔").is_none());
    assert_eq!(fs::read(scratch.0.join("base.silex"))?, base_lexicon);
    assert_eq!(fs::read(scratch.0.join("base.sigram"))?, base_grams);

    let other = "other.si-user";
    scratch.write("sentences.txt", "云鹤\n")?;
    scratch.run(&[
        "user",
        "ingest",
        other,
        "base.silex",
        "batch-1",
        "sentences.txt",
    ])?;
    scratch.run(&["user", "learn", other, "base.silex"])?;
    let other_store = UserModelStore::new(scratch.0.join(other));
    assert!(
        other_store
            .load()?
            .unwrap()
            .lexicon()
            .find_word("云鹤")
            .is_none()
    );
    scratch.learning_config(0, 1, 100, 100, 0)?;
    scratch.run(&["user", "learn", other, "base.silex", "learning.conf"])?;
    assert_eq!(
        other_store
            .load()?
            .unwrap()
            .lexicon()
            .exact(IndexId(0), b"yun'he")
            .next()
            .unwrap()
            .count,
        1
    );

    scratch.run(&["user", "clear", profile])?;
    assert!(store.load()?.is_none());
    assert!(other_store.load()?.is_some());
    for slot in ["snapshot-a", "snapshot-b"] {
        assert!(!scratch.0.join(profile).join(slot).exists());
    }
    assert!(
        String::from_utf8_lossy(&scratch.run(&["user", "status", profile])?.stdout)
            .contains("profile is empty")
    );
    let mut stdin_import = scratch
        .command(&["user", "ingest", profile, "base.silex", "batch-1", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()?;
    stdin_import
        .stdin
        .take()
        .unwrap()
        .write_all("云鹤\n".as_bytes())?;
    assert!(stdin_import.wait()?.success());
    let restarted = store.load()?.unwrap();
    assert_eq!(restarted.lexicon().len(), 2);
    assert_eq!(restarted.grams().unwrap().sizes(), [1, 0, 0, 0]);
    Ok(())
}

#[test]
fn user_ingest_retries_and_concurrent_updates_publish_one_consistent_pair() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("base.csv", "text,reading,weight\n乙,yi,1\n甲,jia,1\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "base.csv"])?;
    let store = UserModelStore::new(scratch.0.join("profile.si-user"));
    let base = EngineResources::open(&scratch.0.join("base.silex"), None)?;
    assert!(
        store
            .ingest(
                base.lexicon(),
                "retry",
                [
                    Ok("甲乙"),
                    Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "failed synthetic read"
                    )),
                ]
            )
            .is_err()
    );
    assert!(store.load()?.is_none());
    store.ingest(base.lexicon(), "retry", [Ok("甲乙")])?;

    let directory = scratch.0.join("profile.si-user");
    let active = directory.join("snapshot-a");
    let inactive = directory.join("snapshot-b");
    let before = ["user.silex", "user.sigram", "batches"].map(|name| fs::read(active.join(name)));
    fs::create_dir(&inactive)?;
    // Retired sidecars need not decode. Opening the word pair leaves its bytes and receipt intact.
    for name in ["characters.silex", "characters.sigram", "recent-samples-v1"] {
        fs::write(active.join(name), b"synthetic retired file")?;
        fs::write(inactive.join(name), b"synthetic retired file")?;
    }
    assert!(store.load()?.is_some());
    for name in ["characters.silex", "characters.sigram", "recent-samples-v1"] {
        assert!(!active.join(name).exists());
        assert!(!inactive.join(name).exists());
    }
    for (bytes, name) in before
        .into_iter()
        .zip(["user.silex", "user.sigram", "batches"])
    {
        assert_eq!(fs::read(active.join(name))?, bytes?);
    }

    // An interrupted writer can leave a partial inactive slot and pointer.
    fs::write(directory.join("snapshot-b/user.silex"), b"incomplete")?;
    fs::write(directory.join("current.next"), b"b\n")?;
    let loaded = store.load()?.unwrap();
    assert_eq!(
        loaded
            .lexicon()
            .word(loaded.lexicon().find_word("甲").unwrap())
            .unwrap()
            .count,
        1
    );
    let retry = store.ingest::<&str>(
        base.lexicon(),
        "retry",
        std::iter::from_fn(|| panic!("retried batch must not be read")),
    )?;
    assert!(retry.already_applied);
    assert!(!directory.join("snapshot-b").exists());
    assert!(!directory.join("current.next").exists());

    scratch.write("more.txt", "甲乙\n")?;
    let mut children = ["second", "third", "third"].map(|batch| {
        scratch
            .command(&[
                "user",
                "ingest",
                "profile.si-user",
                "base.silex",
                batch,
                "more.txt",
            ])
            .stdout(Stdio::null())
            .spawn()
            .unwrap()
    });
    for child in &mut children {
        assert!(child.wait()?.success());
    }
    let model = store.load()?.unwrap();
    let first = model.lexicon().find_word("甲").unwrap();
    let second = model.lexicon().find_word("乙").unwrap();
    assert_eq!(model.lexicon().word(first).unwrap().count, 3);
    assert_eq!(model.grams().unwrap().count(&[first, second]), Some(3));
    let snapshot = match fs::read(directory.join("current"))?.as_slice() {
        b"a\n" => "snapshot-a",
        b"b\n" => "snapshot-b",
        _ => panic!("missing active snapshot"),
    };
    let mut files = fs::read_dir(directory.join(snapshot))?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect::<io::Result<Vec<_>>>()?;
    files.sort_unstable();
    assert_eq!(files, ["batches", "user.sigram", "user.silex"]);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&directory)?.permissions().mode() & 0o777,
            0o700
        );
        for file in files {
            assert_eq!(
                fs::metadata(directory.join(snapshot).join(file))?
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
    }
    Ok(())
}

#[test]
fn corpus_clear_grams_preserves_lexicon_and_pending_ingest() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("seed.csv", "text,reading,weight\n甲,jia,1\n乙,yi,1\n")?;
    scratch.write("paragraphs.txt", "甲乙\n")?;
    scratch.run(&["lexicon", "build", "main.silex", "0", "seed.csv"])?;
    let ingest = [
        "corpus",
        "ingest",
        "main.silex",
        "words.sigram",
        "paragraphs.txt",
    ];
    scratch.run(&ingest)?;
    let grams = scratch.0.join("words.sigram");
    let lexicon = scratch.0.join("main.silex");
    let review = scratch.0.join("words.sigram.review.csv");
    let gram_bytes = fs::read(&grams)?;
    let lexicon_bytes = fs::read(&lexicon)?;
    let review_bytes = fs::read(&review)?;
    let clear = ["corpus", "clear-grams", "main.silex", "words.sigram"];

    for name in ["main.silex.ingest-pending", "words.sigram.ingest-pending"] {
        let pending = scratch.0.join(name);
        fs::create_dir(&pending)?;
        let rejected = scratch.command(&clear).output()?;
        assert!(!rejected.status.success());
        assert!(String::from_utf8_lossy(&rejected.stderr).contains("pending corpus ingest"));
        assert_eq!(fs::read(&grams)?, gram_bytes);
        fs::remove_dir(pending)?;
    }

    scratch.run(&clear)?;
    assert!(!grams.exists());
    assert_eq!(fs::read(&lexicon)?, lexicon_bytes);
    assert_eq!(fs::read(&review)?, review_bytes);
    assert!(scratch.0.join("words.sigram.lock").is_file());
    scratch.run(&clear)?;

    scratch.run(&ingest)?;
    let reopened = EngineResources::open(&lexicon, Some(&grams))?;
    let [first, second] = ["甲", "乙"].map(|word| reopened.lexicon().find_word(word).unwrap());
    assert_eq!(reopened.grams().unwrap().count(&[first, second]), Some(1));
    assert_eq!(reopened.lexicon().word(first).unwrap().count, 3);
    Ok(())
}

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
fn word_bigrams_learn_compounds_from_single_and_multi_character_tokens() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "seed.csv",
        "text,reading,weight\n数据,shu'ju,1\n库,ku,1\n机器,ji'qi,1\n学习,xue'xi,1\n",
    )?;
    scratch.write("corpus.txt", &"数据库\n机器学习\n数据alpha\n".repeat(2))?;
    scratch.write("english.csv", "text,reading,weight\nalpha,alpha,1\n")?;
    scratch.run(&[
        "lexicon",
        "build",
        "base.silex",
        "0",
        "seed.csv",
        "1",
        "english.csv",
    ])?;
    scratch.run(&[
        "corpus",
        "ingest",
        "base.silex",
        "words.sigram",
        "corpus.txt",
    ])?;
    scratch.learning_config(0, 2, 0, 0, 0)?;
    let learn = [
        "lexicon",
        "learn",
        "base.silex",
        "words.sigram",
        "learning.conf",
    ];
    let lexicon_path = scratch.0.join("base.silex");
    let gram_path = scratch.0.join("words.sigram");
    let gram_bytes = fs::read(&gram_path)?;
    let before = EngineResources::open(&lexicon_path, Some(&gram_path))?;
    let data = before.lexicon().find_word("数据").unwrap();
    let alpha = before.lexicon().find_word("alpha").unwrap();
    assert_eq!(before.grams().unwrap().count(&[data, alpha]), Some(2));

    let report = scratch.run(&learn)?;
    assert!(String::from_utf8_lossy(&report.stdout).contains("Added 2 words."));
    let after = EngineResources::open(&lexicon_path, Some(&gram_path))?;
    for (reading, expected) in [("shu'ju'ku", "数据库"), ("ji'qi'xue'xi", "机器学习")] {
        let learned = after
            .lexicon()
            .exact(IndexId(0), reading.as_bytes())
            .next()
            .unwrap();
        assert_eq!((learned.text, learned.count), (expected, 2));
    }
    assert_eq!(after.lexicon().find_word("数据"), Some(data));
    assert!(after.lexicon().find_word("数据alpha").is_none());
    assert_eq!(fs::read(&gram_path)?, gram_bytes);

    let saved = fs::read(&lexicon_path)?;
    let retry = scratch.run(&learn)?;
    assert!(String::from_utf8_lossy(&retry.stdout).contains("Added 0 words."));
    assert_eq!(fs::read(&lexicon_path)?, saved);
    Ok(())
}

#[test]
fn learning_association_accepts_multiple_continuations_and_preserves_review_counts()
-> io::Result<()> {
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
    scratch.learning_config(0, 9, 30, 50, 2)?;
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

    scratch.learning_config(0, 6, 30, 50, 2)?;
    scratch.run(&command)?;
    let resources = EngineResources::open(&path, None)?;
    let lexicon = resources.lexicon();
    for (key, text, count) in [("zai'zhe", "在这", 7), ("zai'na", "在那", 6)] {
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
fn learning_checks_both_directions_on_bigrams() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "seed.csv",
        concat!(
            "text,reading,weight\n重,chong,1\n重,zhong,1\n庆,qing,1\n心,xin,1\n力,li,1\n",
            "江,jiang,1\n海,hai,1\n山,shan,1\n水,shui,1\n白,bai,1\n云,yun,1\n",
            "青,qing,1\n",
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
        ("白山\n", 4),
        ("青山\n", 7),
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
    scratch.learning_config(5, 4, 50, 50, 0)?;
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
    for text in ["重心", "江海", "白云", "白山"] {
        assert!(lexicon.find_word(text).is_none(), "{text}");
    }
    for (key, expected_count) in [("chong'qing", 6), ("qing'shan", 7)] {
        let word = lexicon.exact(IndexId(5), key.as_bytes()).next().unwrap();
        assert_eq!(word.count, expected_count);
    }
    assert_eq!(fs::read(&gram_path)?, gram_bytes);

    let valid = fs::read_to_string(scratch.0.join("learning.conf"))?;
    let learned = fs::read(&path)?;
    for (invalid, expected) in [
        (
            valid.replace("min_forward_percent_2 = 50", "min_forward_percent_2 = 101"),
            "min_forward_percent_2",
        ),
        (
            valid.replace(
                "min_backward_percent_2 = 50",
                "min_backward_percent_2 = 101",
            ),
            "min_backward_percent_2",
        ),
        (
            valid.replace("min_lift_2 = 0", "min_lift_2 = -1"),
            "min_lift_2",
        ),
        (
            valid.replace("min_count_2 = 4\n", ""),
            "missing learning setting min_count_2",
        ),
        (
            format!("{valid}pinyin_index = 5\n"),
            "duplicate learning setting",
        ),
        (
            format!("{valid}force_count = 1\n"),
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
fn paragraph_ingest_marks_nonempty_line_and_punctuation_fragments() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "si.conf",
        &TEST_CONFIG.replace("max_order = 4", "max_order = 5"),
    )?;
    scratch.write(
        "seed.csv",
        "text,reading,weight\n我,wo,1\n先,xian,1\n自己,zi'ji,1\n试,shi,1\n了,le,1\n一下,yi'xia,1\n没,mei,1\n搞定,gao'ding,1\n\"我先自己试了一下，没搞定\",wo'xian'zi'ji'shi'le'yi'xia'mei'gao'ding,1000000\n",
    )?;
    scratch.run(&["lexicon", "build", "main.silex", "0", "seed.csv"])?;
    scratch.write(
        "paragraphs.txt",
        "\u{feff}我先自己试了一下，没搞定。\r\n，？！...\r\n \r\n 我 \r\n",
    )?;
    let ingest = [
        "--config",
        "si.conf",
        "corpus",
        "ingest",
        "main.silex",
        "words.sigram",
        "paragraphs.txt",
    ];
    scratch.run(&ingest)?;
    let first = EngineResources::open(
        &scratch.0.join("main.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    let lexicon = first.lexicon();
    let joined = lexicon.find_word("我先自己试了一下，没搞定").unwrap();
    assert_eq!(lexicon.word(joined).unwrap().count, 1_000_000);
    let [
        start,
        end,
        me,
        first_word,
        myself,
        try_word,
        le,
        once,
        not,
        done,
    ] = [
        "<s>", "</s>", "我", "先", "自己", "试", "了", "一下", "没", "搞定",
    ]
    .map(|text| lexicon.find_word(text).unwrap());
    for id in [start, end] {
        let word = lexicon.word(id).unwrap();
        assert_eq!(word.count, 0);
        assert!(word.reading.is_none());
        assert!(!lexicon.lookup_keys().any(|(_, indexed)| indexed == id));
    }
    let grams = first.grams().unwrap();
    let expected_bigrams = std::collections::HashMap::from([
        ([start, me], 2),
        ([me, first_word], 1),
        ([first_word, myself], 1),
        ([myself, try_word], 1),
        ([try_word, le], 1),
        ([le, once], 1),
        ([once, end], 1),
        ([start, not], 1),
        ([not, done], 1),
        ([done, end], 1),
        ([me, end], 1),
    ]);
    assert_eq!(
        grams.bigrams().collect::<std::collections::HashMap<_, _>>(),
        expected_bigrams
    );
    assert_eq!(grams.count(&[start, me, end]), Some(1));
    assert_eq!(grams.count(&[start, not, done, end]), Some(1));
    assert_eq!(
        grams.count(&[start, me, first_word, myself, try_word]),
        Some(1)
    );
    assert_eq!(grams.count(&[myself, try_word, le, once, end]), Some(1));
    assert_eq!(grams.count(&[once, not]), None);
    assert_eq!(grams.count(&[end, start]), None);
    assert_eq!(grams.count(&[start, end]), None);

    scratch.run(&ingest)?;
    let second = EngineResources::open(
        &scratch.0.join("main.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    assert_eq!(second.lexicon().len(), lexicon.len());
    assert_eq!(second.lexicon().find_word("<s>"), Some(start));
    assert_eq!(second.lexicon().find_word("</s>"), Some(end));
    for (words, count) in expected_bigrams {
        assert_eq!(second.grams().unwrap().count(&words), Some(count * 2));
    }
    Ok(())
}

#[test]
fn paragraph_ingest_unknown_spans_do_not_create_fragment_boundaries() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "seed.csv",
        "text,reading,weight\n甲,jia,1\n乙,yi,1\n丙,bing,1\n丁,ding,1\n重,chong,1\n重,tong,1\n",
    )?;
    scratch.run(&["lexicon", "build", "main.silex", "0", "seed.csv"])?;
    scratch.write("paragraphs.txt", "甲陌乙，陌丙丁陌。甲Mystery乙；重丙。\n")?;
    scratch.run(&[
        "corpus",
        "ingest",
        "main.silex",
        "words.sigram",
        "paragraphs.txt",
    ])?;
    let model = EngineResources::open(
        &scratch.0.join("main.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    let [start, end, a, b, c, d] = ["<s>", "</s>", "甲", "乙", "丙", "丁"]
        .map(|text| model.lexicon().find_word(text).unwrap());
    assert_eq!(
        model
            .grams()
            .unwrap()
            .bigrams()
            .collect::<std::collections::HashMap<_, _>>(),
        std::collections::HashMap::from([
            ([start, a], 2),
            ([b, end], 2),
            ([c, d], 1),
            ([c, end], 1),
        ]),
    );
    assert_eq!(model.grams().unwrap().sizes(), [4, 0, 0, 0]);
    Ok(())
}

#[test]
fn paragraph_ingest_empty_and_unknown_only_fragments_have_no_markers() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("seed.csv", "text,reading,weight\n甲,jia,1\n")?;
    scratch.run(&["lexicon", "build", "main.silex", "0", "seed.csv"])?;
    scratch.write("paragraphs.txt", " \n，。。!!\n陌Mystery\n")?;
    scratch.run(&[
        "corpus",
        "ingest",
        "main.silex",
        "words.sigram",
        "paragraphs.txt",
    ])?;
    let model = EngineResources::open(
        &scratch.0.join("main.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    assert_eq!(model.lexicon().len(), 1);
    assert_eq!(model.grams().unwrap().sizes(), [0; 4]);
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
    let header = "kind,text,count,candidate_readings,first_file,first_line,reading\n";
    let review_path = scratch.0.join("words.sigram.review.csv");
    let review = fs::read_to_string(&review_path)?;
    assert_eq!(
        review,
        format!(
            "{header}unmatched,陌,3,,paragraphs.txt,6,\nunresolved,重,2,0:chong | 0:tong,paragraphs.txt,5,\n"
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
fn paragraph_ingest_review_can_seed_a_fresh_build_without_modifying_the_original_pair()
-> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "seed.csv",
        "text,reading,weight\n甲,jia,1\n重,chong,6\n重,tong,7\n",
    )?;
    scratch.run(&["lexicon", "build", "seed.silex", "0", "seed.csv"])?;
    let corpus = "part,\n\"one\".txt";
    scratch.write(corpus, "重。\n晩。\n陌。\n重。\n甲甲。\n")?;
    scratch.run(&["corpus", "ingest", "seed.silex", "words.sigram", corpus])?;

    let lexicon_path = scratch.0.join("seed.silex");
    let grams_path = scratch.0.join("words.sigram");
    let review_name = "words.sigram.review.csv";
    let lexicon_bytes = fs::read(&lexicon_path)?;
    let gram_bytes = fs::read(&grams_path)?;
    let review = fs::read_to_string(scratch.0.join(review_name))?;
    let source_field = "\"part,\n\"\"one\"\".txt\"";
    let new_reading = format!("unmatched,晩,1,,{source_field},2,");
    let existing_reading = format!("unresolved,重,2,0:chong | 0:tong,{source_field},1,");
    assert!(review.contains(&new_reading) && review.contains(&existing_reading));
    let edited = review
        .replace(&new_reading, &format!("{new_reading}wan"))
        .replace(&existing_reading, &format!("{existing_reading}chong"));
    scratch.write(review_name, &edited)?;
    let result = scratch.run(&[
        "lexicon",
        "build",
        "reviewed.silex",
        "0",
        "seed.csv",
        "0",
        review_name,
    ])?;
    assert!(String::from_utf8_lossy(&result.stdout).contains("Imported 5 CSV rows"));

    let updated = EngineResources::open(&scratch.0.join("reviewed.silex"), None)?;
    let lexicon = updated.lexicon();
    let wan = lexicon.find_reading(IndexId(0), b"wan", "晩").unwrap();
    assert_eq!(lexicon.word(wan).unwrap().count, 1);
    let chong = lexicon.find_reading(IndexId(0), b"chong", "重").unwrap();
    let tong = lexicon.find_reading(IndexId(0), b"tong", "重").unwrap();
    assert_eq!(lexicon.word(chong).unwrap().count, 8);
    assert_eq!(lexicon.word(tong).unwrap().count, 7);
    assert_eq!(fs::read(lexicon_path)?, lexicon_bytes);
    assert!(lexicon.find_word("陌").is_none());
    assert_eq!(fs::read(grams_path)?, gram_bytes);
    Ok(())
}

#[test]
fn paragraph_ingest_reads_ambiguous_words_without_crossing_token_boundaries() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "words.csv",
        concat!(
            "text,reading,weight\n知道,zhi'dao,0\n行为,hang'wei,30\n",
            "行为,xing'wei,20\n会,hui,0\n伤人,shang'ren,0\n"
        ),
    )?;
    scratch.run(&["lexicon", "build", "seed.silex", "0", "words.csv"])?;
    scratch.write("paragraphs.txt", "知道行为会伤人。知道行为\n")?;
    let output = scratch.run(&[
        "corpus",
        "ingest",
        "seed.silex",
        "words.sigram",
        "paragraphs.txt",
    ])?;
    assert!(String::from_utf8_lossy(&output.stdout).contains("and 0 unresolved matches"));
    assert_eq!(
        fs::read_to_string(scratch.0.join("words.sigram.review.csv"))?,
        "kind,text,count,candidate_readings,first_file,first_line,reading\n"
    );
    let resources = EngineResources::open(
        &scratch.0.join("seed.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    let lexicon = resources.lexicon();
    let [know, will, hurt] = ["知道", "会", "伤人"].map(|text| lexicon.find_word(text).unwrap());
    let hang = lexicon
        .find_reading(IndexId(0), b"hang'wei", "行为")
        .unwrap();
    let xing = lexicon
        .find_reading(IndexId(0), b"xing'wei", "行为")
        .unwrap();
    assert_eq!(lexicon.word(hang).unwrap().count, 30);
    assert_eq!(lexicon.word(xing).unwrap().count, 22);
    let grams = resources.grams().unwrap();
    assert_eq!(grams.count(&[know, xing]), Some(2));
    assert_eq!(grams.count(&[know, xing, will, hurt]), Some(1));
    assert_eq!(grams.count(&[know, hang]), None);
    Ok(())
}

#[test]
fn paragraph_ingest_exports_unknown_english_and_counts_only_known_words() -> io::Result<()> {
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
    scratch.write("paragraphs.txt", "revert完PR说明\nPR 说明\nR。PR\npr完\n")?;
    let output = scratch.run(&[
        "corpus",
        "ingest",
        "seed.silex",
        "words.sigram",
        "paragraphs.txt",
    ])?;
    let summary = String::from_utf8_lossy(&output.stdout);
    assert!(summary.contains("Skipped 0 unknown characters"));
    assert!(summary.contains("Exported 2 unknown English spellings"));
    assert!(summary.contains("Counted 1 <char> and 0 <num> placeholders"));

    let first_lexicon = scratch.0.join("seed.silex");
    let grams_path = scratch.0.join("words.sigram");
    let updated = EngineResources::open(&first_lexicon, Some(&grams_path))?;
    let lexicon = updated.lexicon();
    let [revert, wan, explain] =
        ["revert", "完", "说明"].map(|text| lexicon.find_word(text).unwrap());
    assert!(lexicon.find_word("PR").is_none());
    assert!(lexicon.find_word("pr").is_none());
    assert!(lexicon.find_word("P").is_none());
    assert!(lexicon.find_word("R").is_none());
    let grams = updated.grams().unwrap();
    assert_eq!(grams.count(&[revert, wan]), Some(1));
    assert_eq!(grams.count(&[wan, explain]), None);

    let english_csv = scratch.0.join("words.sigram.english.csv");
    assert_eq!(
        fs::read_to_string(&english_csv)?,
        "text,reading,weight\nPR,pr,3\npr,pr,1\n"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&english_csv)?.permissions().mode() & 0o077, 0);
    }
    scratch.run(&[
        "lexicon",
        "build",
        "rebuilt.silex",
        "0",
        "chinese.csv",
        "1",
        "english.csv",
        "1",
        "words.sigram.english.csv",
    ])?;
    let rebuilt = scratch.0.join("rebuilt.silex");
    let imported = EngineResources::open(&rebuilt, None)?;
    let pr = imported
        .lexicon()
        .find_reading(IndexId(1), b"pr", "PR")
        .unwrap();
    assert_eq!(imported.lexicon().word(pr).unwrap().count, 3);
    assert!(imported.grams().is_none());

    scratch.write("more.txt", "PR完\n")?;
    let output = scratch.run(&[
        "corpus",
        "ingest",
        "rebuilt.silex",
        "rebuilt.sigram",
        "more.txt",
    ])?;
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("Exported 0 unknown English spellings")
    );
    assert_eq!(
        fs::read_to_string(scratch.0.join("rebuilt.sigram.english.csv"))?,
        "text,reading,weight\n"
    );
    let next = EngineResources::open(&rebuilt, Some(&scratch.0.join("rebuilt.sigram")))?;
    assert_eq!(next.lexicon().find_word("PR"), Some(pr));
    assert_eq!(next.lexicon().word(pr).unwrap().count, 4);
    assert_eq!(
        next.grams()
            .unwrap()
            .count(&[pr, next.lexicon().find_word("完").unwrap()]),
        Some(1)
    );
    Ok(())
}

#[test]
fn paragraph_ingest_counts_letter_and_number_placeholders_only_in_grams() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "chinese.csv",
        "text,reading,weight\n银行,yin'hang,0\n行走,xing'zou,0\n",
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
    assert_eq!(
        fs::read_to_string(scratch.0.join("words.sigram.english.csv"))?,
        "text,reading,weight\n"
    );
    assert_eq!(
        fs::read_to_string(scratch.0.join("words.sigram.review.csv"))?,
        "kind,text,count,candidate_readings,first_file,first_line,reading\n"
    );

    let resources = EngineResources::open(
        &scratch.0.join("seed.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    let lexicon = resources.lexicon();
    let [letter, number, pr] =
        ["<char>", "<num>", "PR"].map(|text| lexicon.find_word(text).unwrap());
    let bank = lexicon.find_word("银行").unwrap();
    let walk = lexicon.find_word("行走").unwrap();
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
    assert_eq!(grams.count(&[letter, walk]), Some(1));
    assert_eq!(grams.count(&[bank, number, pr, letter]), Some(1));
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
    scratch.write("paragraphs.txt", "Rust engine。甲\nA 404\n")?;
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
    let [letter, number] = ["<char>", "<num>"].map(|word| saved.lexicon().find_word(word).unwrap());
    assert!(saved.lexicon().find_word("Rust").is_none());
    assert!(saved.lexicon().find_word("engine").is_none());
    assert!(saved.lexicon().find_word("甲").is_none());
    assert_eq!(saved.grams().unwrap().count(&[letter, number]), Some(1));
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
    assert_eq!(repeated.lexicon().len(), 4);
    assert_eq!(repeated.grams().unwrap().count(&[letter, number]), Some(2));
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

    for (language, index) in [("zh-Hans", "0"), ("en", "1")] {
        let destination = format!("{language}.silex.csv");
        scratch.run(&[
            "lexicon",
            "export",
            "--language",
            language,
            "original.silex",
            &destination,
        ])?;
        let expected = if index == "0" {
            concat!(
                "kind,id,text,weight,index,reading,key_hex\n",
                "word,0,重,7,0,chong,\nword,1,重,3,0,zhong,\nword,2,庆,120,0,qing,\n",
                "alias,0,,,2,cz,\nalias,0,,,4294967295,,00ff\n",
            )
        } else {
            concat!(
                "kind,id,text,weight,index,reading,key_hex\n",
                "word,3,\"a, \"\"title\"\"\r\n第二行\",18446744073709551615,1,,0080\n",
            )
        };
        assert_eq!(fs::read_to_string(scratch.0.join(destination))?, expected);
    }

    scratch.run(&[
        "lexicon",
        "update",
        "restored.silex",
        "0",
        "chong",
        "重",
        "5",
    ])?;
    let extended = EngineResources::open(&scratch.0.join("restored.silex"), Some(&grams_path))?;
    assert_eq!(extended.lexicon().find_word("庆"), Some(qing.id));
    let aliased = extended.lexicon().exact(IndexId(2), b"cz").next().unwrap();
    assert_eq!((aliased.id, aliased.count), (chong.id, 5));
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
fn lexicon_add_appends_new_id_preserves_existing_entries_and_rejects_duplicates() -> io::Result<()>
{
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "snapshot.csv",
        concat!(
            "kind,id,text,weight,index,reading,key_hex\n",
            "word,0,重,7,0,chong,\nword,1,庆,9,0,qing,\nalias,0,,,2,cz,\n",
        ),
    )?;
    scratch.run(&["lexicon", "restore", "snapshot.csv", "base.silex"])?;
    scratch.write("tokens.txt", "重 庆\n")?;
    scratch.run(&["corpus", "build", "base.silex", "base.sigram", "tokens.txt"])?;
    let path = scratch.0.join("base.silex");
    let grams_path = scratch.0.join("base.sigram");
    let original = EngineResources::open(&path, Some(&grams_path))?;
    let gram_bytes = fs::read(&grams_path)?;
    let output = scratch.run(&["lexicon", "add", "base.silex", "0", "cha", "茶", "1000"])?;
    assert!(String::from_utf8_lossy(&output.stdout).contains("Added word."));
    let updated = EngineResources::open(&path, Some(&grams_path))?;
    let id = updated
        .lexicon()
        .find_reading(IndexId(0), b"cha", "茶")
        .unwrap();
    assert_eq!(id.0 as usize, original.lexicon().len());
    assert_eq!(updated.lexicon().word(id).unwrap().count, 1000);
    for word in original.lexicon().words() {
        assert_eq!(updated.lexicon().word(word.id), Some(word));
    }
    assert_eq!(
        updated.lexicon().exact(IndexId(2), b"cz").next(),
        original.lexicon().exact(IndexId(2), b"cz").next()
    );
    assert_eq!(
        updated.grams().unwrap().sizes(),
        original.grams().unwrap().sizes()
    );
    assert_eq!(fs::read(&grams_path)?, gram_bytes);
    let saved = fs::read(&path)?;
    for count in ["1000", "0", "18446744073709551615"] {
        let duplicate = scratch
            .command(&["lexicon", "add", "base.silex", "0", "cha", "茶", count])
            .output()?;
        assert!(!duplicate.status.success());
        assert!(
            String::from_utf8_lossy(&duplicate.stderr).contains("word identity already exists")
        );
        assert_eq!(fs::read(&path)?, saved);
    }
    // Different primary readings, lookup indices and output bytes remain distinct identities.
    for (index, reading, text, count) in [
        ("0", "zhong", "重", "0"),
        ("1", "cha", "茶", "18446744073709551615"),
        ("0", "cha", "查", "1"),
    ] {
        scratch.run(&["lexicon", "add", "base.silex", index, reading, text, count])?;
        let resources = EngineResources::open(&path, Some(&grams_path))?;
        let id = resources
            .lexicon()
            .find_reading(IndexId(index.parse().unwrap()), reading.as_bytes(), text)
            .unwrap();
        assert_eq!(
            resources.lexicon().word(id).unwrap().count,
            count.parse::<u64>().unwrap()
        );
    }
    assert_eq!(fs::read(&grams_path)?, gram_bytes);
    Ok(())
}

#[test]
fn lexicon_add_rejects_invalid_arguments_missing_snapshots_and_pending_ingestion() -> io::Result<()>
{
    let scratch = ScratchDirectory::new()?;
    scratch.write("seed.csv", "text,reading,weight\n把,ba,7\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "seed.csv"])?;
    let path = scratch.0.join("base.silex");
    let saved = fs::read(&path)?;
    for (index, reading, text, count) in [
        ("0", "", "茶", "1"),
        ("0", " ", "茶", "1"),
        ("0", "cha\n", "茶", "1"),
        ("0", "cha", "", "1"),
        ("0", "cha", " ", "1"),
        ("0", "cha", "茶\n", "1"),
        ("bad", "cha", "茶", "1"),
        ("0", "cha", "茶", "-1"),
        ("0", "cha", "茶", "1.5"),
        ("0", "cha", "茶", "18446744073709551616"),
    ] {
        assert!(
            !scratch
                .command(&["lexicon", "add", "base.silex", index, reading, text, count])
                .output()?
                .status
                .success()
        );
        assert_eq!(fs::read(&path)?, saved);
    }
    let missing = scratch
        .command(&["lexicon", "add", "missing.silex", "0", "cha", "茶", "1"])
        .output()?;
    assert!(!missing.status.success());
    assert!(!scratch.0.join("missing.silex").exists());
    let pending = scratch.0.join("base.silex.ingest-pending");
    fs::create_dir(&pending)?;
    let rejected = scratch
        .command(&["lexicon", "add", "base.silex", "0", "cha", "茶", "1"])
        .output()?;
    assert!(!rejected.status.success());
    assert!(String::from_utf8_lossy(&rejected.stderr).contains("pending corpus ingest"));
    assert_eq!(fs::read(&path)?, saved);
    Ok(())
}

#[test]
fn concurrent_lexicon_adds_reject_duplicates_and_preserve_distinct_new_words() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("seed.csv", "text,reading,weight\n把,ba,7\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "seed.csv"])?;
    let mut first = scratch
        .command(&["lexicon", "add", "base.silex", "0", "cha", "茶", "1"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    let mut second = scratch
        .command(&["lexicon", "add", "base.silex", "0", "cha", "茶", "2"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    assert_ne!(first.wait()?.success(), second.wait()?.success());
    let resources = EngineResources::open(&scratch.0.join("base.silex"), None)?;
    let word = resources
        .lexicon()
        .word(resources.lexicon().find_word("茶").unwrap())
        .unwrap();
    assert!(matches!(word.count, 1 | 2));
    let mut first = scratch
        .command(&["lexicon", "add", "base.silex", "0", "jia", "甲", "1"])
        .stdout(Stdio::null())
        .spawn()?;
    let mut second = scratch
        .command(&["lexicon", "add", "base.silex", "0", "yi", "乙", "2"])
        .stdout(Stdio::null())
        .spawn()?;
    assert!(first.wait()?.success());
    assert!(second.wait()?.success());
    let resources = EngineResources::open(&scratch.0.join("base.silex"), None)?;
    assert_eq!(resources.lexicon().len(), 4);
    assert!(resources.lexicon().find_word("甲").is_some());
    assert!(resources.lexicon().find_word("乙").is_some());
    Ok(())
}

#[test]
fn lexicon_update_sets_only_one_existing_primary_identity_and_keeps_grams() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "snapshot.csv",
        concat!(
            "kind,id,text,weight,index,reading,key_hex\n",
            "word,0,重,7,0,chong,\nword,1,重,3,0,zhong,\n",
            "word,2,庆,9,0,qing,\nword,3,重,11,1,chong,\n",
            "alias,0,,,2,cz,\n",
        ),
    )?;
    scratch.run(&["lexicon", "restore", "snapshot.csv", "base.silex"])?;
    scratch.write("tokens.txt", "重|0|chong 庆\n")?;
    scratch.run(&["corpus", "build", "base.silex", "base.sigram", "tokens.txt"])?;
    let path = scratch.0.join("base.silex");
    let grams = scratch.0.join("base.sigram");
    let before = EngineResources::open(&path, Some(&grams))?;
    let original_grams = fs::read(&grams)?;
    let id = before
        .lexicon()
        .find_reading(IndexId(0), b"chong", "重")
        .unwrap();
    let other = before.lexicon().find_word("庆").unwrap();
    let keys: Vec<_> = before
        .lexicon()
        .lookup_keys()
        .map(|(key, id)| (key.index, key.key.to_vec(), id))
        .collect();
    for count in ["120000000", "120000000", "0", "18446744073709551615", "7"] {
        let output =
            scratch.run(&["lexicon", "update", "base.silex", "0", "chong", "重", count])?;
        assert!(String::from_utf8_lossy(&output.stdout).contains("Updated word frequency"));
        let updated = EngineResources::open(&path, Some(&grams))?;
        assert_eq!(updated.lexicon().len(), before.lexicon().len());
        for word in before.lexicon().words() {
            let actual = updated.lexicon().word(word.id).unwrap();
            assert_eq!(
                (actual.id, actual.text, actual.reading),
                (word.id, word.text, word.reading)
            );
            assert_eq!(
                actual.count,
                if word.id == id {
                    count.parse::<u64>().unwrap()
                } else {
                    word.count
                }
            );
        }
        assert_eq!(
            updated
                .lexicon()
                .lookup_keys()
                .map(|(key, id)| (key.index, key.key.to_vec(), id))
                .collect::<Vec<_>>(),
            keys
        );
        assert_eq!(fs::read(&grams)?, original_grams);
        assert_eq!(updated.grams().unwrap().count(&[id, other]), Some(1));
        // Setting an existing count again is a byte-preserving no-op.
        let saved = fs::read(&path)?;
        scratch.run(&["lexicon", "update", "base.silex", "0", "chong", "重", count])?;
        assert_eq!(fs::read(&path)?, saved);
    }
    let saved = fs::read(&path)?;
    let alias = scratch
        .command(&["lexicon", "update", "base.silex", "2", "cz", "重", "10"])
        .output()?;
    assert!(!alias.status.success());
    assert!(String::from_utf8_lossy(&alias.stderr).contains("word identity is absent"));
    assert_eq!(fs::read(&path)?, saved);
    Ok(())
}

#[test]
fn lexicon_update_rejects_missing_words_bad_arguments_and_pending_ingestion() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("words.csv", "text,reading,weight\n把,ba,7\n吧,ba,3\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "words.csv"])?;
    let path = scratch.0.join("base.silex");
    let saved = fs::read(&path)?;
    for args in [
        vec!["lexicon", "update", "base.silex", "0", "ba", "不存在", "10"],
        vec!["lexicon", "update", "base.silex", "1", "ba", "把", "10"],
        vec!["lexicon", "update", "base.silex", "0", "b", "把", "10"],
        vec!["lexicon", "update", "base.silex", "0", "", "把", "10"],
        vec!["lexicon", "update", "base.silex", "bad", "ba", "把", "10"],
        vec!["lexicon", "update", "base.silex", "0", "ba", "把", "-1"],
        vec![
            "lexicon",
            "update",
            "base.silex",
            "0",
            "ba",
            "把",
            "18446744073709551616",
        ],
        vec!["lexicon", "update", "base.silex", "0", "ba", "把", "1.5"],
        vec!["lexicon", "update", "base.silex", "0", "ba", "把"],
        vec![
            "lexicon",
            "update",
            "base.silex",
            "0",
            "ba",
            "把",
            "10",
            "extra",
        ],
        vec!["lexicon", "add", "base.silex", "0", "words.csv"],
        vec!["lexicon", "import", "base.silex", "0", "words.csv"],
    ] {
        assert!(
            !scratch.command(&args).output()?.status.success(),
            "{args:?}"
        );
        assert_eq!(fs::read(&path)?, saved);
    }
    let missing = scratch
        .command(&["lexicon", "update", "missing.silex", "0", "ba", "把", "10"])
        .output()?;
    assert!(!missing.status.success());
    assert!(!scratch.0.join("missing.silex").exists());
    let pending = scratch.0.join("base.silex.ingest-pending");
    fs::create_dir(&pending)?;
    let rejected = scratch
        .command(&["lexicon", "update", "base.silex", "0", "ba", "把", "10"])
        .output()?;
    assert!(!rejected.status.success());
    assert!(String::from_utf8_lossy(&rejected.stderr).contains("pending corpus ingest"));
    assert_eq!(fs::read(&path)?, saved);
    Ok(())
}

#[test]
fn simultaneous_lexicon_updates_preserve_each_others_counts() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("words.csv", "text,reading,weight\n把,ba,7\n吧,ba,3\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "words.csv"])?;
    let mut first = scratch
        .command(&["lexicon", "update", "base.silex", "0", "ba", "把", "100"])
        .stdout(Stdio::null())
        .spawn()?;
    let mut second = scratch
        .command(&["lexicon", "update", "base.silex", "0", "ba", "吧", "200"])
        .stdout(Stdio::null())
        .spawn()?;
    assert!(first.wait()?.success());
    assert!(second.wait()?.success());
    let resources = EngineResources::open(&scratch.0.join("base.silex"), None)?;
    for (text, count) in [("把", 100), ("吧", 200)] {
        let id = resources.lexicon().find_word(text).unwrap();
        assert_eq!(resources.lexicon().word(id).unwrap().count, count);
    }
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
fn corpus_prune_replaces_only_the_requested_order_and_checks_the_lexicon() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "words.csv",
        "text,reading,weight\n甲,jia,1\n乙,yi,1\n丙,bing,1\n丁,ding,1\n",
    )?;
    scratch.write(
        "reordered.csv",
        "text,reading,weight\n乙,yi,1\n甲,jia,1\n丙,bing,1\n丁,ding,1\n",
    )?;
    scratch.write("source.txt", "甲 乙 丙 丁\n甲 乙 丙 丁\n乙 丙 丁 甲\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "words.csv"])?;
    scratch.run(&["lexicon", "build", "other.silex", "0", "reordered.csv"])?;
    scratch.run(&["corpus", "build", "base.silex", "base.sigram", "source.txt"])?;

    let lexicon_path = scratch.0.join("base.silex");
    let gram_path = scratch.0.join("base.sigram");
    let original_lexicon = fs::read(&lexicon_path)?;
    let original_grams = fs::read(&gram_path)?;
    let mut prune = [
        "corpus",
        "prune",
        "--order",
        "4",
        "--min-count",
        "2",
        "other.silex",
        "base.sigram",
    ];
    let rejected = scratch.command(&prune).output()?;
    assert!(!rejected.status.success());
    assert!(String::from_utf8_lossy(&rejected.stderr).contains("word order does not match"));
    assert_eq!(fs::read(&gram_path)?, original_grams);

    prune[6] = "base.silex";
    let output = scratch.run(&prune)?;
    assert!(String::from_utf8_lossy(&output.stdout).contains("Removed 1 order-4 rows"));
    let resources = EngineResources::open(&lexicon_path, Some(&gram_path))?;
    let [a, b, c, d] =
        ["甲", "乙", "丙", "丁"].map(|word| resources.lexicon().find_word(word).unwrap());
    let grams = resources.grams().unwrap();
    assert_eq!(grams.count(&[d, a]), Some(1));
    assert_eq!(grams.count(&[c, d, a]), Some(1));
    assert_eq!(grams.count(&[a, b, c, d]), Some(2));
    assert_eq!(grams.count(&[b, c, d, a]), None);
    assert_eq!(fs::read(&lexicon_path)?, original_lexicon);

    let pruned = fs::read(&gram_path)?;
    let output = scratch.run(&prune)?;
    assert!(String::from_utf8_lossy(&output.stdout).contains("Removed 0 order-4 rows"));
    assert_eq!(fs::read(&gram_path)?, pruned);
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
        .command(&["lexicon", "build", "rejected.silex", "0", "missing.csv"])
        .output()?;
    assert!(!failure.status.success());
    assert!(String::from_utf8_lossy(&failure.stderr).contains("missing.csv:3: missing reading"));
    assert_eq!(fs::read(path)?, before);
    Ok(())
}

#[test]
fn han_corpus_learns_only_bigrams_even_with_higher_order_settings() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "seed.csv",
        "text,reading,weight\n深,shen,1\n海,hai,2\n探,tan,3\n测,ce,4\n重,chong,5\n重,zhong,0\n庆,qing,6\n",
    )?;
    scratch.write("english.csv", "text,reading,weight\nA,a,1\n")?;
    scratch.write("existing.csv", "text,reading,weight\n探测,tan'ce,99\n")?;
    scratch.run(&[
        "lexicon",
        "build",
        "base.silex",
        "0",
        "seed.csv",
        "1",
        "english.csv",
        "0",
        "existing.csv",
    ])?;
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
    scratch.learning_config(0, 4, 0, 0, 0)?;
    let mut config = fs::read_to_string(scratch.0.join("learning.conf"))?;
    config.push_str(concat!(
        "min_count_3 = 1\nmin_forward_percent_3 = 0\nmin_backward_percent_3 = 0\nmin_lift_3 = 0\n",
        "min_count_4 = 1\nmin_forward_percent_4 = 0\nmin_backward_percent_4 = 0\nmin_lift_4 = 0\n",
    ));
    scratch.write("learning.conf", &config)?;
    let learn = [
        "lexicon",
        "learn",
        "base.silex",
        "base.sigram",
        "learning.conf",
    ];
    let output = scratch.run(&learn)?;
    assert!(String::from_utf8_lossy(&output.stdout).contains("Added 2 words."));
    assert!(!scratch.0.join("base.silex.review-1.csv").exists());

    let resources = EngineResources::open(&lexicon_path, None)?;
    let lexicon = resources.lexicon();
    let pinyin = IndexId(0);
    for (key, expected_text, count) in [("shen'hai", "深海", 4), ("chong'qing", "重庆", 4)] {
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
    assert!(lexicon.find_word("深海探").is_none());
    assert!(lexicon.find_word("深海探测").is_none());
    assert!(lexicon.exact(pinyin, b"zhong'qing").next().is_none());
    assert!(lexicon.exact(IndexId(1), b"chong'qing").next().is_none());
    assert_eq!(fs::read(&gram_path)?, gram_bytes);

    let before_retry = fs::read(&lexicon_path)?;
    let retry = scratch.run(&learn)?;
    assert!(String::from_utf8_lossy(&retry.stdout).contains("Added 0 words."));
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
    assert!(expanded.exact(pinyin, b"hai'tan'ce").next().is_none());

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

    let pruned = scratch.run(&[
        "corpus",
        "prune",
        "--order",
        "4",
        "--min-count",
        "4",
        "base.silex",
        "base.sigram",
    ])?;
    assert!(String::from_utf8_lossy(&pruned.stdout).contains("Removed 1 order-4 rows"));
    let updated = scratch.run(&[
        "corpus",
        "add",
        "--han",
        "base.silex",
        "base.sigram",
        "later.txt",
    ])?;
    assert!(String::from_utf8_lossy(&updated.stdout).contains("and 1 four-grams"));
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
    scratch.learning_config(0, 1, 0, 0, 0)?;
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
    let build_review = [
        "lexicon",
        "build",
        "reviewed.silex",
        "0",
        "seed.csv",
        "0",
        review_name,
    ];
    assert!(!scratch.command(&build_review).output()?.status.success());
    assert_eq!(fs::read(&path)?, before_review);

    let edited = "text,reading,weight\n𠼞茶,a'cha,2\n";
    fs::write(&first, edited)?;
    scratch.run(&learn)?;
    assert_eq!(fs::read_to_string(first)?, edited);
    assert_eq!(
        fs::read_to_string(scratch.0.join("base.silex.review-2.csv"))?,
        report
    );

    scratch.run(&build_review)?;
    let reviewed = EngineResources::open(&scratch.0.join("reviewed.silex"), None)?;
    let word = reviewed
        .lexicon()
        .exact(IndexId(0), b"a'cha")
        .next()
        .unwrap();
    assert_eq!(word.text, "𠼞茶");
    assert_eq!(word.count, 2);
    assert_eq!(fs::read(&path)?, before_review);
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
        .command(&["lexicon", "build", "rejected.silex", "0", "bad.csv"])
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

    scratch.run(&[
        "lexicon",
        "update",
        "main.silex",
        "0",
        "alpha",
        "alpha",
        "4",
    ])?;
    scratch.run(&["corpus", "add", "main.silex", "main.sigram", "words.txt"])?;
    let resources = EngineResources::open(&lexicon_path, Some(&gram_path))?;
    assert_eq!(resources.lexicon().find_word("alpha"), Some(a));
    assert_eq!(resources.lexicon().find_word("beta"), Some(b));
    assert_eq!(resources.lexicon().word(a).unwrap().count, 4);
    assert_eq!(resources.grams().unwrap().count(&[a, b]), Some(2));
    assert_eq!(&fs::read(&lexicon_path)?[..8], b"SILEX\0\x03\0");
    assert_eq!(&fs::read(&gram_path)?[..8], b"SIGRAM\x03\0");
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
                Ok(()) => {
                    let directory = Self(path);
                    directory.write("fixture-defaults.conf", TEST_CONFIG)?;
                    return Ok(directory);
                }
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
        count: u64,
        forward: u8,
        backward: u8,
        lift: u32,
    ) -> io::Result<()> {
        let settings = format!(
            "pinyin_index = {index}\nmin_count_2 = {count}\nmin_forward_percent_2 = {forward}\nmin_backward_percent_2 = {backward}\nmin_lift_2 = {lift}\n"
        );
        self.write("learning.conf", &settings)
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_si-cli"));
        command.current_dir(&self.0);
        if args.first() != Some(&"--config") {
            command.args(["--config", "fixture-defaults.conf"]);
        }
        command.args(args);
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

const TEST_CONFIG: &str = "[base]
max_order = 4
pinyin_index = 0
min_count_2 = 40000
min_forward_percent_2 = 4
min_backward_percent_2 = 4
min_lift_2 = 10

[user]
max_order = 4
pinyin_index = 0
min_count_2 = 5
min_forward_percent_2 = 30
min_backward_percent_2 = 30
min_lift_2 = 2
";

#[test]
fn paragraph_and_user_ingestion_choose_the_complete_frequency_path() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("words.csv", "text,reading,weight\n没有,mei'you,78908345\n没有输,mei'you'shu,155\n输入法,shu'ru'fa,472646\n入,ru,1746243\n法,fa,2191827\n")?;
    scratch.write("sentences.txt", "没有输入法\n没有输入法\n")?;
    scratch.run(&["lexicon", "build", "base.silex", "0", "words.csv"])?;
    let store = UserModelStore::new(scratch.0.join("profile.si-user"));
    // Existing incorrect user evidence must not overwhelm the base frequencies.
    store.edit_entry(
        None,
        Some(&si_engine::resources::user::UserEntry {
            text: "没有输".into(),
            reading: Some((0, b"mei'you'shu".to_vec())),
            count: u64::MAX - 1,
        }),
    )?;
    scratch.run(&[
        "user",
        "ingest",
        "profile.si-user",
        "base.silex",
        "first",
        "sentences.txt",
    ])?;
    let user = store.load()?.unwrap();
    assert!(user.lexicon().find_word("<s>").is_none());
    assert!(user.lexicon().find_word("</s>").is_none());
    let no = user.lexicon().find_word("没有").unwrap();
    let ime = user.lexicon().find_word("输入法").unwrap();
    assert_eq!(user.lexicon().word(no).unwrap().count, 2);
    assert_eq!(user.lexicon().word(ime).unwrap().count, 2);
    assert!(user.lexicon().find_word("入").is_none());
    assert_eq!(user.grams().unwrap().count(&[no, ime]), Some(2));
    let old = user.lexicon().find_word("没有输").unwrap();
    assert_eq!(user.lexicon().word(old).unwrap().count, u64::MAX - 1);

    scratch.run(&[
        "corpus",
        "ingest",
        "base.silex",
        "words.sigram",
        "sentences.txt",
    ])?;
    let base = EngineResources::open(
        &scratch.0.join("base.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    let no = base.lexicon().find_word("没有").unwrap();
    let ime = base.lexicon().find_word("输入法").unwrap();
    let wrong = base.lexicon().find_word("没有输").unwrap();
    assert_eq!(base.lexicon().word(no).unwrap().count, 78_908_347);
    assert_eq!(base.lexicon().word(ime).unwrap().count, 472_648);
    assert_eq!(base.lexicon().word(wrong).unwrap().count, 155);
    assert_eq!(base.grams().unwrap().count(&[no, ime]), Some(2));
    Ok(())
}

#[test]
fn paragraph_ingest_wrappers_preserve_adjacency_without_inventing_sentence_starts() -> io::Result<()>
{
    let scratch = ScratchDirectory::new()?;
    scratch.write("seed.csv", "text,reading,weight\n看过,kan'guo,1\n青蛇,qing'she,1\n你,ni,1\n战争之王,zhan'zheng'zhi'wang,1\n唐伯虎点秋香,tang'bo'hu'dian'qiu'xiang,1\n第,di,1\n届,jie,1\n奥斯卡金像奖,ao'si'ka'jin'xiang'jiang,1\n最佳动画长片,zui'jia'dong'hua'chang'pian,1\n提名,ti'ming,1\n吧,ba,1\n看过青蛇,kan'guo'qing'she,1000000\n")?;
    scratch.run(&["lexicon", "build", "main.silex", "0", "seed.csv"])?;
    scratch.write(
        "paragraphs.txt",
        concat!(
            "看过《青蛇》吧？\n",
            "你看过《战争之王》吧?\n",
            "看过《唐伯虎点秋香》吧？\n",
            "第78届奥斯卡金像奖最佳动画长片(提名)吧。\n",
        ),
    )?;
    scratch.run(&[
        "corpus",
        "ingest",
        "main.silex",
        "words.sigram",
        "paragraphs.txt",
    ])?;
    let model = EngineResources::open(
        &scratch.0.join("main.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    let ids = |text| model.lexicon().find_word(text).unwrap();
    let start = ids("<s>");
    let end = ids("</s>");
    let ba = ids("吧");
    let grams = model.grams().unwrap();
    assert_eq!(grams.count(&[start, ba]), None);
    assert_eq!(grams.count(&[ba, end]), Some(4));
    for title in ["青蛇", "战争之王", "唐伯虎点秋香", "提名"] {
        assert_eq!(grams.count(&[ids(title), ba, end]), Some(1));
        assert_eq!(grams.count(&[start, ids(title)]), None);
    }
    assert_eq!(grams.count(&[ids("看过"), ids("青蛇"), ba]), Some(1));
    assert_eq!(
        model.lexicon().word(ids("看过青蛇")).unwrap().count,
        1_000_000
    );
    Ok(())
}

#[test]
fn paragraph_ingest_ignores_wrappers_but_only_explicit_delimiters_restart_fragments()
-> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write(
        "seed.csv",
        "text,reading,weight\n甲,jia,1\n乙,yi,1\n丙,bing,1\n",
    )?;
    scratch.run(&["lexicon", "build", "main.silex", "0", "seed.csv"])?;
    scratch.write(
        "paragraphs.txt",
        concat!(
            "甲《乙》丙\n甲〈乙〉丙\n甲“乙”丙\n甲‘乙’丙\n",
            "甲「乙」丙\n甲『乙』丙\n甲（乙）丙\n甲(乙)丙\n",
            "甲【乙】丙\n甲[乙]丙\n甲\"乙\"丙\n甲'乙'丙\n",
            "甲：“乙。”\n甲!（乙）\n《乙》\n",
            "甲/乙\n甲$乙\n甲🙂乙\n",
            "甲，\n甲,\n甲。\n甲！\n甲!\n甲？\n甲?\n甲；\n甲;\n甲：\n甲:\n甲…\n甲.\n",
            "《》“”()[]\n",
        ),
    )?;
    scratch.run(&[
        "corpus",
        "ingest",
        "main.silex",
        "words.sigram",
        "paragraphs.txt",
    ])?;
    let model = EngineResources::open(
        &scratch.0.join("main.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    let [start, end, a, b, c] =
        ["<s>", "</s>", "甲", "乙", "丙"].map(|text| model.lexicon().find_word(text).unwrap());
    let grams = model.grams().unwrap();
    assert_eq!(grams.count(&[a, b, c]), Some(12));
    assert_eq!(grams.count(&[start, b]), Some(3));
    assert_eq!(grams.count(&[a, end]), Some(15));
    assert_eq!(grams.count(&[b, end]), Some(6));
    assert_eq!(grams.count(&[start, end]), None);
    Ok(())
}

#[test]
fn paragraph_ingest_internal_periods_do_not_create_boundary_markers() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    scratch.write("seed.csv", "text,reading,weight\n甲,jia,1\n乙,yi,1\n")?;
    scratch.write(
        "english.csv",
        "text,reading,weight\nNode.js,nodejs,1\nexample.com,example.com,1\n3.14,decimal,1\n",
    )?;
    scratch.run(&[
        "lexicon",
        "build",
        "main.silex",
        "0",
        "seed.csv",
        "1",
        "english.csv",
    ])?;
    scratch.write(
        "paragraphs.txt",
        "甲 Node.js 乙\n甲 example.com 乙\n甲 3.14 乙\n",
    )?;
    scratch.run(&[
        "corpus",
        "ingest",
        "main.silex",
        "words.sigram",
        "paragraphs.txt",
    ])?;
    let model = EngineResources::open(
        &scratch.0.join("main.silex"),
        Some(&scratch.0.join("words.sigram")),
    )?;
    let id = |text| model.lexicon().find_word(text).unwrap();
    for word in ["Node.js", "example.com", "3.14"] {
        assert_eq!(
            model
                .grams()
                .unwrap()
                .count(&[id("甲"), id(word), id("乙")]),
            Some(1)
        );
    }
    assert_eq!(model.grams().unwrap().count(&[id("<s>"), id("乙")]), None);
    Ok(())
}
