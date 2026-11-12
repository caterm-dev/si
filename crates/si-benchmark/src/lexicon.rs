use std::error::Error;
use std::fs;
use std::hint::black_box;
use std::time::Instant;

use si_lexicon::{IndexId, Lexicon, WordId};

use crate::support::{ScratchDirectory, measure};

const FULL: IndexId = IndexId(0);
const ABBREVIATED: IndexId = IndexId(1);

pub(crate) fn run(words: u32, queries: u32) -> Result<(), Box<dyn Error>> {
    println!("Lexicon | {words} synthetic words | {queries} queries per case");
    let mut lexicon = Lexicon::new();
    let start = Instant::now();
    for ordinal in 0..words {
        let text = format!("词{ordinal}");
        let key = key_for(ordinal / 4);
        let word = lexicon.add_reading(FULL, &key, &text, u64::from(ordinal % 1_000) + 1)?;
        lexicon.add_key(ABBREVIATED, &key[4..], word)?;
    }
    println!("Build editable dictionary  {:>10.2?}", start.elapsed());
    let start = Instant::now();
    lexicon.compact()?;
    println!("Compact lookup indexes    {:>10.2?}", start.elapsed());

    let path = ScratchDirectory::new()?;
    let dictionary = path.0.join("benchmark.silex");
    let start = Instant::now();
    lexicon.save(&dictionary)?;
    println!("Save snapshot (sync)       {:>10.2?}", start.elapsed());
    let bytes = fs::metadata(&dictionary)?.len();
    println!(
        "Snapshot size              {bytes:>10} B ({:.1} B/word)",
        bytes as f64 / f64::from(words)
    );
    drop(lexicon);
    let start = Instant::now();
    let mut lexicon = Lexicon::open(&dictionary)?;
    println!("Open and validate (warm)  {:>10.2?}", start.elapsed());

    let mut state = 0x5b64_29c1_fade_11c5_u64;
    let fixtures: Vec<_> = (0..4096)
        .map(|_| {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let ordinal = ((state >> 32) as u32) % words;
            let hit = key_for(ordinal / 4);
            let mut miss = hit;
            miss[6] = 0xff;
            let id = WordId(ordinal);
            (hit, miss, id)
        })
        .collect();

    println!("\nQuery times per operation (percentiles of batch averages)");
    measure("Exact hit", queries, |i| {
        let (hit, _, _) = &fixtures[i % fixtures.len()];
        black_box(
            lexicon
                .exact(FULL, black_box(hit))
                .map(|word| word.count)
                .sum::<u64>(),
        );
    });
    measure("Exact miss", queries, |i| {
        let (_, miss, _) = &fixtures[i % fixtures.len()];
        black_box(lexicon.exact(FULL, black_box(miss)).next());
    });
    measure("Prefix, first 8 matches", queries, |i| {
        let (hit, _, _) = &fixtures[i % fixtures.len()];
        black_box(
            lexicon
                .prefix(FULL, black_box(&hit[..6]))
                .take(8)
                .map(|(_, word)| word.count)
                .sum::<u64>(),
        );
    });
    measure("Word by ID", queries, |i| {
        let (_, _, id) = fixtures[i % fixtures.len()];
        black_box(lexicon.word(black_box(id)));
    });

    let start = Instant::now();
    for edit in 0..1_000 {
        let (key, _, _) = &fixtures[edit % fixtures.len()];
        lexicon.add_reading(FULL, key, &format!("新词{edit}"), 1)?;
    }
    println!("\nAdd 1,000 words and keys  {:>10.2?}", start.elapsed());
    measure("Exact hit with edits", queries, |i| {
        let (hit, _, _) = &fixtures[i % fixtures.len()];
        black_box(
            lexicon
                .exact(FULL, black_box(hit))
                .map(|word| word.count)
                .sum::<u64>(),
        );
    });
    Ok(())
}

fn key_for(mut value: u32) -> [u8; 7] {
    let mut key = [b'a'; 7];
    for letter in key.iter_mut().rev() {
        *letter += (value % 26) as u8;
        value /= 26;
    }
    key
}
