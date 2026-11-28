use std::ffi::OsString;
use std::io::{self, BufRead, BufWriter, Write};
use std::path::Path;

use si_engine::resources::{EngineResources, SiConfig};
use si_engine::{
    CandidateEngine, CandidateLanguage, CandidatePoolInspector, CorrectionSensitivity, PoolOptions,
};

use super::candidates::{parse_languages, write_escaped};

pub(super) fn run(base: &Path, args: &[OsString], config: &SiConfig) -> Option<io::Result<()>> {
    let (pairs, tail) = args.as_chunks::<2>();
    if !tail.is_empty() {
        return None;
    }
    let mut grams = None;
    let mut languages = None;
    let mut preceding = None;
    let mut request_format = None;
    let mut correction = None;
    let mut k_best = None;
    let mut pool_size = None;
    let mut structure_limit = None;
    let mut multiword_limit = None;
    let mut search_budget = None;
    for [flag, value] in pairs {
        let value = value.to_str()?;
        match flag.to_str()? {
            "--grams" if grams.is_none() => grams = Some(Path::new(value)),
            "--languages" if languages.is_none() => languages = Some(parse_languages(value)?),
            "--preceding" if preceding.is_none() => preceding = Some(value),
            "--request-format" if request_format.is_none() => {
                request_format = Some(match value {
                    "spelling" => false,
                    "context-tsv" => true,
                    _ => return None,
                })
            }
            "--pinyin-correction" if correction.is_none() => {
                correction = Some(match value {
                    "on" => Some(CorrectionSensitivity::Conservative),
                    "off" => None,
                    _ => return None,
                })
            }
            "--k-best" if k_best.is_none() => k_best = Some(value.parse::<usize>().ok()?),
            "--pool-size" if pool_size.is_none() => pool_size = Some(value.parse::<usize>().ok()?),
            "--structure-limit" if structure_limit.is_none() => {
                structure_limit = Some(value.parse::<usize>().ok()?)
            }
            "--multiword-limit" if multiword_limit.is_none() => {
                multiword_limit = Some(value.parse::<usize>().ok()?)
            }
            "--search-budget" if search_budget.is_none() => {
                search_budget = Some(value.parse::<usize>().ok()?)
            }
            _ => return None,
        }
    }
    if request_format == Some(true) && preceding.is_some() {
        return None;
    }
    Some((|| {
        let defaults = PoolOptions::default();
        let pool_size = pool_size.unwrap_or(defaults.pool_size);
        let options = PoolOptions {
            k_best: k_best.unwrap_or(defaults.k_best),
            pool_size,
            structure_limit: structure_limit.unwrap_or(defaults.structure_limit),
            multiword_limit: multiword_limit.unwrap_or(pool_size),
            search_budget: search_budget.unwrap_or(defaults.search_budget),
        }
        .validate()
        .map_err(|message| io::Error::new(io::ErrorKind::InvalidInput, message))?;
        let resources = EngineResources::open(base, grams)?;
        let engine = CandidateEngine::new_with_config(&resources, None, config.engine);
        let inspector = CandidatePoolInspector::new(&engine).map_err(io::Error::other)?;
        let mut output = BufWriter::new(io::stdout().lock());
        for line in io::stdin().lock().lines() {
            let line = line?;
            let (source, context) = if request_format.unwrap_or_default() {
                let (source, context) = line.split_once('\t').ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidInput, "Expected spelling<TAB>context")
                })?;
                if context.contains('\t') {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "Context must not contain tabs",
                    ));
                }
                (source, (!context.is_empty()).then_some(context))
            } else {
                (line.as_str(), preceding)
            };
            let pool = inspector
                .inspect(
                    source,
                    languages.unwrap_or_default(),
                    context,
                    correction.flatten(),
                    options,
                )
                .map_err(io::Error::other)?;
            writeln!(
                output,
                "pool\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                usize::from(pool.complete),
                pool.certified,
                pool.expanded,
                pool.frontier_peak,
                pool.edges,
                pool.stop,
                pool.bound_states,
                pool.bound_steps
            )?;
            for (index, row) in pool.entries.iter().enumerate() {
                let blockers = row
                    .blocked_by
                    .iter()
                    .map(|index| (index + 1).to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                write!(
                    output,
                    "row\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{:.17}\t{:.17}\t{}\t{}\t",
                    index + 1,
                    row.native_rank.unwrap_or(0),
                    row.k_best_rank.unwrap_or(0),
                    usize::from(row.eligible),
                    usize::from(row.structure_kept),
                    usize::from(row.quota_kept),
                    usize::from(row.selected),
                    row.exclusion,
                    row.candidate.score_bits.unwrap_or_default(),
                    row.candidate.context_adjustment,
                    language(row.candidate.language),
                    blockers
                )?;
                write!(
                    output,
                    "{}\t{}\t{}\t{}\t",
                    usize::from(row.trace_matches_candidate),
                    row.k_best_score
                        .map(|score| format!("{score:.17}"))
                        .unwrap_or_default(),
                    usize::from(row.native_eligible),
                    row.native_score
                        .map(|score| format!("{score:.17}"))
                        .unwrap_or_default()
                )?;
                write_escaped(&mut output, &row.candidate.text)?;
                writeln!(output)?;
                for (position, token) in row.tokens.iter().enumerate() {
                    write!(
                        output,
                        "token\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{:.17}\t{:.17}\t{:.17}\t{:.17}\t",
                        index + 1,
                        position + 1,
                        language(token.language),
                        token.source_start,
                        token.source_end,
                        token.word_id,
                        token.count,
                        token.unigram_bits,
                        token.gram_bits,
                        token.context_bits,
                        token.spelling_bits
                    )?;
                    write!(output, "{}\t", usize::from(token.structural_single))?;
                    write_escaped(&mut output, &token.text)?;
                    writeln!(output)?;
                }
            }
            writeln!(output)?;
            output.flush()?;
        }
        Ok(())
    })())
}

fn language(language: CandidateLanguage) -> &'static str {
    match language {
        CandidateLanguage::Chinese => "zh-Hans",
        CandidateLanguage::English => "en",
        CandidateLanguage::Mixed => "mixed",
        CandidateLanguage::Literal => "literal",
    }
}
