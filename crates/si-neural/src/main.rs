use std::io::{self, BufRead, Read, Write};
use std::path::Path;

use serde_json::{Value, json};
use si_neural::{Pinyin, Reranker, Result};

fn strings(value: &Value) -> Result<Vec<String>> {
    serde_json::from_value(value.clone()).map_err(|_| io::Error::other("expected array of strings"))
}

fn requests(run: impl Fn(Value) -> Result<Value>) -> Result<()> {
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let mut line = String::new();
    loop {
        line.clear();
        if (&mut input).take(1024 * 1024 + 1).read_line(&mut line)? == 0 {
            break;
        }
        if line.len() > 1024 * 1024 {
            return Err(io::Error::other("request exceeds size limit"));
        }
        let query =
            serde_json::from_str(&line).map_err(|_| io::Error::other("invalid JSON request"))?;
        serde_json::to_writer(&mut output, &run(query)?)?;
        writeln!(output)?;
        output.flush()?;
    }
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    match args.as_slice() {
        [command, path] if command == "generate" => {
            let model = Pinyin::open(Path::new(path))?;
            requests(|q| {
                let input = q["input"]
                    .as_str()
                    .ok_or_else(|| io::Error::other("input must be a string"))?;
                let paths = if q["syllable_paths"].is_null() {
                    vec![]
                } else {
                    strings(&q["syllable_paths"])?
                };
                let beam = q["beam_size"]
                    .as_u64()
                    .and_then(|n| usize::try_from(n).ok())
                    .ok_or_else(|| io::Error::other("beam_size must be a positive integer"))?;
                let result = model.generate(input, q["context"].as_str(), &paths, beam)?;
                Ok(
                    json!({ "model_candidates": result.model_candidates, "candidates": result.candidates }),
                )
            })
        }
        [command, path] if command == "rank" => {
            let metadata: Value =
                serde_json::from_slice(&std::fs::read(Path::new(path).join("model.json"))?)
                    .map_err(|_| io::Error::other("invalid model metadata"))?;
            if metadata["score_protocol"]
                .as_str()
                .is_some_and(|protocol| protocol.starts_with("si-app-model-adjustment-"))
            {
                return Err(io::Error::other(
                    "App-aligned bundles require si-cli candidates --model or si-cli model-adjustments",
                ));
            }
            let model = Reranker::open(Path::new(path))?;
            requests(|q| {
                let result = model.rank(
                    q["context"].as_str().unwrap_or_default(),
                    &strings(&q["candidates"])?,
                    q["length_penalty"].as_f64(),
                )?;
                Ok(
                    json!({ "scores": result.scores, "order": result.order, "abstained": result.abstained,
                           "context_tokens_used": result.context_tokens_used }),
                )
            })
        }
        _ => Err(io::Error::other(
            "usage: si-neural <generate|rank> <bundle> (JSONL requests on stdin)",
        )),
    }
}
