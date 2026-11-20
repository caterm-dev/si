//! Offline TSV transport: hex UTF-8 avoids escaping ambiguities and supports multiline context.
use si_engine::ranking_features::{self, NAMES, SCHEMA};
use si_engine::resources::EngineResources;
use si_engine::{
    CandidateEngine, CandidateLanguage, ConversionPreferences, EnabledLanguages, PathPreference,
    TokenPreference,
};
use std::ffi::OsString;
use std::io::{self, BufRead, Write};
use std::path::Path;

pub(super) fn run(base: &Path, args: &[OsString]) -> Option<io::Result<()>> {
    let (mut grams, mut user_lexicon, mut user_grams) = (None, None, None);
    let mut legacy = false;
    let mut v5 = false;
    let mut correction = false;
    let mut model_correction_pool = false;
    let mut pinyin_paths = false;
    let mut flags = args.iter();
    while let Some(flag) = flags.next() {
        if flag == "--pinyin-correction" {
            correction = true;
            continue;
        }
        if flag == "--model-correction-pool" {
            model_correction_pool = true;
            continue;
        }
        if flag == "--v5" {
            v5 = true;
            continue;
        }
        if flag == "--pinyin-paths" {
            pinyin_paths = true;
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
    if user_grams.is_some() && user_lexicon.is_none()
        || legacy && (user_lexicon.is_some() || v5 || model_correction_pool)
        || correction && model_correction_pool
    {
        return None;
    }
    Some((|| {
        let resources = EngineResources::open(base, grams)?;
        let user = user_lexicon
            .map(|path| EngineResources::open(path, user_grams))
            .transpose()?;
        let engine = CandidateEngine::new(&resources, user.as_ref())
            .with_pinyin_correction(correction || model_correction_pool);
        let mut output = io::BufWriter::new(io::stdout().lock());
        let extended_names: Vec<_> = NAMES
            .into_iter()
            .chain(ranking_features::V5_ADDITIONS)
            .collect();
        let (schema, names): (&str, &[&str]) = if v5 {
            (ranking_features::V5_LEXICAL_SCHEMA, &extended_names)
        } else if legacy {
            ("si-rank-features-v2", &ranking_features::V2_NAMES)
        } else {
            (SCHEMA, &NAMES)
        };
        writeln!(output, "{schema}\t{}", names.join(","))?;
        for line in io::stdin().lock().lines() {
            let line = line?;
            let fields: Vec<_> = line.split('\t').collect();
            if !(matches!(fields.len(), 3 | 4) || v5 && fields.len() == 5) {
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
            let observations = parse_preferences(fields.get(4).copied().unwrap_or_default())?;
            let tokens: Vec<_> = observations
                .iter()
                .filter(|entry| !entry.spelling.is_empty())
                .map(|entry| TokenPreference {
                    spelling: &entry.spelling,
                    text: &entry.text,
                    language: entry.language,
                    bonus: entry.bonus,
                })
                .collect();
            let paths: Vec<_> = observations
                .iter()
                .filter(|entry| entry.spelling.is_empty())
                .map(|entry| PathPreference {
                    consumed_bytes: source.len(),
                    text: &entry.text,
                    language: entry.language,
                    frequency: entry.bonus,
                    contextual: 0.0,
                })
                .collect();
            let preferences = ConversionPreferences {
                tokens: &tokens,
                paths: &paths,
            };
            let candidates = if model_correction_pool {
                engine.model_pool_with_preference_evidence(
                    &source,
                    languages,
                    &context,
                    preferences,
                )
            } else {
                engine.candidates_with_preference_evidence(
                    &source,
                    languages,
                    &context,
                    preferences,
                )
            };
            let correction_slots = if model_correction_pool {
                candidates
                    .iter()
                    .filter(|candidate| candidate.is_corrected())
                    .count()
            } else {
                0
            };
            let mut total = 0;
            for candidate in &candidates {
                let features = if v5 {
                    ranking_features::extract_v5(
                        &source,
                        &context,
                        available,
                        candidate,
                        preferences,
                    )
                } else if legacy {
                    ranking_features::extract_v2(&source, &context, candidate)
                        .map(|values| values.into_iter().map(Some).collect())
                } else {
                    ranking_features::extract_with_context_state(
                        &source, &context, available, candidate,
                    )
                };
                if let Some(features) = features {
                    total += 1;
                    if total > 64 - correction_slots
                        && !(model_correction_pool && candidate.is_corrected())
                    {
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
            if pinyin_paths {
                let paths = if languages.chinese {
                    engine.contextual_pinyin_paths(&source)
                } else {
                    Vec::new()
                };
                writeln!(output, "END\t{total}\t{}", paths.join("|"))?;
            } else {
                writeln!(output, "END\t{total}")?;
            }
            output.flush()?;
        }
        Ok(())
    })())
}
struct Preference {
    spelling: String,
    text: String,
    language: CandidateLanguage,
    bonus: f64,
}

// An empty spelling marks a whole-input choice. Other rows describe a token.
fn parse_preferences(value: &str) -> io::Result<Vec<Preference>> {
    if value.is_empty() {
        return Ok(Vec::new());
    }
    if value.len() > 192 * 1024 {
        return Err(invalid());
    }
    let mut result = Vec::new();
    for item in value.split(',') {
        let fields: Vec<_> = item.split(':').collect();
        let [language, bonus, spelling, text] = fields.as_slice() else {
            return Err(invalid());
        };
        let language = match *language {
            "zh-Hans" => CandidateLanguage::Chinese,
            "en" => CandidateLanguage::English,
            "mixed" if spelling.is_empty() => CandidateLanguage::Mixed,
            _ => return Err(invalid()),
        };
        let bonus: f64 = bonus.parse().map_err(|_| invalid())?;
        let spelling = unhex(spelling)?;
        let text = unhex(text)?;
        if !(0.0..=32.0).contains(&bonus)
            || spelling.len() > 128
            || text.is_empty()
            || text.len() > 512
            || result.len() == 128
        {
            return Err(invalid());
        }
        result.push(Preference {
            spelling,
            text,
            language,
            bonus,
        });
    }
    Ok(result)
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, "invalid rank-features request")
}
fn unhex(value: &str) -> io::Result<String> {
    if !value.is_ascii() || !value.len().is_multiple_of(2) {
        return Err(invalid());
    }
    let bytes = (0..value.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&value[i..i + 2], 16).map_err(|_| invalid()))
        .collect::<io::Result<Vec<_>>>()?;
    String::from_utf8(bytes).map_err(|_| invalid())
}
