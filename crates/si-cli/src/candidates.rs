use std::ffi::OsString;
use std::io::{self, BufRead, BufWriter, Write};
use std::path::Path;

use si_engine::resources::EngineResources;
use si_engine::resources::user::UserModelStore;
use si_engine::{
    Candidate, CandidateEngine, CandidateLanguage, ConversionPreferences, CorrectionSensitivity,
    EnabledLanguages,
};

pub(super) fn run(base: &Path, args: &[OsString]) -> Option<io::Result<()>> {
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
    for [flag, value] in options {
        match flag.to_str()? {
            "--grams" if grams.is_none() => grams = Some(Path::new(value)),
            "--user" if profile.is_none() => profile = Some(UserModelStore::new(Path::new(value))),
            "--languages" if languages.is_none() => {
                languages = Some(parse_languages(value.to_str()?)?)
            }
            "--preceding" if preceding.is_none() => preceding = Some(value.to_str()?),
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
    Some((|| {
        let base = EngineResources::open(base, grams)?;
        let user = profile
            .as_ref()
            .map(UserModelStore::load)
            .transpose()?
            .flatten();
        let engine = CandidateEngine::new(&base, user.as_ref())
            .with_correction_sensitivity(pinyin_correction.flatten());
        let mut output = BufWriter::new(io::stdout().lock());
        for line in io::stdin().lock().lines() {
            let line = line?;
            let languages = languages.unwrap_or_default();
            let rows = engine.convert_with_context(
                &line,
                languages,
                preview.unwrap_or_default(),
                &[],
                ConversionPreferences::default(),
                preceding.unwrap_or_default(),
            );
            if window.unwrap_or_default() {
                for index in si_engine::presentation::conversion_window(&line, languages, &rows) {
                    write_candidate(&mut output, &rows[index], line.len())?;
                }
            } else {
                for candidate in rows {
                    write_candidate(&mut output, &candidate, line.len())?;
                }
            }
            writeln!(output)?;
            output.flush()?;
        }
        Ok(())
    })())
}

fn parse_languages(value: &str) -> Option<EnabledLanguages> {
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
    for character in candidate.text.chars() {
        if character == '\\' || character.is_control() {
            write!(output, "{}", character.escape_default())?;
        } else {
            write!(output, "{character}")?;
        }
    }
    writeln!(output)
}
