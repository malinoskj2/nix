use std::error::Error;

fn parse(input: &str) -> Result<u8, String> {
    input.parse().map_err(|_| String::from("bad"))
}

fn validate(input: &str) -> Result<(), &'static str> {
    if input.is_empty() { Err("empty") } else { Ok(()) }
}

fn load() -> Result<(), Box<dyn Error + Send + Sync>> {
    Ok(())
}

fn typed(input: &str) -> Result<u8, std::num::ParseIntError> {
    input.parse()
}

struct Port(u16);

impl std::str::FromStr for Port {
    type Err = String;

    fn from_str(input: &str) -> Result<Self, Self::Err> {
        input.parse().map(Port).map_err(|_| String::from("bad port"))
    }
}

fn main() {
    let _ = (parse("1"), validate("x"), load(), typed("1"), "1".parse::<Port>().map(|p| p.0));
}
