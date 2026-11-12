use std::error::Error;
use std::fs;
use std::hint::black_box;
use std::time::Instant;

use si_gram::{GramBuilder, GramModel};
use si_lexicon::WordId;

use crate::support::{ScratchDirectory, measure};

pub(crate) fn run(rows: u32, queries: u32) -> Result<(), Box<dyn Error>> {
    println!("Gram | {rows} synthetic grams per order | {queries} queries per case");
    let mut builder = GramBuilder::new();
    let start = Instant::now();
    for index in 0..rows {
        let (two, three, four, five) = fixture(index);
        let count = u64::from(index % 100) + 1;
        builder.add(&two, count)?;
        builder.add(&three, count)?;
        builder.add(&four, count)?;
        builder.add(&five, count)?;
    }
    println!("Accumulate raw counts     {:>10.2?}", start.elapsed());
    let start = Instant::now();
    let model = builder.finish()?;
    println!("Build lookup tables       {:>10.2?}", start.elapsed());
    assert_eq!(model.sizes(), [rows as usize; 4]);

    let scratch = ScratchDirectory::new()?;
    let path = scratch.0.join("benchmark.sigram");
    let start = Instant::now();
    model.save(&path)?;
    println!("Save snapshot (sync)      {:>10.2?}", start.elapsed());
    let bytes = fs::metadata(&path)?.len();
    println!(
        "Snapshot size             {bytes:>10} B ({:.1} B/gram)",
        bytes as f64 / (4.0 * f64::from(rows))
    );
    drop(model);
    let start = Instant::now();
    let model = GramModel::open(&path)?;
    println!("Open and validate (warm)  {:>10.2?}", start.elapsed());

    let mut state = 0x517c_c1b7_2722_0a95_u64;
    let fixtures: Vec<_> = (0..4096)
        .map(|_| {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let index = ((state >> 32) as u32) % rows;
            fixture(index)
        })
        .collect();
    let contexts: Vec<_> = fixtures
        .iter()
        .map(|(_, _, _, key)| (model.context(&key[..4]), key[4]))
        .collect();

    println!("\nQuery times per operation (percentiles of batch averages)");
    measure("2-gram hit", queries, |i| {
        black_box(model.count(black_box(&fixtures[i % fixtures.len()].0)));
    });
    measure("3-gram hit", queries, |i| {
        black_box(model.count(black_box(&fixtures[i % fixtures.len()].1)));
    });
    measure("4-gram hit", queries, |i| {
        black_box(model.count(black_box(&fixtures[i % fixtures.len()].2)));
    });
    measure("5-gram hit", queries, |i| {
        black_box(model.count(black_box(&fixtures[i % fixtures.len()].3)));
    });
    measure("4-gram miss", queries, |i| {
        let mut miss = fixtures[i % fixtures.len()].2;
        miss[3] = WordId(u32::MAX);
        black_box(model.count(black_box(&miss)));
    });
    measure("5-gram prepared hit", queries, |i| {
        let (context, next) = &contexts[i % contexts.len()];
        black_box(context.count(black_box(*next)));
    });
    measure("4-gram context + first 8", queries, |i| {
        let (_, _, key, _) = &fixtures[i % fixtures.len()];
        let context = model.context(black_box(&key[..3]));
        black_box(
            context
                .continuations()
                .take(8)
                .map(|(_, count)| count)
                .sum::<u64>(),
        );
    });
    Ok(())
}

fn fixture(index: u32) -> ([WordId; 2], [WordId; 3], [WordId; 4], [WordId; 5]) {
    let next = index % 16;
    let previous = (index / 16) % 16;
    (
        [index / 16, next].map(WordId),
        [index / 256, previous, next].map(WordId),
        [index / 4096, (index / 256) % 16, previous, next].map(WordId),
        [
            index / 65536,
            (index / 4096) % 16,
            (index / 256) % 16,
            previous,
            next,
        ]
        .map(WordId),
    )
}
