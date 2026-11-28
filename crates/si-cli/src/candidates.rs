use std::ffi::OsString;
use std::io::{self, BufRead, BufWriter, Write};
use std::path::Path;

use si_engine::resources::user::UserModelStore;
use si_engine::resources::{EngineResources, SiConfig};
use si_engine::{
    Candidate, CandidateEngine, CandidateLanguage, ConversionOptions, ConversionPreferences,
    CorrectionSensitivity, EnabledLanguages, PrecedingTextCache, SmallReranker,
};

pub(super) fn run(base: &Path, args: &[OsString], config: &SiConfig) -> Option<io::Result<()>> {
    let (options, tail) = args.as_chunks::<2>();
    if !tail.is_empty() {
        return None;
    }
    let mut grams = None;
    let mut profile = None;
    let mut languages = None;
    let mut pinyin_correction = None;
    let mut preview = None;
    let mut preceding = None;
    let mut window = None;
    let mut context_tsv = None;
    let mut model_output = None;
    let mut model_path = None;
    for [flag, value] in options {
        match flag.to_str()? {
            "--grams" if grams.is_none() => grams = Some(Path::new(value)),
            "--user" if profile.is_none() => profile = Some(UserModelStore::new(Path::new(value))),
            "--languages" if languages.is_none() => {
                languages = Some(parse_languages(value.to_str()?)?)
            }
            "--preceding" if preceding.is_none() => preceding = Some(value.to_str()?),
            "--model" if model_path.is_none() => model_path = Some(Path::new(value)),
            "--output-format" if model_output.is_none() => {
                model_output = Some(match value.to_str()? {
                    "tsv" => false,
                    "model-tsv" => true,
                    _ => return None,
                });
            }
            "--request-format" if context_tsv.is_none() => {
                context_tsv = Some(match value.to_str()? {
                    "spelling" => false,
                    "context-tsv" => true,
                    _ => return None,
                });
            }
            "--list" if window.is_none() => {
                window = Some(match value.to_str()? {
                    "full" => false,
                    "window" => true,
                    _ => return None,
                });
            }
            "--search" if preview.is_none() => {
                preview = Some(match value.to_str()? {
                    "preview" => true,
                    "full" => false,
                    _ => return None,
                });
            }
            "--pinyin-correction" if pinyin_correction.is_none() => {
                pinyin_correction = Some(match value.to_str()? {
                    "on" => Some(CorrectionSensitivity::Conservative),
                    "higher-recall" => Some(CorrectionSensitivity::HigherRecall),
                    "off" => None,
                    _ => return None,
                });
            }
            _ => return None,
        }
    }
    if context_tsv == Some(true) && preceding.is_some() {
        return None;
    }
    if model_output == Some(true)
        && (profile.is_some()
            || model_path.is_some()
            || preview == Some(true)
            || window == Some(true))
    {
        return None;
    }
    Some((|| {
        let base = EngineResources::open(base, grams)?;
        let user = profile
            .as_ref()
            .map(UserModelStore::load)
            .transpose()?
            .flatten();
        let engine = CandidateEngine::new_with_config(&base, user.as_ref(), config.engine)
            .with_correction_sensitivity(pinyin_correction.flatten());
        let model = model_path
            .map(|path| SmallReranker::open_with_config(path, config.engine.local_model_ranking))
            .transpose()?;
        let mut output = BufWriter::new(io::stdout().lock());
        let context_cache = PrecedingTextCache::default();
        for line in io::stdin().lock().lines() {
            let line = line?;
            let (spelling, request_context) = if context_tsv.unwrap_or_default() {
                let (spelling, context) = line.split_once('\t').ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidInput, "Expected spelling<TAB>context")
                })?;
                if context.contains('\t') {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "Context must not contain tabs",
                    ));
                }
                (spelling, (!context.is_empty()).then_some(context))
            } else {
                (line.as_str(), preceding)
            };
            let languages = languages.unwrap_or_default();
            let rows = engine.convert_with_cached_context(
                spelling,
                languages,
                preview.unwrap_or_default(),
                &[],
                ConversionPreferences::default(),
                request_context,
                ConversionOptions {
                    correction: pinyin_correction.flatten(),
                    reranker: model.as_ref(),
                },
                Some(&context_cache),
            );
            if model_output.unwrap_or_default() {
                write!(output, "context\t")?;
                write_escaped(
                    &mut output,
                    si_engine::model_context_fragment(request_context.unwrap_or_default()),
                )?;
                writeln!(output)?;
                let pool = SmallReranker::pool_indices(
                    &rows,
                    spelling.len(),
                    config.engine.local_model_ranking,
                );
                let adjusted = SmallReranker::adjustment_indices(&rows, spelling.len());
                for (index, row) in rows.iter().enumerate().filter(|(_, row)| {
                    row.consumed_bytes == spelling.len()
                        && row.language != CandidateLanguage::Literal
                }) {
                    // This export has no user model, phrases or transient preferences.
                    if row.personal || row.preferred || row.token_bonus != 0.0 {
                        return Err(io::Error::other(
                            "Model pool export requires an empty personal profile",
                        ));
                    }
                    write!(
                        output,
                        "{}\t{}\t{:.17}\t",
                        usize::from(pool.contains(&index)),
                        usize::from(adjusted.contains(&index)),
                        row.score_bits.unwrap_or_default() + row.context_adjustment
                    )?;
                    write_candidate(&mut output, row, spelling.len())?;
                }
            } else if window.unwrap_or_default() {
                for index in si_engine::presentation::conversion_window(spelling, languages, &rows)
                {
                    write_candidate(&mut output, &rows[index], spelling.len())?;
                }
            } else {
                for candidate in rows {
                    write_candidate(&mut output, &candidate, spelling.len())?;
                }
            }
            writeln!(output)?;
            output.flush()?;
        }
        Ok(())
    })())
}

pub(super) fn parse_languages(value: &str) -> Option<EnabledLanguages> {
    let (chinese, english) = match value {
        "zh-Hans,en" | "en,zh-Hans" => (true, true),
        "zh-Hans" => (true, false),
        "en" => (false, true),
        "none" => (false, false),
        _ => return None,
    };
    Some(EnabledLanguages { chinese, english })
}

fn write_candidate(
    output: &mut impl Write,
    candidate: &Candidate,
    input_bytes: usize,
) -> io::Result<()> {
    let language = match candidate.language {
        CandidateLanguage::Chinese => "zh-Hans",
        CandidateLanguage::English => "en",
        CandidateLanguage::Mixed => "mixed",
        CandidateLanguage::Literal => "literal",
    };
    let kind = if candidate.language == CandidateLanguage::Literal {
        "literal"
    } else if candidate.consumed_bytes < input_bytes {
        "prefix"
    } else if candidate.is_corrected() {
        "correction"
    } else if candidate.completion {
        "completion"
    } else {
        "exact"
    };
    write!(output, "{language}\t{}\t{kind}\t", candidate.consumed_bytes)?;
    if let Some(score) = candidate.score_bits {
        write!(output, "{score:.6}")?;
    }
    write!(output, "\t")?;
    write_escaped(output, &candidate.text)?;
    writeln!(output)
}

pub(super) fn write_escaped(output: &mut impl Write, text: &str) -> io::Result<()> {
    for character in text.chars() {
        if character == '\\' || character.is_control() {
            write!(output, "{}", character.escape_default())?;
        } else {
            write!(output, "{character}")?;
        }
    }
    Ok(())
}
