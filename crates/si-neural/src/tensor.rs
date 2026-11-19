//! Contiguous row-major FP32 matrices for the two inference graphs.

use std::collections::BTreeMap;
use std::io::{self, BufReader, Read};
use std::path::Path;

use crate::{Result, invalid};

pub(crate) struct Matrix {
    pub rows: usize,
    pub cols: usize,
    pub values: Vec<f32>,
}

impl Matrix {
    pub fn zeros(rows: usize, cols: usize) -> Self {
        Self {
            rows,
            cols,
            values: vec![0.0; rows * cols],
        }
    }

    pub fn row(&self, index: usize) -> &[f32] {
        &self.values[index * self.cols..(index + 1) * self.cols]
    }

    pub fn row_mut(&mut self, index: usize) -> &mut [f32] {
        &mut self.values[index * self.cols..(index + 1) * self.cols]
    }

    pub fn select_rows(&self, indices: impl IntoIterator<Item = usize>) -> Self {
        let values: Vec<_> = indices
            .into_iter()
            .flat_map(|i| self.row(i).iter().copied())
            .collect();
        Self {
            rows: values.len() / self.cols,
            cols: self.cols,
            values,
        }
    }

    pub fn add(&mut self, other: Self) {
        debug_assert_eq!((self.rows, self.cols), (other.rows, other.cols));
        for (lhs, rhs) in self.values.iter_mut().zip(other.values) {
            *lhs += rhs;
        }
    }

    pub fn project(&self, weights: &Self) -> Self {
        assert_eq!(self.cols, weights.cols);
        let mut output = Self::zeros(self.rows, weights.rows);
        multiply(self, weights, &mut output);
        output
    }
}

#[cfg(all(target_os = "macos", not(feature = "portable-matmul")))]
#[link(name = "Accelerate", kind = "framework")]
unsafe extern "C" {
    fn cblas_sgemm(
        order: i32,
        trans_a: i32,
        trans_b: i32,
        m: i32,
        n: i32,
        k: i32,
        alpha: f32,
        a: *const f32,
        lda: i32,
        b: *const f32,
        ldb: i32,
        beta: f32,
        c: *mut f32,
        ldc: i32,
    );
}

#[cfg(all(target_os = "macos", not(feature = "portable-matmul")))]
fn multiply(input: &Matrix, weights: &Matrix, output: &mut Matrix) {
    // Dimensions are validated against the bundle limits, and all three matrices
    // are contiguous, disjoint buffers with the row strides passed to BLAS.
    unsafe {
        cblas_sgemm(
            101,
            111,
            112,
            input.rows as i32,
            weights.rows as i32,
            input.cols as i32,
            1.0,
            input.values.as_ptr(),
            input.cols as i32,
            weights.values.as_ptr(),
            weights.cols as i32,
            0.0,
            output.values.as_mut_ptr(),
            output.cols as i32,
        );
    }
}

#[cfg(any(not(target_os = "macos"), feature = "portable-matmul"))]
fn multiply(input: &Matrix, weights: &Matrix, output: &mut Matrix) {
    for i in 0..input.rows {
        for (j, result) in output.row_mut(i).iter_mut().enumerate() {
            *result = dot(input.row(i), weights.row(j));
        }
    }
}

pub(crate) fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

pub(crate) struct Weights {
    reader: BufReader<std::fs::File>,
    entries: BTreeMap<String, (Vec<usize>, u64)>,
}

impl Weights {
    pub fn open(path: &Path, shapes: BTreeMap<String, Vec<usize>>) -> Result<Self> {
        let mut offset = 0_u64;
        let mut entries = BTreeMap::new();
        for (name, shape) in shapes {
            if !matches!(shape.len(), 1 | 2) || shape.iter().any(|&n| n == 0 || n > 65_536) {
                return Err(invalid("invalid tensor dimensions"));
            }
            entries.insert(name, (shape.clone(), offset));
            offset += shape.iter().map(|&n| n as u64).product::<u64>() * 4;
            if offset > 512 * 1024 * 1024 {
                return Err(invalid("weight bundle exceeds limit"));
            }
        }
        let file = std::fs::File::open(path)?;
        if file.metadata()?.len() != offset {
            return Err(invalid("weight size mismatch"));
        }
        Ok(Self {
            reader: BufReader::new(file),
            entries,
        })
    }

    fn read(&mut self, name: &str, expected: &[usize]) -> Result<Vec<f32>> {
        use io::{Seek, SeekFrom};
        let (shape, offset) = self
            .entries
            .remove(name)
            .ok_or_else(|| invalid(format!("missing tensor {name}")))?;
        if shape != expected {
            return Err(invalid(format!("unexpected shape for tensor {name}")));
        }
        self.reader.seek(SeekFrom::Start(offset))?;
        let mut bytes = vec![0; shape.iter().product::<usize>() * 4];
        self.reader.read_exact(&mut bytes)?;
        let values: Vec<_> = bytes
            .chunks_exact(4)
            .map(|chunk| f32::from_le_bytes(chunk.try_into().unwrap()))
            .collect();
        if values.iter().any(|x| !x.is_finite()) {
            return Err(invalid("nonfinite tensor weight"));
        }
        Ok(values)
    }

    pub fn matrix(&mut self, name: &str, rows: usize, cols: usize) -> Result<Matrix> {
        Ok(Matrix {
            rows,
            cols,
            values: self.read(name, &[rows, cols])?,
        })
    }

    pub fn vector(&mut self, name: &str, width: usize) -> Result<Vec<f32>> {
        self.read(name, &[width])
    }

    pub fn finish(self) -> Result<()> {
        if !self.entries.is_empty() {
            return Err(invalid("unexpected tensors in weight bundle"));
        }
        Ok(())
    }
}
