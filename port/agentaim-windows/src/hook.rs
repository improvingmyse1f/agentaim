use crate::event::{HookEvent, IPC_MAGIC, MAXIMUM_EVENT_BYTES, MAXIMUM_INPUT_BYTES};
use std::io::Read;
use std::time::{SystemTime, UNIX_EPOCH};
use windows_sys::Win32::Foundation::{LPARAM, WPARAM};
use windows_sys::Win32::System::DataExchange::COPYDATASTRUCT;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    FindWindowW, SendMessageTimeoutW, SMTO_ABORTIFHUNG, WM_COPYDATA,
};

const WINDOW_CLASS: &str = "AgentAimOverlayWindow";

pub fn run() {
    let provider = std::env::args()
        .skip_while(|argument| argument != "--provider")
        .nth(1)
        .filter(|provider| matches!(provider.as_str(), "codex" | "claude" | "workbuddy"));
    let Some(provider) = provider else { return };

    let mut input = Vec::new();
    if std::io::stdin()
        .take((MAXIMUM_INPUT_BYTES + 1) as u64)
        .read_to_end(&mut input)
        .is_err()
        || input.len() > MAXIMUM_INPUT_BYTES
    {
        return;
    }
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or(0.0);
    let Some(event) = HookEvent::from_hook_json(&input, &provider, now) else {
        return;
    };
    let Ok(payload) = serde_json::to_vec(&event) else {
        return;
    };
    if payload.len() > MAXIMUM_EVENT_BYTES {
        return;
    }

    let class_name = wide(WINDOW_CLASS);
    unsafe {
        let window = FindWindowW(class_name.as_ptr(), std::ptr::null());
        if window.is_null() {
            return;
        }
        let packet = COPYDATASTRUCT {
            dwData: IPC_MAGIC,
            cbData: payload.len() as u32,
            lpData: payload.as_ptr() as *mut _,
        };
        let mut result = 0usize;
        let _ = SendMessageTimeoutW(
            window,
            WM_COPYDATA,
            0 as WPARAM,
            &packet as *const COPYDATASTRUCT as LPARAM,
            SMTO_ABORTIFHUNG,
            1_000,
            &mut result,
        );
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}
