fn work() {}

fn main() {
    std::thread::spawn(work);
    let _ = std::thread::spawn(work);
    let handle = std::thread::spawn(work);
    let _ = handle.join();
}
