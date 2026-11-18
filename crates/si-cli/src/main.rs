mod candidates;
mod rank_features;

use std::env;
use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::io::{self, BufRead, BufReader};
use std::path::Path;
use std::process::ExitCode;
use std::str::FromStr;

use si_engine::IndexId;
use si_engine::resources::user::{UserLearningConfig, UserModelStore};
use si_engine::resources::{
    self, CorpusCountMode, CorpusImport, CorpusProgress, EngineResources, GramOrder, GramSizes,
    LearningConfig, LexiconImport, LexiconLearning, LexiconSource, ParagraphImport, SiConfig,
};

const USAGE: &str = "\
Usage:
  si-cli [--config <si.conf>] <command> ...
  si-cli lexicon build <output.silex> <index> <csv-or-dir> [<index> <csv-or-dir> ...]
  si-cli lexicon add   <output.silex> <index> <csv-or-dir> [<index> <csv-or-dir> ...]
  si-cli lexicon export [--language <zh-Hans|en>] <lexicon.silex> <output.csv>
  si-cli lexicon restore <source.csv> <output.silex>
  si-cli lexicon learn <lexicon.silex> <grams.sigram> [<si.conf>]
  si-cli corpus build  [--han] <lexicon.silex> <output.sigram> <source.txt> [<source.txt> ...]
  si-cli corpus add    [--han] <lexicon.silex> <output.sigram> <source.txt> [<source.txt> ...]
  si-cli corpus ingest <lexicon.silex> <grams.sigram> <source.txt> [<source.txt> ...]
  si-cli corpus clear-grams <lexicon.silex> <grams.sigram>
  si-cli corpus prune  --order <2|3|4|5> --min-count <count> <lexicon.silex> <grams.sigram>
  si-cli rank-features <base.silex> [--grams <base.sigram>]
  si-cli candidates <base.silex> [--grams <base.sigram>] [--user <profile.si-user>] [--languages <zh-Hans,en|zh-Hans|en|none>]
  si-cli user ingest <profile.si-user> <base.silex> <batch-id> <sentences.txt|->
  si-cli user learn  <profile.si-user> <base.silex> [<si.conf>]
  si-cli user status <profile.si-user>
  si-cli user clear  <profile.si-user>";

