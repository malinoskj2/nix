mod utils {}

fn parse(input: &str) -> Result<u8, String> {
    input.parse().map_err(|_| String::from("bad"))
}
fn main() {
    let (sender, _receiver) = std::sync::mpsc::channel::<u8>();
    drop(sender);
    let _ = parse("1").unwrap();
}
