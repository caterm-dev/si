//! Inference for exported single-output LightGBM LambdaRank trees.
use std::ops::Range;
use std::path::Path;

use serde_json::Value;

use crate::json;

use crate::{Result, invalid};

enum Node {
    Leaf {
        value: f64,
    },
    Numeric {
        feature: usize,
        threshold: f64,
        missing: Missing,
        default_left: bool,
        left: Box<Node>,
        right: Box<Node>,
    },
    Categorical {
        feature: usize,
        categories: Vec<i32>,
        left: Box<Node>,
        right: Box<Node>,
    },
}

enum Missing {
    None,
    Nan,
    Zero,
}

impl Node {
    fn parse(raw: &Value) -> Result<Self> {
        let kind = json::text(&raw["kind"])?;
        if kind == "leaf" {
            return Ok(Self::Leaf {
                value: json::number(&raw["value"])?,
            });
        }
        let feature = json::integer(&raw["feature"])?;
        let left = Box::new(Self::parse(&raw["left"])?);
        let right = Box::new(Self::parse(&raw["right"])?);
        match kind {
            "numeric" => {
                let missing = match json::text(&raw["missing"])? {
                    "None" => Missing::None,
                    "NaN" => Missing::Nan,
                    "Zero" => Missing::Zero,
                    _ => return Err(invalid("unsupported missing value policy")),
                };
                let default_left = raw["default_left"]
                    .as_bool()
                    .ok_or_else(|| invalid("missing default branch"))?;
                Ok(Self::Numeric {
                    feature,
                    threshold: json::number(&raw["threshold"])?,
                    missing,
                    default_left,
                    left,
                    right,
                })
            }
            "categorical" => {
                let categories = json::array(&raw["categories"])?
                    .iter()
                    .map(|category| {
                        category
                            .as_i64()
                            .and_then(|n| i32::try_from(n).ok())
                            .ok_or_else(|| invalid("invalid category"))
                    })
                    .collect::<Result<_>>()?;
                Ok(Self::Categorical {
                    feature,
                    categories,
                    left,
                    right,
                })
            }
            _ => Err(invalid("unsupported node type")),
        }
    }

    fn valid(&self, width: usize) -> bool {
        match self {
            Self::Leaf { value } => value.is_finite(),
            Self::Numeric {
                feature,
                threshold,
                left,
                right,
                ..
            } => {
                *feature < width && threshold.is_finite() && left.valid(width) && right.valid(width)
            }
            Self::Categorical {
                feature,
                categories,
                left,
                right,
            } => {
                *feature < width
                    && !categories.is_empty()
                    && left.valid(width)
                    && right.valid(width)
            }
        }
    }

    fn split_feature(&self) -> Option<usize> {
        match self {
            Self::Leaf { .. } => None,
            Self::Numeric { feature, .. } | Self::Categorical { feature, .. } => Some(*feature),
        }
    }

    fn branch(&self, row: &[Option<f64>]) -> &Self {
        let (test, left, right) = match self {
            Self::Leaf { .. } => unreachable!("leaf has no branch"),
            Self::Numeric {
                feature,
                threshold,
                missing,
                default_left,
                left,
                right,
            } => {
                let value = row[*feature];
                let take_left = match missing {
                    Missing::Nan if value.is_none() => *default_left,
                    Missing::Zero if value.unwrap_or(0.0).abs() <= 1e-35_f32 as f64 => {
                        *default_left
                    }
                    _ => value.unwrap_or(0.0) <= *threshold,
                };
                (take_left, left, right)
            }
            Self::Categorical {
                feature,
                categories,
                left,
                right,
            } => {
                let take_left = row[*feature].is_some_and(|value| {
                    value >= 0.0 && value <= i32::MAX as f64 && categories.contains(&(value as i32))
                });
                (take_left, left, right)
            }
        };
        if test { left } else { right }
    }

    fn score(&self, row: &[Option<f64>]) -> f64 {
        let mut node = self;
        loop {
            if let Self::Leaf { value } = node {
                return *value;
            }
            node = node.branch(row);
        }
    }

    fn requires_features(&self, row: &[Option<f64>], unresolved: &Range<usize>) -> bool {
        let mut node = self;
        while let Some(feature) = node.split_feature() {
            if unresolved.contains(&feature) {
                return true;
            }
            node = node.branch(row);
        }
        false
    }
}

