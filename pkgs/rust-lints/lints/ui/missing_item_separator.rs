use std::fmt;
use std::io;
const LIMIT: usize = 3;
const NAME: &str = "x";
struct First;
impl First {
    const SIZE: usize = 1;
    const OTHER: usize = 2;

    fn one(&self) {}
    fn two(&self) {}

    /// Documented.
    fn three(&self) {}
    /// Directly against `three`.
    fn four(&self) {}

    fn five(&self) {}
    // A comment does not separate them.
    fn six(&self) {}
}

trait Shape {
    fn area(&self) -> f64;
    fn name(&self) -> &str;
    fn describe(&self) -> String {
        String::new()
    }
    fn print(&self) {}
}

impl Iterator for First {
    type Item = u8;
    fn next(&mut self) -> Option<u8> {
        None
    }
}

fn alpha() {}

fn beta() {}
fn gamma() {}

mod inner {
    pub struct A;
    pub struct B;
}

fn main() {
    let _ = (LIMIT, NAME, First, inner::A, inner::B);
    let _: Option<(fmt::Error, io::Error)> = None;
}
