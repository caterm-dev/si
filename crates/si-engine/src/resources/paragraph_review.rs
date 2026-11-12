use std::collections::HashMap;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use si_lexicon::Lexicon;

use super::csv_output::{PendingCsv, write_field};

pub(super) const HEADER: &str = "kind,text,count,candidate_readings,first_file,first_line,reading";

#[derive(Default)]
pub(super) struct ParagraphReview {
    unmatched: HashMap<String, Occurrences>,
    unresolved: HashMap<String, Occurrences>,
}

struct Occurrences {
    count: usize,
    first_file: PathBuf,
    first_line: usize,
}

impl ParagraphReview {
    pub(super) fn record(&mut self, text: &str, unresolved: bool, source: &Path, line: usize) {
        let entries = if unresolved {
            &mut self.unresolved
        } else {
            &mut self.unmatched
        };
        if let Some(entry) = entries.get_mut(text) {
            entry.count += 1;
        } else {
            entries.insert(
                text.to_owned(),
                Occurrences {
                    count: 1,
                    first_file: source.to_owned(),
                    first_line: line,
                },
            );
        }
    }

    pub(super) fn save(self, lexicon: &Lexicon, destination: &Path) -> io::Result<usize> {
        let header = format!("{HEADER}\n");
        let mut csv = PendingCsv::new(destination, header.as_bytes())?;
        let count = self.unmatched.len() + self.unresolved.len();
        for (kind, entries) in [
            ("unmatched", self.unmatched),
            ("unresolved", self.unresolved),
        ] {
            let mut entries: Vec<_> = entries.into_iter().collect();
            entries.sort_unstable_by(|(left_text, left), (right_text, right)| {
                right
                    .count
                    .cmp(&left.count)
                    .then_with(|| left_text.cmp(right_text))
            });
            for (text, entry) in entries {
                let mut readings = Vec::new();
                if kind == "unresolved" {
                    for reading in lexicon
                        .words_for_text(&text)
                        .filter_map(|word| word.reading)
                    {
                        if let Ok(key) = std::str::from_utf8(reading.key) {
                            readings.push(format!("{}:{key}", reading.index.0));
                        }
                    }
                }
                let output = &mut csv.writer;
                write!(output, "{kind},")?;
                write_field(output, &text)?;
                write!(output, ",{},", entry.count)?;
                write_field(output, &readings.join(" | "))?;
                write!(output, ",")?;
                write_field(output, &entry.first_file.to_string_lossy())?;
                writeln!(output, ",{},", entry.first_line)?;
            }
        }
        csv.finish()?.publish(destination)?;
        Ok(count)
    }
}
