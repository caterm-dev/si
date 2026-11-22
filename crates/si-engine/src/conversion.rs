mod cache;
mod context;
mod input;
mod lookup;
mod ranking;
mod reranking;
mod scoring;
mod search;

use si_lexicon::{IndexId, WordId};

use self::input::Input;
use self::lookup::Lookup;
use self::scoring::Scoring;
use crate::resources::EngineResources;
pub use reranking::SmallReranker;

const MAX_OUTPUT_BYTES: usize = 4_096;

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

/// The single key edit used by a Pinyin suggestion.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CorrectionKind {
    MissingKey,
    NeighborKey,
    AdjacentSwap,
}

/// The edited dictionary word's span in the original UTF-8 input.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Correction {
    pub kind: CorrectionKind,
    pub word_start_bytes: usize,
    pub word_end_bytes: usize,
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

#[derive(Clone, Copy, Default)]
pub struct ConversionPreferences<'a> {
    pub tokens: &'a [TokenPreference<'a>],
    pub paths: &'a [PathPreference<'a>],
}

/// Optional scoring stages selected independently for a single conversion.
#[derive(Clone, Copy, Default)]
pub struct ConversionOptions<'a> {
    pub correction: Option<CorrectionSensitivity>,
    pub reranker: Option<&'a SmallReranker>,
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
    /// Bounded whole-input reward from the optional character model.
    pub reranking_bonus: f64,
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
    /// Whole-input typo suggestion requiring explicit acceptance by the caller.
    pub correction: Option<Correction>,
    pub token_bonus: f64,
}

impl Candidate {
    pub fn is_corrected(&self) -> bool {
        self.correction.is_some()
    }

    /// Select a default for whole-input acceptance without accepting a typo suggestion.
    /// The original-text row remains eligible when no ordinary whole result exists.
    pub fn default_for_whole_input(rows: &[Self], input_bytes: usize) -> Option<&Self> {
        rows.iter()
            .find(|row| row.consumed_bytes == input_bytes && !row.is_corrected())
    }
}

/// Confidence margin over the best complete exact path, in bits.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum CorrectionSensitivity {
    #[default]
    Conservative,
    HigherRecall,
}

impl CorrectionSensitivity {
    fn margin(self) -> f64 {
        match self {
            Self::Conservative => 2.0,
            Self::HigherRecall => 0.0,
        }
    }
}

/// Reuse this engine across requests. Construction indexes dictionary
/// readings. Candidate generation uses the loaded resources in memory.
pub struct CandidateEngine<'a> {
    pinyin_correction: Option<CorrectionSensitivity>,
    lookup: Lookup<'a>,
    scoring: Scoring<'a>,
    context: Option<context::Context<'a>>,
}

impl<'a> CandidateEngine<'a> {
    pub fn new(base: &'a EngineResources, user: Option<&'a EngineResources>) -> Self {
        let lookup = Lookup::new(base.lexicon(), user.map(EngineResources::lexicon));
        let scoring = Scoring::new(base, user);
        let user_with_grams = user.filter(|user| user.grams().is_some());
        let context = (base.grams().is_some() || user_with_grams.is_some()).then(|| {
            context::Context::new(
                base.lexicon(),
                user_with_grams.map(EngineResources::lexicon),
            )
        });
        Self {
            pinyin_correction: None,
            lookup,
            scoring,
            context,
        }
    }

    /// Enable bounded Pinyin typo suggestions. Disabled by default.
    pub fn with_pinyin_correction(self, enabled: bool) -> Self {
        self.with_correction_sensitivity(enabled.then_some(CorrectionSensitivity::default()))
    }

    /// Set how strongly a suggestion must beat ordinary decoding. None disables correction.
    pub fn with_correction_sensitivity(
        mut self,
        sensitivity: Option<CorrectionSensitivity>,
    ) -> Self {
        self.set_correction_sensitivity(sensitivity);
        self
    }

    /// Configure correction before querying candidates.
    pub fn set_correction_sensitivity(&mut self, sensitivity: Option<CorrectionSensitivity>) {
        if sensitivity.is_some() {
            self.prepare_pinyin_correction();
        }
        self.pinyin_correction = sensitivity;
    }

    /// Prepare the immutable index before requesting correction on a shared engine.
    pub fn prepare_pinyin_correction(&mut self) {
        self.lookup
            .prepare_corrections(|word| self.scoring.unigram(word).personalized);
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
        self.convert_with_correction(
            text,
            languages,
            preview,
            phrases,
            preferences,
            preceding_text,
            self.pinyin_correction,
        )
    }

    /// Use a per-request mode. Shared-engine callers must prepare the index first.
    #[allow(clippy::too_many_arguments)]
    pub fn convert_with_correction(
        &self,
        text: &str,
        languages: EnabledLanguages,
        preview: bool,
        phrases: &[PersonalPhrase<'_>],
        preferences: ConversionPreferences<'_>,
        preceding_text: &str,
        correction: Option<CorrectionSensitivity>,
    ) -> Vec<Candidate> {
        self.convert_with_options(
            text,
            languages,
            preview,
            phrases,
            preferences,
            preceding_text,
            ConversionOptions {
                correction,
                reranker: None,
            },
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn convert_with_options(
        &self,
        text: &str,
        languages: EnabledLanguages,
        preview: bool,
        phrases: &[PersonalPhrase<'_>],
        preferences: ConversionPreferences<'_>,
        preceding_text: &str,
        options: ConversionOptions<'_>,
    ) -> Vec<Candidate> {
        if text.is_empty() {
            return Vec::new();
        }
        let mut candidates = if languages.chinese || languages.english {
            let history = self
                .context
                .as_ref()
                .map_or_else(Default::default, |context| {
                    context.history(preceding_text, &self.scoring)
                });
            let personal = Lookup::personal(phrases);
            search::run(
                &Input::new(text),
                languages,
                &self.lookup,
                self.scoring.session(history),
                preview,
                &personal,
                preferences,
                options.correction,
                options
                    .reranker
                    .filter(|_| !preview)
                    .map(|model| (model, preceding_text, text.len())),
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
            reranking_bonus: 0.0,
            completion: false,
            lexical_tokens: 0,
            source_boundaries: Vec::new(),
            confirmation_boundaries: Vec::new(),
            personal: false,
            preferred: false,
            verbatim: false,
            correction: None,
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
