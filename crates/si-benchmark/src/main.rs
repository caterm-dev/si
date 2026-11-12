mod gram;
mod lexicon;
mod support;

use std::env;
use std::num::NonZeroU32;
use std::process::ExitCode;

const USAGE: &str = "Usage: si-benchmark lexicon [words] [queries]\n       si-benchmark gram [grams-per-order] [queries]";

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let benchmark = match args.next().as_deref() {
        Some("-h" | "--help") | None => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Some("lexicon") => lexicon::run,
        Some("gram") => gram::run,
        _ => return usage_error(),
    };
    let rows = args
        .next()
        .as_deref()
        .unwrap_or("1000000")
        .parse::<NonZeroU32>();
    let queries = args
        .next()
        .as_deref()
        .unwrap_or("100000")
        .parse::<NonZeroU32>();
    let (Ok(rows), Ok(queries), None) = (rows, queries, args.next()) else {
        return usage_error();
    };

    match benchmark(rows.get(), queries.get()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Benchmark failed: {error}");
            ExitCode::FAILURE
        }
    }
}

fn usage_error() -> ExitCode {
    eprintln!("{USAGE}");
    ExitCode::from(2)
}