fn main() -> ExitCode {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.is_empty() || matches!(args.as_slice(), [flag] if flag == "--help" || flag == "-h") {
        println!("{USAGE}");
        return ExitCode::SUCCESS;
    }
    let (config, args) = match args.as_slice() {
        [flag, path, args @ ..] if flag == "--config" => (SiConfig::open(Path::new(path)), args),
        _ => (Ok(SiConfig::default()), args.as_slice()),
    };
    let result = match config {
        Ok(config) => run(args, &config),
        Err(error) => Some(Err(error)),
    };
    let Some(result) = result else {
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

fn run(args: &[OsString], config: &SiConfig) -> Option<io::Result<()>> {
    match args {
        [scope, lexicon, grams @ ..] if scope == "check-resources" && grams.len() <= 1 => {
            Some(EngineResources::open(Path::new(lexicon), grams.first().map(Path::new)).map(drop))
        }
        [scope, base, options @ ..] if scope == "rank-features" => {
            rank_features::run(Path::new(base), options)
        }
        [scope, base, options @ ..] if scope == "candidates" => {
            candidates::run(Path::new(base), options)
        }
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
        [scope, action, inputs @ ..] if scope == "lexicon" && action == "export" => {
            export_lexicon(inputs)
        }
        [scope, action, source, output] if scope == "lexicon" && action == "restore" => Some(
            resources::restore_lexicon(Path::new(source), Path::new(output)).map(print_lexicon),
        ),
        [scope, action, lexicon, grams, path @ ..]
            if scope == "lexicon" && action == "learn" && path.len() <= 1 =>
        {
            Some((|| {
                let custom = path
                    .first()
                    .map(|path| LearningConfig::open(Path::new(path)))
                    .transpose()?;
                resources::learn_lexicon(
                    Path::new(lexicon),
                    Path::new(grams),
                    custom.as_ref().unwrap_or(&config.base_learning),
                )
                .map(print_learning)
            })())
        }
        [scope, action, inputs @ ..] if scope == "corpus" && action == "ingest" => {
            ingest_corpus(inputs, config.base_max_order)
        }
        [scope, action, inputs @ ..] if scope == "corpus" && action == "prune" => {
            prune_corpus(inputs)
        }
        [scope, action, lexicon, grams] if scope == "corpus" && action == "clear-grams" => {
            let grams = Path::new(grams);
            Some(
                resources::clear_corpus_grams(Path::new(lexicon), grams).map(|removed| {
                    if removed {
                        println!("Removed {}.", grams.display());
                    } else {
                        println!("No gram snapshot at {}.", grams.display());
                    }
                }),
            )
        }
        [scope, action, inputs @ ..] if scope == "corpus" => {
            run_corpus(action, inputs, config.base_max_order)
        }
        [scope, action, profile, inputs @ ..] if scope == "user" => {
            run_user(action, profile, inputs, config)
        }
        _ => None,
    }
}

fn run_user(
    action: &OsStr,
    profile: &OsStr,
    inputs: &[OsString],
    config: &SiConfig,
) -> Option<io::Result<()>> {
    let store = UserModelStore::new(Path::new(profile));
    match (action.to_str()?, inputs) {
        ("ingest", [base, batch, source]) => Some(ingest_user(
            &store,
            base,
            batch.to_str()?,
            source,
            config.user_max_order,
        )),
        ("learn", [base, path @ ..]) if path.len() <= 1 => Some((|| {
            let base = EngineResources::open(Path::new(base), None)?;
            let custom = path
                .first()
                .map(|path| UserLearningConfig::open(Path::new(path)))
                .transpose()?;
            let report = store.learn(
                base.lexicon(),
                custom.as_ref().unwrap_or(&config.user_learning),
            )?;
            println!(
                "Added {} user words. Skipped {} unresolved readings.",
                report.added_words, report.unresolved_readings
            );
            Ok(())
        })()),
        ("status", []) => Some(store.load().map(|model| {
            let Some(model) = model else {
                println!("User profile is empty.");
                return;
            };
            let grams = gram_summary(model.grams().expect("user word grams").sizes());
            println!("User model has {} words, {grams}.", model.lexicon().len());
        })),
        ("clear", []) => Some(store.clear().map(|()| println!("Cleared the user model."))),
        _ => None,
    }
}

fn ingest_user(
    store: &UserModelStore,
    base: &OsStr,
    batch_id: &str,
    source: &OsStr,
    max_order: GramOrder,
) -> io::Result<()> {
    let base = EngineResources::open(Path::new(base), None)?;
    let report = if source == "-" {
        store.ingest_with_order(
            base.lexicon(),
            batch_id,
            io::stdin().lock().lines(),
            max_order,
        )?
    } else {
        let reader = BufReader::new(File::open(Path::new(source))?);
        store.ingest_with_order(base.lexicon(), batch_id, reader.lines(), max_order)?
    };
    if report.already_applied {
        println!("Batch was already applied.");
    } else {
        println!(
            "Imported {} sentences with {} matched words and {} skipped spans.",
            report.sentences, report.matched_words, report.skipped_spans
        );
    }
    println!(
        "User model has {} words, {}.",
        report.words,
        gram_summary(report.grams)
    );
    Ok(())
}

fn prune_corpus(inputs: &[OsString]) -> Option<io::Result<()>> {
    let [order_flag, order, count_flag, min_count, lexicon, grams] = inputs else {
        return None;
    };
    if order_flag != "--order" || count_flag != "--min-count" {
        return None;
    }
    let order_number = number::<u64>(order)?;
    let order = GramOrder::try_from(order_number).ok()?;
    let min_count = number(min_count)?;
    Some(
        resources::prune_corpus(Path::new(lexicon), Path::new(grams), order, min_count).map(
            |removed| {
                println!(
                    "Removed {removed} order-{order_number} rows with counts below {min_count}."
                )
            },
        ),
    )
}

fn ingest_corpus(inputs: &[OsString], max_order: GramOrder) -> Option<io::Result<()>> {
    let [lexicon, grams, sources @ ..] = inputs else {
        return None;
    };
    if sources.is_empty() || sources.iter().any(|input| input == "--grams") {
        return None;
    }
    let sources = sources.iter().map(Into::into).collect::<Vec<_>>();
    Some(
        resources::ingest_corpus_with_order(
            Path::new(lexicon),
            Path::new(grams),
            &sources,
            max_order,
            print_corpus_progress,
        )
        .map(print_paragraphs),
    )
}

fn run_corpus(action: &OsStr, inputs: &[OsString], max_order: GramOrder) -> Option<io::Result<()>> {
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
        resources::count_corpus_with_order(
            Path::new(lexicon),
            Path::new(output),
            &sources,
            mode,
            max_order,
            print_corpus_progress,
        )
        .map(print_corpus),
    )
}

fn export_lexicon(inputs: &[OsString]) -> Option<io::Result<()>> {
    let (result, output) = match inputs {
        [source, output] => (
            resources::export_lexicon(Path::new(source), Path::new(output)),
            output,
        ),
        [flag, language, source, output] if flag == "--language" => {
            let index = match language.to_str()? {
                "zh-Hans" => IndexId(0),
                "en" => IndexId(1),
                _ => return None,
            };
            (
                resources::export_lexicon_index(Path::new(source), Path::new(output), index),
                output,
            )
        }
        _ => return None,
    };
    Some(result.map(|words| {
        println!("Exported {words} words to {}.", Path::new(output).display());
    }))
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
    println!("Added {} words.", report.added[0]);
    if let Some(review) = report.review {
        println!(
            "Exported {} candidates for reading review to {}.",
            review.rows,
            review.path.display()
        );
    }
}

fn print_corpus(report: CorpusImport) {
    println!(
        "Read {} sentences and skipped {} unknown tokens. Model has {}.",
        report.sentences,
        report.unknown_tokens,
        gram_summary(report.grams)
    );
}

fn gram_summary([two, three, four, five]: GramSizes) -> String {
    let tail = if five == 0 {
        format!("and {four} four-grams")
    } else {
        format!("{four} four-grams, and {five} five-grams")
    };
    format!("{two} bigrams, {three} trigrams, {tail}")
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
    println!(
        "Imported {} paragraphs with {} matched words. Skipped {} unknown characters and {} unresolved matches.",
        report.paragraphs, report.matched_words, report.unknown_characters, report.ambiguous_words
    );
    if let Some(review) = report.english_review {
        println!(
            "Exported {} unknown English spellings to {}.",
            review.rows,
            review.path.display()
        );
    } else if report.added_english_words != 0 {
        println!("Added {} new English words.", report.added_english_words);
    }
    println!(
        "Counted {} <char> and {} <num> placeholders in the token stream.",
        report.letter_placeholders, report.number_placeholders
    );
    println!("Model has {}.", gram_summary(report.grams));
    if let Some(review) = report.review {
        println!(
            "Exported {} entries for manual review to {}.",
            review.rows,
            review.path.display()
        );
    }
}