pub struct LambdaRank {
    pub feature_names: Vec<String>,
    pub reranker_checkpoint_sha256: String,
    pub correction_margins: Option<[f64; 2]>,
    trees: Vec<Node>,
}

impl LambdaRank {
    pub fn open(path: &Path) -> Result<Self> {
        if path.metadata()?.len() > 8 * 1024 * 1024 {
            return Err(invalid("ranker exceeds size limit"));
        }
        let raw: Value =
            serde_json::from_reader(std::io::BufReader::new(std::fs::File::open(path)?))?;
        let correction_margins = match raw.get("correction_margins") {
            None => None,
            Some(margins) => {
                let conservative = json::number(&margins["conservative"])?;
                let higher_recall = json::number(&margins["higher_recall"])?;
                if conservative < higher_recall {
                    return Err(invalid("invalid correction margin order"));
                }
                Some([conservative, higher_recall])
            }
        };
        let model = Self {
            feature_names: json::strings(&raw["feature_names"])?,
            reranker_checkpoint_sha256: json::text(&raw["reranker_checkpoint_sha256"])?.to_owned(),
            correction_margins,
            trees: json::array(&raw["trees"])?
                .iter()
                .map(Node::parse)
                .collect::<Result<_>>()?,
        };
        if raw["schema"].as_u64() != Some(1)
            || model.feature_names.is_empty()
            || model.trees.is_empty()
            || !model
                .trees
                .iter()
                .all(|tree| tree.valid(model.feature_names.len()))
        {
            return Err(invalid("invalid LambdaRank model"));
        }
        Ok(model)
    }

    pub fn score(&self, row: &[Option<f64>]) -> Result<f64> {
        if row.len() != self.feature_names.len()
            || row.iter().flatten().any(|value| !value.is_finite())
        {
            return Err(invalid("invalid LambdaRank feature row"));
        }
        let score: f64 = self.trees.iter().map(|tree| tree.score(row)).sum();
        if !score.is_finite() {
            return Err(invalid("nonfinite LambdaRank score"));
        }
        Ok(score)
    }

    /// Walk the branches decided by known values, including known missing values.
    /// Return true as soon as a tree reaches a feature the caller has yet to compute.
    pub fn requires_features(&self, row: &[Option<f64>], unresolved: Range<usize>) -> Result<bool> {
        if row.len() != self.feature_names.len() || unresolved.end > row.len() {
            return Err(invalid("invalid LambdaRank feature row"));
        }
        Ok(self
            .trees
            .iter()
            .any(|tree| tree.requires_features(row, &unresolved)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn required_features_follow_known_branches_and_missing_values() {
        let leaf = |value| Box::new(Node::Leaf { value });
        let ranker = LambdaRank {
            feature_names: ["lexical", "conditional", "context_gain"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            reranker_checkpoint_sha256: String::new(),
            correction_margins: None,
            trees: vec![Node::Numeric {
                feature: 0,
                threshold: 0.0,
                missing: Missing::None,
                default_left: false,
                left: leaf(1.0),
                right: Box::new(Node::Numeric {
                    feature: 1,
                    threshold: 0.0,
                    missing: Missing::None,
                    default_left: false,
                    left: leaf(2.0),
                    right: Box::new(Node::Numeric {
                        feature: 2,
                        threshold: 0.0,
                        missing: Missing::Nan,
                        default_left: false,
                        left: leaf(3.0),
                        right: leaf(4.0),
                    }),
                }),
            }],
        };

        assert!(!ranker.requires_features(&[None, None, None], 1..3).unwrap());
        assert!(
            ranker
                .requires_features(&[Some(1.0), None, None], 1..3)
                .unwrap()
        );
        let skip_gain = [Some(1.0), Some(-1.0), None];
        assert!(!ranker.requires_features(&skip_gain, 2..3).unwrap());
        assert_eq!(ranker.score(&skip_gain).unwrap(), 2.0);
        let known_missing_gain = [Some(1.0), Some(1.0), None];
        assert!(ranker.requires_features(&known_missing_gain, 2..3).unwrap());
        assert_eq!(ranker.score(&known_missing_gain).unwrap(), 4.0);
    }
}
