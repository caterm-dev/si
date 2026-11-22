//! Platform-independent input method engine for SI.

mod conversion;
mod han;
mod pinyin;
pub mod resources;
pub mod segmentation;

pub use conversion::{
    Candidate, CandidateEngine, CandidateLanguage, ConversionBoundary, ConversionPreferences,
    Correction, CorrectionKind, CorrectionSensitivity, EnabledLanguages, PathPreference,
    PersonalPhrase, TokenPreference,
};
pub use si_lexicon::IndexId;
