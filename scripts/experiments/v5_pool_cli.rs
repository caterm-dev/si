//! Experiment-only CLI for shared post-union feature enrichment and native scoring.
use si_engine::resources::EngineResources;
use si_engine::{CandidateEngine, ConversionPreferences, EnabledLanguages, HybridRanking, v5_experiment};
use std::io::{self, BufRead};
use std::path::Path;

fn parse_optional(text: &str) -> Option<f64> {
    (text != "null").then(|| text.parse().expect("invalid numerical feature"))
}

fn csv(values: impl IntoIterator<Item = Option<f64>>) -> String {
    values.into_iter().map(|value| value.map_or_else(|| "null".into(), |value| value.to_string()))
        .collect::<Vec<_>>().join(",")
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [mode] if mode == "enrich" => {
            println!("{}", v5_experiment::NAMES.join(","));
            for line in io::stdin().lock().lines() {
                let line = line?;
                let fields: Vec<_> = line.split('\t').collect();
                let [buffer, lexical, ratios] = fields.as_slice() else {
                    return Err("expected buffer, lexical scores, and completion ratios".into());
                };
                let buffer: [Option<f64>; v5_experiment::BUFFER_SIZE] =
                    buffer.split(',').map(parse_optional).collect::<Vec<_>>().try_into()
                        .map_err(|_| "invalid buffer width")?;
                let lexical: Vec<_> = lexical.split(',').filter(|value| !value.is_empty())
                    .map(parse_optional).collect();
                let ratios: Vec<_> = ratios.split(',').filter(|value| !value.is_empty())
                    .map(str::parse::<f64>).collect::<Result<_, _>>()?;
                let rows = v5_experiment::enrich(&lexical, buffer, &ratios);
                println!("{}", rows.into_iter().map(csv).collect::<Vec<_>>().join(";"));
            }
        }
        [mode, lexicon, grams, bundle] if mode == "runtime" => {
            let resources = EngineResources::open(Path::new(lexicon), Some(Path::new(grams)))?;
            let engine = CandidateEngine::new(&resources, None);
            let model = HybridRanking::open(Path::new(bundle))?;
            for line in io::stdin().lock().lines() {
                let line = line?;
                for row in model.convert(&engine, &line, EnabledLanguages::default(), &[],
                                         ConversionPreferences::default(), "", None) {
                    if let Some(score) = row.model_score {
                        let features = row.experiment_features.as_deref().unwrap_or_default();
                        println!("{}\t{score}\t{}", row.candidate.text,
                                 csv(features.iter().copied()));
                    }
                }
                println!("END");
            }
        }
        _ => return Err("usage: v5-pool-features enrich | runtime LEXICON GRAMS BUNDLE".into()),
    }
    Ok(())
}
