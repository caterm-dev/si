//! Offline TSV transport: hex UTF-8 avoids escaping ambiguities and supports multiline context.
use si_engine::ranking_features::{self, NAMES, SCHEMA};
use si_engine::resources::EngineResources;
use si_engine::{CandidateEngine, CandidateLanguage, EnabledLanguages};
use std::ffi::OsString;
use std::io::{self, BufRead, Write};
use std::path::Path;

pub(super) fn run(base: &Path, args: &[OsString]) -> Option<io::Result<()>> {
    let (mut grams, mut user_lexicon, mut user_grams) = (None, None, None);
    let mut legacy = false;
    let mut correction = false;
    let mut flags = args.iter();
    while let Some(flag) = flags.next() {
        if flag == "--pinyin-correction" {
            correction = true;
            continue;
        }
        if flag == "--legacy-v2" {
            legacy = true;
            continue;
        }
        let path = Path::new(flags.next()?);
        match flag.to_str()? {
            "--grams" if grams.is_none() => grams = Some(path),
            "--user-lexicon" if user_lexicon.is_none() => user_lexicon = Some(path),
            "--user-grams" if user_grams.is_none() => user_grams = Some(path),
            _ => return None,
        }
    }
    if user_grams.is_some() && user_lexicon.is_none() || legacy && user_lexicon.is_some() {
        return None;
    }
    Some((|| {
        let resources = EngineResources::open(base, grams)?;
        let user = user_lexicon
            .map(|path| EngineResources::open(path, user_grams))
            .transpose()?;
        let engine =
            CandidateEngine::new(&resources, user.as_ref()).with_pinyin_correction(correction);
        let mut output = io::BufWriter::new(io::stdout().lock());
        let (schema, names): (&str, &[&str]) = if legacy {
            ("si-rank-features-v2", &ranking_features::V2_NAMES)
        } else {
            (SCHEMA, &NAMES)
        };
        writeln!(output, "{schema}\t{}", names.join(","))?;
        for line in io::stdin().lock().lines() {
            let line = line?;
            let fields: Vec<_> = line.split('\t').collect();
            if !matches!(fields.len(), 3 | 4) {
                return Err(invalid());
            }
            let source = unhex(fields[0])?;
            let context = unhex(fields[1])?;
            let available = match fields.get(3).copied() {
                None => !context.is_empty(),
                Some("0") if context.is_empty() => false,
                Some("1") => true,
                _ => return Err(invalid()),
            };
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
                let features = if legacy {
                    ranking_features::extract_v2(&source, &context, candidate)
                        .map(|values| values.into_iter().map(Some).collect())
                } else {
                    ranking_features::extract_with_context_state(
                        &source, &context, available, candidate,
                    )
                };
                if let Some(features) = features {
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
                        .map(|v| v.map_or_else(|| "null".to_owned(), |v| v.to_string()))
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
