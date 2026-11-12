use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use si_gram::{BuildError, GramBuilder, GramModel};
use si_lexicon::WordId;

#[test]
fn observing_counts_overlapping_windows_within_each_sequence() {
    let [a, b, c, d] = [0, 1, 2, 3].map(WordId);
    let mut builder = GramBuilder::new();
    builder.observe(&[a, b, a, b, a]).unwrap();
    builder.observe(&[c, d]).unwrap();
    builder.observe(&[a]).unwrap();
    let model = builder.finish().unwrap();

    assert_eq!(model.sizes(), [3, 2, 2]);
    assert_eq!(model.count(&[a, b]), Some(2));
    assert_eq!(model.count(&[b, a]), Some(2));
    assert_eq!(model.count(&[c, d]), Some(1));
    assert_eq!(model.count(&[a, c]), None);
    assert_eq!(model.count(&[a, b, a]), Some(2));
    assert_eq!(model.count(&[b, a, b]), Some(1));
    assert_eq!(model.count(&[a, b, a, b]), Some(1));
    assert_eq!(model.count(&[b, a, b, a]), Some(1));
}

#[test]
fn pre_counted_grams_preserve_raw_counts_and_validate_order() {
    let [a, b, c] = [0, 1, 2].map(WordId);
    let mut builder = GramBuilder::new();
    assert_eq!(builder.add(&[a], 1), Err(BuildError::InvalidOrder));
    builder.add(&[a, c], 0).unwrap();
    builder.add(&[a, b], u64::from(u32::MAX)).unwrap();
    builder.add(&[a, b], 10).unwrap();
    builder.add(&[a, b, c], u64::MAX).unwrap();
    assert_eq!(builder.add(&[a, b, c], 1), Err(BuildError::CountOverflow));
    let model = builder.finish().unwrap();

    assert_eq!(model.sizes(), [1, 1, 0]);
    assert_eq!(model.count(&[a, b]), Some(u64::from(u32::MAX) + 10));
    assert_eq!(model.count(&[a, b, c]), Some(u64::MAX));
    assert_eq!(model.count(&[a]), None);
}

#[test]
fn overflowing_observation_rolls_back_every_order() {
    let [a, b, c, d, e] = [0, 1, 2, 3, 4].map(WordId);
    let mut builder = GramBuilder::new();
    builder.add(&[a, b], 7).unwrap();
    builder.add(&[b, c, d, e], u64::MAX).unwrap();
    assert_eq!(
        builder.observe(&[a, b, c, d, e]),
        Err(BuildError::CountOverflow)
    );
    let model = builder.finish().unwrap();
    assert_eq!(model.sizes(), [1, 0, 1]);
    assert_eq!(model.count(&[a, b]), Some(7));
    assert_eq!(model.count(&[b, c, d, e]), Some(u64::MAX));
}

#[test]
fn prepared_context_returns_only_its_sorted_continuations() {
    let [a, b, c, d, e, high] = [0, 1, 2, 3, 4, u32::MAX].map(WordId);
    let mut builder = GramBuilder::new();
    builder.add(&[high, a], 9).unwrap();
    builder.add(&[a, b, c], 12).unwrap();
    builder.add(&[a, b, c, e], 3).unwrap();
    builder.add(&[a, b, c, d], 2).unwrap();
    builder.add(&[a, b, d, e], 4).unwrap();
    let model = builder.finish().unwrap();

    assert_eq!(model.count(&[high, a]), Some(9));
    assert_eq!(model.context(&[high]).count(a), Some(9));
    assert_eq!(model.context(&[a, b]).count(c), Some(12));
    let context = model.context(&[a, b, c]);
    assert_eq!(
        context.continuations().collect::<Vec<_>>(),
        [(d, 2), (e, 3)]
    );
    assert_eq!(context.count(e), Some(3));
    assert_eq!(context.count(c), None);
    assert_eq!(model.context(&[a, b, e]).continuations().len(), 0);
    assert_eq!(model.context(&[]).continuations().len(), 0);
}

#[test]
fn snapshot_round_trip_preserves_all_orders_and_rejects_invalid_rows() -> io::Result<()> {
    let scratch = ScratchDirectory::new()?;
    let path = scratch.0.join("model.sigram");
    let [a, b, c, d] = [0, 1, 2, 3].map(WordId);
    let mut builder = GramBuilder::new();
    builder.add(&[a, b], 99).unwrap();
    builder.add(&[a, c], 90).unwrap();
    builder.add(&[a, b, c], u64::MAX).unwrap();
    builder.add(&[a, b, c, d], 4).unwrap();
    builder.finish().unwrap().save(&path)?;

    let model = GramModel::open(&path)?;
    assert_eq!(model.sizes(), [2, 1, 1]);
    assert_eq!(model.count(&[a, b]), Some(99));
    assert_eq!(model.count(&[a, b, c]), Some(u64::MAX));
    assert_eq!(model.count(&[a, b, c, d]), Some(4));
    assert_eq!(
        model.context(&[a]).continuations().collect::<Vec<_>>(),
        [(b, 99), (c, 90)]
    );

    let bytes = fs::read(&path)?;
    assert_eq!(bytes.len(), 28 + 2 * 16 + 20 + 24);
    fs::write(&path, &bytes[..bytes.len() - 1])?;
    assert!(matches!(GramModel::open(&path), Err(e) if e.kind() == io::ErrorKind::InvalidData));

    let mut duplicate_key = bytes.clone();
    duplicate_key.copy_within(28..36, 36);
    fs::write(&path, duplicate_key)?;
    assert!(matches!(GramModel::open(&path), Err(e) if e.kind() == io::ErrorKind::InvalidData));

    let mut zero_count = bytes;
    zero_count[44..52].fill(0);
    fs::write(&path, zero_count)?;
    assert!(matches!(GramModel::open(&path), Err(e) if e.kind() == io::ErrorKind::InvalidData));
    Ok(())
}

struct ScratchDirectory(PathBuf);

impl ScratchDirectory {
    fn new() -> io::Result<Self> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        loop {
            let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
            let path =
                std::env::temp_dir().join(format!("si-gram-{}-{sequence}", std::process::id()));
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error),
            }
        }
    }
}

impl Drop for ScratchDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
