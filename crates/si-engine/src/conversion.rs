mod input;
mod lookup;
mod ranking;
mod scoring;
mod search;

use si_lexicon::{IndexId, WordId};

use self::input::Input;
use self::lookup::Lookup;
use self::scoring::Scoring;
use crate::resources::EngineResources;

/// Languages eligible for dictionary lookup in one request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EnabledLanguages {
    pub chinese: bool,
    pub english: bool,
}

impl Default for EnabledLanguages {
    fn default() -> Self {
        Self {
            chinese: true,
            english: true,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum CandidateLanguage {
    Chinese,
    English,
    Mixed,
    Literal,
}

/// One possible conversion of a prefix or the whole input.
#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub text: String,
    pub language: CandidateLanguage,
    /// Exact length in UTF-8 bytes from the start of the original input.
    pub consumed_bytes: usize,
    /// Higher scores rank first within the same consumed span.
    pub score_bits: Option<f64>,
    /// The last word extends the typed spelling.
    pub completion: bool,
}

/// Reuse this engine across requests. Construction indexes dictionary
/// readings. Candidate generation uses the loaded resources in memory.
pub struct CandidateEngine<'a> {
    lookup: Lookup<'a>,
    scoring: Scoring<'a>,
}

impl<'a> CandidateEngine<'a> {
    pub fn new(base: &'a EngineResources, user: Option<&'a EngineResources>) -> Self {
        let lookup = Lookup::new(base.lexicon(), user.map(EngineResources::lexicon));
        let scoring = Scoring::new(base, user, &lookup);
        Self { lookup, scoring }
    }

    /// Return ranked candidates and one exact literal for nonempty input.
    pub fn candidates(&self, text: &str, languages: EnabledLanguages) -> Vec<Candidate> {
        if text.is_empty() {
            return Vec::new();
        }
        let mut candidates = if languages.chinese || languages.english {
            search::run(&Input::new(text), languages, &self.lookup, &self.scoring)
        } else {
            Vec::new()
        };
        candidates.push(Candidate {
            text: text.to_owned(),
            language: CandidateLanguage::Literal,
            consumed_bytes: text.len(),
            score_bits: None,
            completion: false,
        });
        candidates
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
enum Language {
    Chinese,
    English,
}

impl Language {
    const ALL: [Self; 2] = [Self::Chinese, Self::English];

    fn from_index(index: IndexId) -> Option<Self> {
        match index {
            IndexId(0) => Some(Self::Chinese),
            IndexId(1) => Some(Self::English),
            _ => None,
        }
    }

    fn enabled(self, languages: EnabledLanguages) -> bool {
        match self {
            Self::Chinese => languages.chinese,
            Self::English => languages.english,
        }
    }

    fn mask(self) -> usize {
        1 << self as usize
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct WordIds {
    base: Option<WordId>,
    user: Option<WordId>,
}
