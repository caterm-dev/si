mod context;
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(C)]
pub struct ConversionBoundary {
    pub source_bytes: usize,
    pub output_bytes: usize,
}

/// An explicitly saved code, supplied transiently for this request.
pub struct PersonalPhrase<'a> {
    pub spelling: &'a str,
    pub text: &'a str,
    pub language: CandidateLanguage,
    pub pinned: bool,
}

/// A transient frequency preference from a previously selected single-language word.
pub struct TokenPreference<'a> {
    pub spelling: &'a str,
    pub text: &'a str,
    pub language: CandidateLanguage,
    pub bonus: f64,
}

/// A preference for one complete output of a specific consumed source span.
pub struct PathPreference<'a> {
    pub consumed_bytes: usize,
    pub text: &'a str,
    pub language: CandidateLanguage,
    pub frequency: f64,
    pub contextual: f64,
}

#[derive(Default)]
pub struct ConversionPreferences<'a> {
    pub tokens: &'a [TokenPreference<'a>],
    pub paths: &'a [PathPreference<'a>],
}

/// One possible conversion of a prefix or the whole input.
#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub text: String,
    pub language: CandidateLanguage,
    /// Exact length in UTF-8 bytes from the start of the original input.
    pub consumed_bytes: usize,
    /// Lexical score before any transient token or whole-path preference.
    pub score_bits: Option<f64>,
    /// Transient change in log probability from the host field's preceding text.
    pub context_adjustment: f64,
    /// The last word extends the typed spelling.
    pub completion: bool,
    /// Lexical units in the strongest derivation, with direct-word evidence retained.
    pub lexical_tokens: usize,
    /// Syllable and word boundaries in original UTF-8 bytes.
    pub source_boundaries: Vec<usize>,
    /// Aligned source and output boundaries from leading exact Chinese words.
    pub confirmation_boundaries: Vec<ConversionBoundary>,
    pub personal: bool,
    pub preferred: bool,
    pub verbatim: bool,
    pub token_bonus: f64,
}

/// Reuse this engine across requests. Construction indexes dictionary
/// readings. Candidate generation uses the loaded resources in memory.
pub struct CandidateEngine<'a> {
    lookup: Lookup<'a>,
    scoring: Scoring<'a>,
    context: Option<context::Context<'a>>,
}

impl<'a> CandidateEngine<'a> {
    pub fn new(base: &'a EngineResources, user: Option<&'a EngineResources>) -> Self {
        let lookup = Lookup::new(base.lexicon(), user.map(EngineResources::lexicon));
        let scoring = Scoring::new(base, user, &lookup);
        let context = (base.grams().is_some() || user.is_some_and(|user| user.grams().is_some()))
            .then(|| context::Context::new(base.lexicon(), user.map(EngineResources::lexicon)));
        Self {
            lookup,
            scoring,
            context,
        }
    }

    /// Return ranked candidates and one exact literal for nonempty input.
    pub fn candidates(&self, text: &str, languages: EnabledLanguages) -> Vec<Candidate> {
        self.convert(
            text,
            languages,
            false,
            &[],
            ConversionPreferences::default(),
        )
    }

    /// Provisional candidates from a smaller search beam.
    pub fn preview(&self, text: &str, languages: EnabledLanguages) -> Vec<Candidate> {
        self.convert(text, languages, true, &[], ConversionPreferences::default())
    }

    /// Check an exact English prefix independently of the enabled languages.
    pub fn has_english_word_prefix(&self, text: &str, minimum: usize) -> bool {
        let input = Input::new(text);
        let mut found = false;
        self.lookup
            .visit(Language::English, &input, 0, input.len(), |entry| {
                found |= entry.missing == 0 && entry.end >= minimum;
            });
        found
    }

    pub fn convert(
        &self,
        text: &str,
        languages: EnabledLanguages,
        preview: bool,
        phrases: &[PersonalPhrase<'_>],
        preferences: ConversionPreferences<'_>,
    ) -> Vec<Candidate> {
        self.convert_with_context(text, languages, preview, phrases, preferences, "")
    }

    /// Convert `text` with transient committed field text preceding the composition.
    pub fn convert_with_context(
        &self,
        text: &str,
        languages: EnabledLanguages,
        preview: bool,
        phrases: &[PersonalPhrase<'_>],
        preferences: ConversionPreferences<'_>,
        preceding_text: &str,
    ) -> Vec<Candidate> {
        if text.is_empty() {
            return Vec::new();
        }
        let mut candidates = if languages.chinese || languages.english {
            let personal = Lookup::personal(phrases);
            let history = self
                .context
                .as_ref()
                .map_or_else(Default::default, |context| {
                    context.history(preceding_text, &self.scoring)
                });
            search::run(
                &Input::new(text),
                languages,
                &self.lookup,
                self.scoring.session(history),
                preview,
                &personal,
                preferences,
            )
        } else {
            Vec::new()
        };
        candidates.push(Candidate {
            text: text.to_owned(),
            language: CandidateLanguage::Literal,
            consumed_bytes: text.len(),
            score_bits: None,
            context_adjustment: 0.0,
            completion: false,
            lexical_tokens: 0,
            source_boundaries: Vec::new(),
            confirmation_boundaries: Vec::new(),
            personal: false,
            preferred: false,
            verbatim: false,
            token_bonus: 0.0,
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
