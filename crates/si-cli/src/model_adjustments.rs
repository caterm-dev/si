use si_engine::SmallReranker;
use si_engine::resources::SiConfig;
use std::io::{self, BufRead, Write};
use std::path::Path;

pub(super) fn run(bundle: &Path, config: &SiConfig) -> io::Result<()> {
    let model = SmallReranker::open_with_config(bundle, config.engine.local_model_ranking)?;
    let mut output = io::BufWriter::new(io::stdout().lock());
    for line in io::stdin().lock().lines() {
        let line = line?;
        let mut fields = line.split('\t');
        let context = si_engine::model_context_fragment(fields.next().unwrap_or_default());
        let texts: Vec<_> = fields.collect();
        match model.bonuses(context, &texts) {
            Some(values) => {
                for (i, value) in values.into_iter().enumerate() {
                    if i > 0 {
                        write!(output, "\t")?;
                    }
                    write!(output, "{value:.17}")?;
                }
                writeln!(output)?;
            }
            None => writeln!(output, "abstained")?,
        }
        output.flush()?;
    }
    Ok(())
}
