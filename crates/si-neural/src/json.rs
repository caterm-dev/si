use serde_json::Value;

use crate::{Result, invalid};

pub fn integer(value: &Value) -> Result<usize> {
    value
        .as_u64()
        .and_then(|v| usize::try_from(v).ok())
        .ok_or_else(|| invalid("expected unsigned integer"))
}

pub fn number(value: &Value) -> Result<f64> {
    value
        .as_f64()
        .ok_or_else(|| invalid("expected finite number"))
}

pub fn text(value: &Value) -> Result<&str> {
    value
        .as_str()
        .ok_or_else(|| invalid("expected JSON string"))
}

pub fn array(value: &Value) -> Result<&[Value]> {
    value
        .as_array()
        .map(Vec::as_slice)
        .ok_or_else(|| invalid("expected JSON array"))
}
