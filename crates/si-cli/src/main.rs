use std::env;
use std::ffi::{OsStr, OsString};
use std::io;
use std::path::Path;
use std::process::ExitCode;
use std::str::FromStr;

use si_engine::IndexId;
use si_engine::resources::{
    self, CorpusCountMode, CorpusImport, CorpusProgress, LearningConfig, LexiconImport,
    LexiconLearning, LexiconSource, ParagraphImport,
};

const USAGE: &str = "\
Usage:
  si-cli lexicon build <output.silex> <index> <csv-or-dir> [<index> <csv-or-dir> ...]
  si-cli lexicon add   <output.silex> <index> <csv-or-dir> [<index> <csv-or-dir> ...]
  si-cli lexicon export <lexicon.silex> <output.csv>
  si-cli lexicon restore <source.csv> <output.silex>
  si-cli lexicon learn <lexicon.silex> <grams.sigram> <learning.conf>
  si-cli corpus build  [--han] <lexicon.silex> <output.sigram> <source.txt> [<source.txt> ...]
  si-cli corpus add    [--han] <lexicon.silex> <output.sigram> <source.txt> [<source.txt> ...]
  si-cli corpus ingest <lexicon.silex> <grams.sigram> <source.txt> [<source.txt> ...]";

fn main() -> ExitCode {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.is_empty() || matches!(args.as_slice(), [flag] if flag == "--help" || flag == "-h") {
        println!("{USAGE}");
        return ExitCode::SUCCESS;
    }
    let Some(result) = run(&args) else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("si-cli: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[OsString]) -> Option<io::Result<()>> {
    match args {
        [scope, action, output, inputs @ ..]
            if scope == "lexicon" && (action == "build" || action == "add") =>
        {
            let sources = lexicon_sources(inputs)?;
            let import = if action == "build" {
                resources::build_lexicon
            } else {
                resources::add_lexicon
            };
            Some(import(Path::new(output), &sources).map(print_lexicon))
        }
        [scope, action, source, output] if scope == "lexicon" && action == "export" => Some(
            resources::export_lexicon(Path::new(source), Path::new(output)).map(|words| {
                println!("Exported {words} words to {}.", Path::new(output).display());
            }),
        ),
        [scope, action, source, output] if scope == "lexicon" && action == "restore" => Some(
            resources::restore_lexicon(Path::new(source), Path::new(output)).map(print_lexicon),
        ),
        [scope, action, lexicon, grams, config] if scope == "lexicon" && action == "learn" => Some(
            LearningConfig::open(Path::new(config))
                .and_then(|config| {
                    resources::learn_lexicon(Path::new(lexicon), Path::new(grams), &config)
                })
                .map(print_learning),
        ),
        [scope, action, inputs @ ..] if scope == "corpus" && action == "ingest" => {
            ingest_corpus(inputs)
        }
        [scope, action, inputs @ ..] if scope == "corpus" => run_corpus(action, inputs),
        _ => None,
    }
}

fn ingest_corpus(inputs: &[OsString]) -> Option<io::Result<()>> {
    let [lexicon, grams, sources @ ..] = inputs else {
        return None;
    };
    if sources.is_empty() || sources.iter().any(|input| input == "--grams") {
        return None;
    }
    let sources = sources.iter().map(Into::into).collect::<Vec<_>>();
    Some(
        resources::ingest_corpus_with_progress(
            Path::new(lexicon),
            Path::new(grams),
            &sources,
            print_corpus_progress,
        )
        .map(print_paragraphs),
    )
}

fn run_corpus(action: &OsStr, inputs: &[OsString]) -> Option<io::Result<()>> {
    let han = inputs.first().is_some_and(|input| input == "--han");
    let [lexicon, output, sources @ ..] = &inputs[usize::from(han)..] else {
        return None;
    };
    if sources.is_empty() {
        return None;
    }
    let mode = match (action.to_str()?, han) {
        ("build", false) => CorpusCountMode::Build,
        ("add", false) => CorpusCountMode::Add,
        ("build", true) => CorpusCountMode::BuildHan,
        ("add", true) => CorpusCountMode::AddHan,
        _ => return None,
    };
    let sources = sources.iter().map(Into::into).collect::<Vec<_>>();
    Some(
        resources::count_corpus_with_progress(
            Path::new(lexicon),
            Path::new(output),
            &sources,
            mode,
            print_corpus_progress,
        )
        .map(print_corpus),
    )
}

fn lexicon_sources(inputs: &[OsString]) -> Option<Vec<LexiconSource>> {
    let (pairs, remainder) = inputs.as_chunks::<2>();
    if pairs.is_empty() || !remainder.is_empty() {
        return None;
    }
    pairs
        .iter()
        .map(|[index, path]| {
            Some(LexiconSource {
                index: IndexId(number(index)?),
                path: path.into(),
            })
        })
        .collect()
}

fn number<T: FromStr>(argument: &OsStr) -> Option<T> {
    argument.to_str()?.parse().ok()
}

fn print_lexicon(report: LexiconImport) {
    println!(
        "Imported {} CSV rows. Dictionary has {} words.",
        report.rows, report.words
    );
}

fn print_learning(report: LexiconLearning) {
    let [two, three, four] = report.added;
    println!(
        "Added {two} two-character, {three} three-character, and {four} four-character words."
    );
    if let Some(review) = report.review {
        println!(
            "Exported {} candidates for reading review to {}.",
            review.rows,
            review.path.display()
        );
    }
}

fn print_corpus(report: CorpusImport) {
    let [two, three, four] = report.grams;
    println!(
        "Read {} sentences and skipped {} unknown tokens. Model has {two} bigrams, {three} trigrams, and {four} four-grams.",
        report.sentences, report.unknown_tokens
    );
}

fn print_corpus_progress(progress: CorpusProgress) {
    match progress {
        CorpusProgress::Preparing { files } => {
            eprintln!("Preparing to import {files} corpus files.")
        }
        CorpusProgress::Reading {
            file,
            files,
            bytes_read,
            file_bytes,
            records,
            matched_tokens,
            unknown_tokens,
            unresolved_matches,
            complete,
        } => {
            let position = match file_bytes {
                Some(total) if total > 0 => format!(
                    "{:.1}%",
                    100.0 * bytes_read.min(total) as f64 / total as f64
                ),
                Some(_) if complete => "100.0%".into(),
                Some(_) => "0.0%".into(),
                None => format!("{bytes_read} bytes read"),
            };
            let action = if complete { "Finished" } else { "Reading" };
            eprintln!(
                "{action} corpus file {file}/{files} ({position}) | {records} records processed | {matched_tokens} matched tokens | {unknown_tokens} unknown | {unresolved_matches} unresolved"
            );
        }
        CorpusProgress::BuildingGrams => eprintln!("Building gram tables."),
        CorpusProgress::Saving => eprintln!("Saving corpus results."),
    }
}

fn print_paragraphs(report: ParagraphImport) {
    let [two, three, four] = report.grams;
    println!(
        "Imported {} paragraphs with {} matched words. Skipped {} unknown characters and {} unresolved matches.",
        report.paragraphs, report.matched_words, report.unknown_characters, report.ambiguous_words
    );
    println!("Added {} new English words.", report.added_english_words);
    println!(
        "Counted {} <char> and {} <num> placeholders in the token stream.",
        report.letter_placeholders, report.number_placeholders
    );
    println!("Model has {two} bigrams, {three} trigrams, and {four} four-grams.");
    if let Some(review) = report.review {
        println!(
            "Exported {} entries for manual review to {}.",
            review.rows,
            review.path.display()
        );
    }
}
