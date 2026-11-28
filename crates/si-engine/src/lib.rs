//! Platform-independent input method engine for SI.

mod conversion;
mod han;
mod pinyin;
pub mod presentation;
pub mod resources;
pub mod segmentation;
mod text_boundaries;

/// Exact punctuation-delimited field fragment used by local neural ranking.
pub use text_boundaries::last_fragment as model_context_fragment;

pub use conversion::{
    Candidate, CandidateEngine, CandidateLanguage, CandidatePool, CandidatePoolInspector,
    ConversionBoundary, ConversionOptions, ConversionPreferences, Correction, CorrectionKind,
    CorrectionSensitivity, EnabledLanguages, PathPreference, PersonalPhrase, PoolEntry,
    PoolOptions, PoolToken, PrecedingTextCache, SmallReranker, TokenPreference,
};
pub use si_lexicon::IndexId;
