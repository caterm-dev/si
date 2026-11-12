use std::fs;
use std::io;
use std::path::PathBuf;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const BATCH: usize = 256;

pub(crate) fn measure(label: &str, queries: u32, mut query: impl FnMut(usize)) {
    for i in 0..4096 {
        query(i);
    }
    let queries = queries as usize;
    let mut samples = Vec::with_capacity(queries.div_ceil(BATCH));
    let mut elapsed = 0.0;
    for start in (0..queries).step_by(BATCH) {
        let end = (start + BATCH).min(queries);
        let clock = Instant::now();
        for i in start..end {
            query(i);
        }
        let duration = clock.elapsed().as_secs_f64() * 1e9;
        elapsed += duration;
        samples.push(duration / (end - start) as f64);
    }
    samples.sort_unstable_by(f64::total_cmp);
    let percentile = |p: usize| samples[(samples.len() * p).div_ceil(100) - 1];
    println!(
        "{label:<25} avg {:>8.1} ns   p50 {:>8.1} ns   p95 {:>8.1} ns",
        elapsed / queries as f64,
        percentile(50),
        percentile(95),
    );
}

pub(crate) struct ScratchDirectory(pub(crate) PathBuf);

impl ScratchDirectory {
    pub(crate) fn new() -> io::Result<Self> {
        let time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_nanos();
        let path = std::env::temp_dir().join(format!("si-benchmark-{}-{time}", std::process::id()));
        fs::create_dir(&path)?;
        Ok(Self(path))
    }
}

impl Drop for ScratchDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
