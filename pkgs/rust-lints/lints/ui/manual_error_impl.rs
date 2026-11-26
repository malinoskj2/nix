use std::fmt;

#[derive(Debug)]
struct ParseError;

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("parse failed")
    }
}

impl std::error::Error for ParseError {}

fn main() {}
