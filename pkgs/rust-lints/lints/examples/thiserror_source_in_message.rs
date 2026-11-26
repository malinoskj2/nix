#![allow(dead_code)]

use thiserror::Error;

#[derive(Debug, Error)]
enum ConfigError {
    #[error("failed to read config: {0}")]
    Read(#[from] std::io::Error),
    #[error("failed to parse {path}: {source}")]
    Parse { path: String, source: std::num::ParseIntError },
    #[error("failed to open {path}: {}", .cause)]
    Open { path: String, #[source] cause: std::io::Error },
    #[error("failed to open {path}")]
    Missing { path: String, #[source] cause: std::io::Error },
    #[error("value {0} out of range")]
    Range(u32),
    #[error("{{0}} is literal")]
    Escaped(#[from] std::fmt::Error),
}

fn main() {}
