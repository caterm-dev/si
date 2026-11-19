use crate::Result;
use crate::tensor::{Matrix, Weights, dot};

struct Linear {
    weights: Matrix,
    bias: Vec<f32>,
}

impl Linear {
    fn load(w: &mut Weights, name: &str, output: usize, input: usize) -> Result<Self> {
        Ok(Self {
            weights: w.matrix(&format!("{name}.weight"), output, input)?,
            bias: w.vector(&format!("{name}.bias"), output)?,
        })
    }

    fn run(&self, x: &Matrix) -> Matrix {
        let mut value = x.project(&self.weights);
        for row in value.values.chunks_exact_mut(value.cols) {
            for (x, bias) in row.iter_mut().zip(&self.bias) {
                *x += bias;
            }
        }
        value
    }
}

pub(crate) struct Norm {
    weights: Vec<f32>,
    bias: Vec<f32>,
}

impl Norm {
    pub fn load(w: &mut Weights, name: &str, width: usize) -> Result<Self> {
        Ok(Self {
            weights: w.vector(&format!("{name}.weight"), width)?,
            bias: w.vector(&format!("{name}.bias"), width)?,
        })
    }

    pub fn run(&self, x: &Matrix) -> Matrix {
        let mut out = Matrix::zeros(x.rows, x.cols);
        for i in 0..x.rows {
            let row = x.row(i);
            let mean = row.iter().sum::<f32>() / x.cols as f32;
            let var = row.iter().map(|value| (value - mean).powi(2)).sum::<f32>() / x.cols as f32;
            let inverse = (var + 1e-5).sqrt().recip();
            for (j, value) in out.row_mut(i).iter_mut().enumerate() {
                *value = (row[j] - mean) * inverse * self.weights[j] + self.bias[j];
            }
        }
        out
    }
}

pub(crate) struct KeyValue {
    k: Matrix,
    v: Matrix,
}

pub(crate) struct Attention {
    q: Linear,
    k: Linear,
    v: Linear,
    out: Linear,
    heads: usize,
}

impl Attention {
    fn load(w: &mut Weights, prefix: &str, width: usize, heads: usize, lm: bool) -> Result<Self> {
        let projection = if lm { "qkv.weight" } else { "in_proj_weight" };
        let bias = if lm { "qkv.bias" } else { "in_proj_bias" };
        let packed = w.matrix(&format!("{prefix}{projection}"), width * 3, width)?;
        let packed_bias = w.vector(&format!("{prefix}{bias}"), width * 3)?;
        let split = |i| Linear {
            weights: packed.select_rows(i * width..(i + 1) * width),
            bias: packed_bias[i * width..(i + 1) * width].to_vec(),
        };
        Ok(Self {
            q: split(0),
            k: split(1),
            v: split(2),
            out: Linear::load(
                w,
                &format!("{prefix}{}", if lm { "proj" } else { "out_proj" }),
                width,
                width,
            )?,
            heads,
        })
    }

    pub fn key_values(&self, x: &Matrix) -> KeyValue {
        KeyValue {
            k: self.k.run(x),
            v: self.v.run(x),
        }
    }

    pub fn run(&self, query: &Matrix, kv: &KeyValue, causal: bool) -> Matrix {
        let q = self.q.run(query);
        let width = q.cols / self.heads;
        let scale = (width as f32).sqrt().recip();
        let mut output = Matrix::zeros(q.rows, q.cols);
        let mut logits = vec![0.0; kv.k.rows];
        for i in 0..q.rows {
            let keys = if causal { i + 1 } else { kv.k.rows };
            let scores = &mut logits[..keys];
            for head in 0..self.heads {
                let range = head * width..(head + 1) * width;
                for (j, score) in scores.iter_mut().enumerate() {
                    *score = dot(&q.row(i)[range.clone()], &kv.k.row(j)[range.clone()]) * scale;
                }
                let max = scores.iter().copied().fold(f32::NEG_INFINITY, f32::max);
                let mut sum = 0.0;
                for score in &mut *scores {
                    *score = (*score - max).exp();
                    sum += *score;
                }
                let row = &mut output.row_mut(i)[range.clone()];
                for (j, score) in scores.iter().enumerate() {
                    let probability = *score / sum;
                    for (value, v) in row.iter_mut().zip(&kv.v.row(j)[range.clone()]) {
                        *value += probability * v;
                    }
                }
            }
        }
        self.out.run(&output)
    }
}

fn gelu(x: f32) -> f32 {
    // Portable approximation to erf (Abramowitz and Stegun 7.1.26).
    let z = x.abs() * std::f32::consts::FRAC_1_SQRT_2;
    let t = (1.0 + 0.3275911 * z).recip();
    let poly =
        ((((1.0614054 * t - 1.4531521) * t + 1.4214138) * t - 0.28449672) * t + 0.2548296) * t;
    let tail = poly * (-z * z).exp();
    x * 0.5 * if x < 0.0 { tail } else { 2.0 - tail }
}

#[derive(Clone, Copy, PartialEq)]
pub(crate) enum BlockKind {
    CharacterLm,
    Encoder,
    Decoder,
}

pub(crate) struct Block {
    norm1: Norm,
    attention: Attention,
    norm2: Norm,
    cross: Option<(Attention, Norm)>,
    fc: Linear,
    out: Linear,
    causal: bool,
}

impl Block {
    pub fn load(
        w: &mut Weights,
        name: &str,
        width: usize,
        heads: usize,
        hidden: usize,
        kind: BlockKind,
    ) -> Result<Self> {
        let lm = kind == BlockKind::CharacterLm;
        let decoder = kind == BlockKind::Decoder;
        Ok(Self {
            norm1: Norm::load(w, &format!("{name}.norm1"), width)?,
            attention: Attention::load(
                w,
                &format!("{name}.{}", if lm { "" } else { "self_attn." }),
                width,
                heads,
                lm,
            )?,
            norm2: Norm::load(
                w,
                &format!("{name}.norm{}", if decoder { 3 } else { 2 }),
                width,
            )?,
            cross: if decoder {
                Some((
                    Attention::load(w, &format!("{name}.multihead_attn."), width, heads, false)?,
                    Norm::load(w, &format!("{name}.norm2"), width)?,
                ))
            } else {
                None
            },
            fc: Linear::load(
                w,
                &format!("{name}.{}", if lm { "fc" } else { "linear1" }),
                hidden,
                width,
            )?,
            out: Linear::load(
                w,
                &format!("{name}.{}", if lm { "out" } else { "linear2" }),
                width,
                hidden,
            )?,
            causal: kind != BlockKind::Encoder,
        })
    }

    pub fn cross_key_values(&self, memory: &Matrix) -> KeyValue {
        self.cross
            .as_ref()
            .expect("decoder block")
            .0
            .key_values(memory)
    }

    pub fn run(&self, x: &mut Matrix, memory: Option<&KeyValue>) {
        let relative = self.norm1.run(x);
        x.add(self.attention.run(
            &relative,
            &self.attention.key_values(&relative),
            self.causal,
        ));
        if let Some((cross, norm)) = &self.cross {
            x.add(cross.run(&norm.run(x), memory.expect("decoder memory"), false));
        }
        let mut hidden = self.fc.run(&self.norm2.run(x));
        hidden.values.iter_mut().for_each(|x| *x = gelu(*x));
        x.add(self.out.run(&hidden));
    }
}
