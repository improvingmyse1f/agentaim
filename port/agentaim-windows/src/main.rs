#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod windows_app;

#[cfg(windows)]
fn main() {
    if let Err(error) = windows_app::run() {
        windows_app::show_fatal_error(&error);
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("AgentAim Windows shell can only run on Windows 10/11.");
}
