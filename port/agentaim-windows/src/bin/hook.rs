#[cfg(windows)]
fn main() {
    agentaim_windows::hook::run();
}

#[cfg(not(windows))]
fn main() {}
