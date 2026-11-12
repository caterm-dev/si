use std::time::{Duration, Instant};

const UPDATE_INTERVAL: Duration = Duration::from_secs(2);
const SAMPLE_BYTES: u64 = 64 * 1024;

/// Progress from a corpus import before its final snapshot is published.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CorpusProgress {
    Preparing {
        files: usize,
    },
    Reading {
        file: usize,
        files: usize,
        bytes_read: u64,
        file_bytes: Option<u64>,
        records: usize,
        matched_tokens: usize,
        unknown_tokens: usize,
        unresolved_matches: usize,
        complete: bool,
    },
    BuildingGrams,
    Saving,
}

#[derive(Clone, Copy, Default)]
pub(super) struct ProgressCounts {
    pub(super) records: usize,
    pub(super) matched_tokens: usize,
    pub(super) unknown_tokens: usize,
    pub(super) unresolved_matches: usize,
}

pub(super) struct ProgressReporter<'a> {
    notify: &'a mut dyn FnMut(CorpusProgress),
    files: usize,
    file: usize,
    file_bytes: Option<u64>,
    sampled_bytes: u64,
    last_update: Instant,
}

impl<'a> ProgressReporter<'a> {
    pub(super) fn new(files: usize, notify: &'a mut dyn FnMut(CorpusProgress)) -> Self {
        notify(CorpusProgress::Preparing { files });
        Self {
            notify,
            files,
            file: 0,
            file_bytes: None,
            sampled_bytes: 0,
            last_update: Instant::now(),
        }
    }

    pub(super) fn phase(&mut self, phase: CorpusProgress) {
        (self.notify)(phase);
    }

    pub(super) fn start_file(&mut self, file_bytes: Option<u64>, counts: ProgressCounts) {
        self.file += 1;
        self.file_bytes = file_bytes;
        self.sampled_bytes = 0;
        self.reading(0, counts, false);
    }

    pub(super) fn after_line(&mut self, line: usize, bytes: u64, counts: ProgressCounts) {
        if !line.is_multiple_of(256) && bytes - self.sampled_bytes < SAMPLE_BYTES {
            return;
        }
        self.sampled_bytes = bytes;
        if self.last_update.elapsed() >= UPDATE_INTERVAL {
            self.reading(bytes, counts, false);
        }
    }

    pub(super) fn finish_file(&mut self, bytes: u64, counts: ProgressCounts) {
        self.reading(bytes, counts, true);
    }

    fn reading(&mut self, bytes_read: u64, counts: ProgressCounts, complete: bool) {
        self.last_update = Instant::now();
        self.phase(CorpusProgress::Reading {
            file: self.file,
            files: self.files,
            bytes_read,
            file_bytes: self.file_bytes,
            records: counts.records,
            matched_tokens: counts.matched_tokens,
            unknown_tokens: counts.unknown_tokens,
            unresolved_matches: counts.unresolved_matches,
            complete,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_long_file_reports_progress_before_reaching_the_end() {
        let mut events = Vec::new();
        let mut notify = |event| events.push(event);
        let mut reporter = ProgressReporter::new(1, &mut notify);
        reporter.start_file(Some(2 * SAMPLE_BYTES), ProgressCounts::default());
        reporter.last_update = Instant::now() - UPDATE_INTERVAL;
        reporter.after_line(
            1,
            SAMPLE_BYTES - 1,
            ProgressCounts {
                records: 1,
                ..ProgressCounts::default()
            },
        );
        reporter.after_line(
            2,
            SAMPLE_BYTES,
            ProgressCounts {
                records: 2,
                ..ProgressCounts::default()
            },
        );
        assert_eq!(events.len(), 3);
        assert!(matches!(
            events[2],
            CorpusProgress::Reading {
                bytes_read: SAMPLE_BYTES,
                records: 2,
                complete: false,
                ..
            }
        ));
    }
}
