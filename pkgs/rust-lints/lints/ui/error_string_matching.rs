use std::io;

fn classify(err: &io::Error) -> bool {
    err.to_string().contains("not found")
}

fn compare(err: io::Error) -> bool {
    err.to_string() == "denied"
}

fn lowered(err: &io::Error) -> bool {
    err.to_string().to_lowercase().starts_with("timed out")
}

fn boxed(err: Box<dyn std::error::Error>) -> bool {
    err.to_string().ends_with("closed")
}

fn by_kind(err: &io::Error) -> bool {
    err.kind() == io::ErrorKind::NotFound
}

fn not_an_error(name: &str) -> bool {
    name.to_string().contains("x")
}

fn main() {
    let err = io::Error::other("x");
    let _ = (classify(&err), lowered(&err), by_kind(&err), not_an_error("x"));
    let _ = compare(io::Error::other("x"));
    let _ = boxed(Box::new(io::Error::other("x")));
}
