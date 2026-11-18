//! Offline TSV transport: hex UTF-8 avoids escaping ambiguities and supports multiline context.
use si_engine::ranking_features::{self, NAMES, SCHEMA};
use si_engine::resources::EngineResources;
use si_engine::{CandidateEngine, CandidateLanguage, EnabledLanguages};
use std::ffi::OsString;
use std::io::{self, BufRead, Write};
use std::path::Path;

pub(super) fn run(base: &Path, args: &[OsString]) -> Option<io::Result<()>> {
    let grams = match args {
        [] => None,
        [flag, path] if flag == "--grams" => Some(Path::new(path)),
        _ => return None,
    };
    Some((|| {
        let resources = EngineResources::open(base, grams)?;
        let engine = CandidateEngine::new(&resources, None);
        let mut output = io::BufWriter::new(io::stdout().lock());
        writeln!(output, "{SCHEMA}\t{}", NAMES.join(","))?;
        for line in io::stdin().lock().lines() {
            let line = line?;
            let fields: Vec<_> = line.split('\t').collect();
            if fields.len() != 3 {
                return Err(invalid());
            }
            let source = unhex(fields[0])?;
            let context = unhex(fields[1])?;
            let languages = match fields[2] {
                "zh-Hans,en" => EnabledLanguages {
                    chinese: true,
                    english: true,
                },
                "zh-Hans" => EnabledLanguages {
                    chinese: true,
                    english: false,
                },
                "en" => EnabledLanguages {
                    chinese: false,
                    english: true,
                },
                _ => return Err(invalid()),
            };
            let candidates = engine.candidates_with_evidence(&source, languages, &context);
            let mut total = 0;
            for candidate in &candidates {
                if let Some(features) = ranking_features::extract(&source, &context, candidate) {
                    total += 1;
                    if total > 64 {
                        continue;
                    }
                    let language = match candidate.language {
                        CandidateLanguage::Chinese => "zh-Hans",
                        CandidateLanguage::English => "en",
                        CandidateLanguage::Mixed => "mixed",
                        CandidateLanguage::Literal => unreachable!(),
                    };
                    let text = candidate
                        .text
                        .as_bytes()
                        .iter()
                        .map(|b| format!("{b:02x}"))
                        .collect::<String>();
                    let features = features
                        .iter()
                        .map(ToString::to_string)
                        .collect::<Vec<_>>()
                        .join(",");
                    writeln!(output, "{language}\t{text}\t{features}")?;
                }
            }
            writeln!(output, "END\t{total}")?;
            output.flush()?;
        }
        Ok(())
    })())
}
fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, "invalid rank-features request")
}
fn unhex(value: &str) -> io::Result<String> {
    if !value.is_ascii() || value.len() % 2 != 0 {
        return Err(invalid());
    }
    let bytes = (0..value.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&value[i..i + 2], 16).map_err(|_| invalid()))
        .collect::<io::Result<Vec<_>>>()?;
    String::from_utf8(bytes).map_err(|_| invalid())
}
