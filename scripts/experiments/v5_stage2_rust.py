"""Build the V5 extension against a workspace copy, leaving app and CLI sources untouched."""
import argparse
from pathlib import Path
import shutil
import subprocess

from v5_probability_audit import ROOT, replace_once


def build(workspace):
    workspace.mkdir(parents=True, exist_ok=False)
    for name in ('Cargo.toml', 'Cargo.lock'):
        shutil.copy2(ROOT / name, workspace / name)
    for name in ('crates', 'config'):
        shutil.copytree(ROOT / name, workspace / name)

    engine = workspace / 'crates/si-engine/src'
    recipes = Path(__file__).resolve().parent
    shutil.copy2(recipes / 'v5_features.rs', engine / 'conversion/v5_experiment.rs')
    replace_once(engine / 'conversion.rs', 'mod input;', 'mod input;\npub mod v5_experiment;')
    replace_once(engine / 'lib.rs', 'pub use si_lexicon::IndexId;',
                 'pub use si_lexicon::IndexId;\npub use conversion::v5_experiment;')
    replace_once(engine / 'conversion.rs', "impl<'a> CandidateEngine<'a> {",
                 "impl<'a> CandidateEngine<'a> {\n"
                 '    pub fn experiment_buffer(&self, source: &str) -> [Option<f64>; v5_experiment::BUFFER_SIZE] {\n'
                 '        v5_experiment::buffer(source, self.base.lexicon())\n'
                 '    }')

    evidence = engine / 'ranking_features.rs'
    replace_once(evidence, '    pub unigram_bits: f64,',
                 '    pub english_completion_ratio: f64,\n'
                 '    pub experiment_path: Vec<(String, f64)>,\n'
                 '    pub unigram_bits: f64,')
    replace_once(evidence, '            statistics: Vec::new(),',
                 '            statistics: Vec::new(),\n'
                 '            english_completion_ratio: next.english_completion_ratio,\n'
                 '            experiment_path: self.experiment_path.iter()\n'
                 '                .chain(&next.experiment_path).cloned().collect(),')
    replace_once(engine / 'conversion/scoring.rs', '                unigram_bits: base_prior.log2(),',
                 '                english_completion_ratio: 1.0,\n'
                 '                experiment_path: vec![(word.text.to_owned(), priors.personalized.log2())],\n'
                 '                unigram_bits: base_prior.log2(),')
    replace_once(engine / 'conversion/search.rs',
                 '        evidence.abbreviated_tokens = usize::from(edge.is_abbreviated());',
                 '        if edge.word.language == Language::English && edge.missing > 0 {\n'
                 '            let typed = edge.end - start;\n'
                 '            evidence.english_completion_ratio = typed as f64 / (typed + edge.missing) as f64;\n'
                 '        }\n'
                 '        evidence.abbreviated_tokens = usize::from(edge.is_abbreviated());')

    hybrid = engine / 'conversion/hybrid.rs'
    replace_once(hybrid, 'use crate::ranking_features;',
                 'use crate::ranking_features;\nuse super::v5_experiment::{self, Extension};')
    replace_once(hybrid, '    v5: bool,', '    v5: bool,\n    extension: Option<Extension>,')
    replace_once(hybrid, '    pub model_score: Option<f64>,',
                 '    pub model_score: Option<f64>,\n    pub experiment_features: Option<Vec<Option<f64>>>,')
    replace_once(hybrid, '            model_score: None,',
                 '            model_score: None,\n            experiment_features: None,')
    replace_once(hybrid, '        let matches = |extra: &[&str]| {',
                 '        let matches = |extra: &[&str], extension: &[&str]| {')
    replace_once(hybrid, '                    .chain(RERANKER_FEATURES))',
                 '                    .chain(RERANKER_FEATURES).chain(extension.iter().copied()))')
    replace_once(hybrid, '        let v5 = matches(&ranking_features::V5_ADDITIONS);\n        if !v5 && !matches(&[]) {',
                 '        let extension = Extension::ALL.into_iter().find(|extension| {\n'
                 '            matches(&ranking_features::V5_ADDITIONS, extension.names())\n'
                 '        });\n'
                 '        let v5 = extension.is_some() || matches(&ranking_features::V5_ADDITIONS, &[]);\n'
                 '        if !v5 && !matches(&[], &[]) {')
    replace_once(hybrid, '            v5,', '            v5,\n            extension,')
    replace_once(hybrid, '                &mut rows,\n                source,',
                 '                engine,\n                &mut rows,\n                source,')
    replace_once(hybrid, '    fn enhance(\n        &self,',
                 '    fn enhance(\n        &self,\n        engine: &CandidateEngine<\'_>,')
    replace_once(hybrid, '        for mut feature in features {',
                 '        let extended = self.extension.map(|extension| {\n'
                 '            let lexical: Vec<_> = features.iter().map(|feature| feature.values[51]).collect();\n'
                 '            let ratios: Vec<_> = features.iter().map(|feature| {\n'
                 '                v5_experiment::completion(&rows[feature.row_index].candidate)\n'
                 '            }).collect();\n'
                 '            (extension, v5_experiment::enrich(&lexical, engine.experiment_buffer(source), &ratios))\n'
                 '        });\n'
                 '        for (feature_index, mut feature) in features.into_iter().enumerate() {')
    replace_once(hybrid, '            row.model_score = Some(self.ranker.score(&feature.values)?);',
                 '            if let Some((extension, values)) = &extended {\n'
                 '                feature.values.extend_from_slice(extension.values(&values[feature_index]));\n'
                 '            }\n'
                 '            row.model_score = Some(self.ranker.score(&feature.values)?);\n'
                 '            row.experiment_features = Some(feature.values);')

    cli = workspace / 'crates/si-cli/src'
    (cli / 'bin').mkdir()
    shutil.copy2(recipes / 'v5_pool_cli.rs', cli / 'bin/v5-pool-features.rs')
    feature_export = cli / 'rank_features.rs'
    replace_once(feature_export, '                    writeln!(output, "{language}\\t{text}\\t{features}")?;',
                 '                    let path = candidate.ranking_evidence.as_ref().unwrap();\n'
                 '                    let edges = path.experiment_path.iter().map(|(word, logp)| {\n'
                 '                        let hex = word.bytes().map(|b| format!("{b:02x}")).collect::<String>();\n'
                 '                        format!("{hex}:{logp}")\n'
                 '                    }).collect::<Vec<_>>().join(",");\n'
                 '                    writeln!(output, "{language}\\t{text}\\t{features}\\t{}\\t{edges}\\t{},{},{},{},{}",\n'
                 '                        path.english_completion_ratio, path.unigram_bits, path.gram_adjustment_bits,\n'
                 '                        path.token_cost_bits, path.language_cost_bits, path.spelling_cost_bits)?;')
    replace_once(feature_export, '            if pinyin_paths {\n                let paths = if languages.chinese {',
                 '            let buffer = engine.experiment_buffer(&source).iter()\n'
                 '                .map(|value| value.map_or_else(|| "null".to_owned(), |v| v.to_string()))\n'
                 '                .collect::<Vec<_>>().join(",");\n'
                 '            writeln!(output, "BUFFER\\t{buffer}")?;\n'
                 '            if pinyin_paths {\n                let paths = if languages.chinese {')

    cargo = ['cargo', 'build', '--release', '--locked', '--offline', '--manifest-path', str(workspace / 'Cargo.toml')]
    subprocess.run([*cargo, '-p', 'si-cli', '--bins',
                    '--features', 'si-engine/experimental-ranking'], check=True)
    subprocess.run([*cargo, '-p', 'si-macos-bridge'], check=True)
    subprocess.run(['cargo', 'test', '--release', '--locked', '--offline', '--manifest-path',
                    str(workspace / 'Cargo.toml'), '-p', 'si-engine', '--lib', 'v5_experiment'],
                   check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, required=True)
    build(parser.parse_args().workspace.resolve())
