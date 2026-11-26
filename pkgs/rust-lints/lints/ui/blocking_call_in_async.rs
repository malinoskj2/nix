use std::time::Duration;

async fn sleeps() {
    std::thread::sleep(Duration::from_millis(1));
}

async fn reads() -> std::io::Result<String> {
    std::fs::read_to_string("state.json")
}

async fn opens() -> std::io::Result<std::fs::File> {
    std::fs::File::open("state.json")
}

async fn runs() -> std::io::Result<std::process::Output> {
    std::process::Command::new("true").output()
}

fn offloads() -> impl std::future::Future<Output = ()> {
    async {
        let work = || std::thread::sleep(Duration::from_millis(1));
        work();
    }
}

fn sync_reads() -> std::io::Result<String> {
    std::fs::read_to_string("state.json")
}

fn main() {
    let _ = (sleeps(), reads(), opens(), runs(), offloads(), sync_reads());
}
