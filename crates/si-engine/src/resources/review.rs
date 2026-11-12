use std::io::{self, Write};
use std::path::{Path, PathBuf};

use super::LexiconReview;
use super::csv_output::{PendingCsv, append_suffix};

pub(super) struct ReviewCsv {
    lexicon: PathBuf,
    pending: Option<PendingCsv>,
    rows: usize,
}

impl ReviewCsv {
    pub(super) fn new(lexicon: &Path) -> Self {
        Self {
            lexicon: lexicon.to_owned(),
            pending: None,
            rows: 0,
        }
    }

    pub(super) fn write(&mut self, text: &str, count: u64) -> io::Result<()> {
        let pending = match &mut self.pending {
            Some(pending) => pending,
            None => self
                .pending
                .insert(PendingCsv::new(&self.lexicon, b"text,reading,weight\n")?),
        };
        // The learner supplies only Han characters, which need no CSV escaping.
        writeln!(pending.writer, "{text},,{count}")?;
        self.rows += 1;
        Ok(())
    }

    pub(super) fn finish(self) -> io::Result<Option<LexiconReview>> {
        let Some(pending) = self.pending else {
            return Ok(None);
        };
        let csv = pending.finish()?;

        // Publish the finished file without replacing any earlier review, even if
        // its destination was created while this command was running.
        let mut number = 1u64;
        loop {
            let destination = append_suffix(&self.lexicon, &format!(".review-{number}.csv"));
            match csv.publish(&destination) {
                Ok(()) => {
                    return Ok(Some(LexiconReview {
                        path: destination,
                        rows: self.rows,
                    }));
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => number += 1,
                Err(error) => return Err(error),
            }
        }
    }
}
