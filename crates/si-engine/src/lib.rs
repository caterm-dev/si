//! Platform-independent input method engine for SI.

mod conversion;
mod han;
mod pinyin;
pub mod presentation;
pub mod resources;
pub mod segmentation;

pub use conversion::{
    Candidate, CandidateEngine, CandidateLanguage, ConversionBoundary, ConversionOptions,
    ConversionPreferences, Correction, CorrectionKind, CorrectionSensitivity, EnabledLanguages,
    PathPreference, PersonalPhrase, SmallReranker, TokenPreference,
};
pub use si_lexicon::IndexId;
