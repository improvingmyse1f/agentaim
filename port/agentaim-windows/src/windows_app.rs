#![allow(static_mut_refs)]

use agentaim_core::{
    AimAngles, AimPoint, DisplayMode, GameProfile, PerspectiveProjection, ScoreBoard, Sensitivity,
    SplitMix64, TargetField, TargetFieldParameters,
};
use agentaim_windows::event::{HookEvent, IPC_MAGIC, MAXIMUM_EVENT_BYTES};
use serde::{Deserialize, Serialize};
use std::ffi::c_void;
use std::mem::{size_of, zeroed};
use std::path::PathBuf;
use std::ptr::{null, null_mut};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows_sys::Win32::Foundation::{
    GetLastError, COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM,
};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, CreatePen, CreateSolidBrush, DeleteObject, DrawTextW, Ellipse, EndPaint, FillRect,
    GetStockObject, InvalidateRect, ScreenToClient, SelectObject, SetBkMode, SetTextColor,
    DT_CENTER, DT_LEFT, DT_RIGHT, DT_SINGLELINE, DT_VCENTER, HBRUSH, PAINTSTRUCT, PS_SOLID,
    TRANSPARENT, WHITE_BRUSH,
};
use windows_sys::Win32::System::DataExchange::COPYDATASTRUCT;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Controls::{BST_CHECKED, BST_UNCHECKED};
use windows_sys::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{SetFocus, VK_ESCAPE};
use windows_sys::Win32::UI::Input::{
    GetRawInputData, RegisterRawInputDevices, MOUSE_MOVE_ABSOLUTE, RAWINPUT, RAWINPUTDEVICE,
    RIDEV_INPUTSINK, RIDEV_NOLEGACY, RID_INPUT, RIM_TYPEMOUSE,
};
use windows_sys::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NIM_SETVERSION,
    NOTIFYICONDATAW, NOTIFYICON_VERSION_4,
};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

const WINDOW_CLASS: &str = "AgentAimOverlayWindow";
const SETTINGS_CLASS: &str = "AgentAimSettingsWindow";
const TRAY_MESSAGE: u32 = WM_APP + 1;
const TIMER_ID: usize = 1;
const TARGET_COUNT: usize = 3;
const AIM_INSET: f64 = 18.0;
const ID_START: usize = 100;
const ID_SETTINGS: usize = 101;
const ID_AUTOSTART: usize = 102;
const ID_QUIT: usize = 103;
const ID_PROFILE: i32 = 1001;
const ID_DISPLAY: i32 = 1002;
const ID_SENSITIVITY: i32 = 1003;
const ID_DPI: i32 = 1004;
const ID_AUTO_CHECK: i32 = 1005;
const ID_LOGIN_CHECK: i32 = 1006;
const ID_SAVE: usize = 1;
const ID_CANCEL: usize = 2;
const COLOR_KEY: COLORREF = 0x0003_0201;

// Win32 window procedures for this process are dispatched on the one UI thread. Keeping the
// state here avoids sharing HWND/GDI values across threads; every access remains inside that
// message loop. The explicit allow documents this single-threaded callback invariant.
static mut APP: Option<AppState> = None;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
struct Settings {
    profile: String,
    sensitivity: f64,
    dpi: Option<f64>,
    display_mode: String,
    auto_start_on_agent_work: bool,
    launch_at_login: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            profile: "valorant".to_owned(),
            sensitivity: 0.327,
            dpi: None,
            display_mode: "16:9".to_owned(),
            auto_start_on_agent_work: false,
            launch_at_login: false,
        }
    }
}

impl Settings {
    fn load() -> Self {
        std::fs::read(settings_path())
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .filter(Self::is_valid)
            .unwrap_or_default()
    }

    fn save(&self) -> Result<(), String> {
        let path = settings_path();
        let directory = path.parent().ok_or("invalid settings path")?;
        std::fs::create_dir_all(directory).map_err(|error| error.to_string())?;
        let data = serde_json::to_vec_pretty(self).map_err(|error| error.to_string())?;
        std::fs::write(path, data).map_err(|error| error.to_string())?;
        set_startup(self.launch_at_login)
    }

    fn is_valid(&self) -> bool {
        matches!(self.profile.as_str(), "valorant" | "cs2")
            && self.sensitivity.is_finite()
            && self.sensitivity > 0.0
            && self.dpi.is_none_or(|dpi| dpi.is_finite() && dpi > 0.0)
            && matches!(self.display_mode.as_str(), "16:9" | "4:3")
    }

    fn sensitivity(&self) -> Sensitivity {
        Sensitivity::new(
            if self.profile == "cs2" {
                GameProfile::CounterStrike2
            } else {
                GameProfile::Valorant
            },
            self.sensitivity,
            self.dpi,
        )
        .unwrap_or_else(Sensitivity::default_tactical)
    }

    fn display_mode(&self) -> DisplayMode {
        if self.display_mode == "4:3" {
            DisplayMode::Stretched4x3
        } else {
            DisplayMode::Widescreen16x9
        }
    }
}

enum Mode {
    Idle,
    Armed {
        shown_at: Instant,
        hover_started: Option<Instant>,
    },
    Playing,
}

struct AppState {
    hwnd: HWND,
    settings_hwnd: HWND,
    mode: Mode,
    settings: Settings,
    field: TargetField,
    rng: SplitMix64,
    board: ScoreBoard,
    aim_angles: AimAngles,
    crosshair: AimPoint,
    round_started: Instant,
    last_activity: Instant,
    last_elapsed_second: u64,
    last_paint_request: Instant,
    saved_cursor: POINT,
    cursor_hidden: bool,
    last_agent_status: String,
    tray_icon: NOTIFYICONDATAW,
}

impl AppState {
    fn new(hwnd: HWND, settings: Settings) -> Self {
        let now = Instant::now();
        Self {
            hwnd,
            settings_hwnd: null_mut(),
            mode: Mode::Idle,
            settings,
            field: TargetField::new(1.0, 1.0, TARGET_COUNT, TargetFieldParameters::default()),
            rng: SplitMix64::new(seed()),
            board: ScoreBoard::new(),
            aim_angles: AimAngles::default(),
            crosshair: AimPoint::ZERO,
            round_started: now,
            last_activity: now,
            last_elapsed_second: 0,
            last_paint_request: now,
            saved_cursor: POINT { x: 0, y: 0 },
            cursor_hidden: false,
            last_agent_status: "Agent idle".to_owned(),
            tray_icon: NOTIFYICONDATAW::default(),
        }
    }

    fn is_playing(&self) -> bool {
        matches!(self.mode, Mode::Playing)
    }

    unsafe fn arm(&mut self) {
        if self.is_playing() {
            return;
        }
        let width = 80;
        let height = 80;
        let screen_width = GetSystemMetrics(SM_CXSCREEN);
        let screen_height = GetSystemMetrics(SM_CYSCREEN);
        let x = (screen_width - width) / 2;
        let y = screen_height - height - 72;
        let style = (GetWindowLongPtrW(self.hwnd, GWL_EXSTYLE) as u32)
            | WS_EX_TRANSPARENT
            | WS_EX_NOACTIVATE
            | WS_EX_TOOLWINDOW
            | WS_EX_LAYERED
            | WS_EX_TOPMOST;
        SetWindowLongPtrW(self.hwnd, GWL_EXSTYLE, style as isize);
        SetWindowPos(
            self.hwnd,
            HWND_TOPMOST,
            x,
            y,
            width,
            height,
            SWP_NOACTIVATE | SWP_FRAMECHANGED,
        );
        self.mode = Mode::Armed {
            shown_at: Instant::now(),
            hover_started: None,
        };
        ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
        InvalidateRect(self.hwnd, null(), 1);
    }

    unsafe fn begin_round(&mut self) {
        if self.is_playing() {
            return;
        }
        let x = GetSystemMetrics(SM_XVIRTUALSCREEN);
        let y = GetSystemMetrics(SM_YVIRTUALSCREEN);
        let width = GetSystemMetrics(SM_CXVIRTUALSCREEN).max(1);
        let height = GetSystemMetrics(SM_CYVIRTUALSCREEN).max(1);
        self.field.screen_width = width as f64;
        self.field.screen_height = height as f64;
        self.field.reset();
        self.rng = SplitMix64::new(seed());
        for index in 0..TARGET_COUNT {
            self.field.spawn(index, &mut self.rng);
        }
        self.board.reset();
        self.aim_angles = AimAngles::default();
        self.crosshair = AimPoint::new(width as f64 / 2.0, height as f64 / 2.0);
        self.round_started = Instant::now();
        self.last_activity = self.round_started;
        self.last_elapsed_second = 0;
        self.last_paint_request = self.round_started;
        GetCursorPos(&mut self.saved_cursor);

        let style = ((GetWindowLongPtrW(self.hwnd, GWL_EXSTYLE) as u32)
            & !(WS_EX_TRANSPARENT | WS_EX_NOACTIVATE))
            | WS_EX_LAYERED
            | WS_EX_TOOLWINDOW
            | WS_EX_TOPMOST;
        SetWindowLongPtrW(self.hwnd, GWL_EXSTYLE, style as isize);
        SetWindowPos(
            self.hwnd,
            HWND_TOPMOST,
            x,
            y,
            width,
            height,
            SWP_SHOWWINDOW | SWP_FRAMECHANGED,
        );
        self.mode = Mode::Playing;
        SetForegroundWindow(self.hwnd);
        SetFocus(self.hwnd);

        let center = POINT {
            x: x + width / 2,
            y: y + height / 2,
        };
        SetCursorPos(center.x, center.y);
        let clip = RECT {
            left: center.x,
            top: center.y,
            right: center.x + 1,
            bottom: center.y + 1,
        };
        ClipCursor(&clip);
        while ShowCursor(0) >= 0 {}
        self.cursor_hidden = true;
        InvalidateRect(self.hwnd, null(), 1);
    }

    unsafe fn end_round(&mut self) {
        let was_playing = self.is_playing();
        if !was_playing && !matches!(self.mode, Mode::Armed { .. }) {
            return;
        }
        self.mode = Mode::Idle;
        if was_playing {
            ClipCursor(null());
            if self.cursor_hidden {
                while ShowCursor(1) < 0 {}
                self.cursor_hidden = false;
            }
            SetCursorPos(self.saved_cursor.x, self.saved_cursor.y);
        }
        ShowWindow(self.hwnd, SW_HIDE);
    }

    unsafe fn process_raw_input(&mut self, lparam: LPARAM) {
        if !self.is_playing() {
            return;
        }
        let mut size = 0u32;
        if GetRawInputData(
            lparam as _,
            RID_INPUT,
            null_mut(),
            &mut size,
            size_of::<windows_sys::Win32::UI::Input::RAWINPUTHEADER>() as u32,
        ) == u32::MAX
            || size == 0
        {
            return;
        }
        let mut buffer = vec![0u8; size as usize];
        if GetRawInputData(
            lparam as _,
            RID_INPUT,
            buffer.as_mut_ptr() as *mut c_void,
            &mut size,
            size_of::<windows_sys::Win32::UI::Input::RAWINPUTHEADER>() as u32,
        ) != size
        {
            return;
        }
        let raw = &*(buffer.as_ptr() as *const RAWINPUT);
        if raw.header.dwType != RIM_TYPEMOUSE {
            return;
        }
        let mouse = raw.data.mouse;
        self.last_activity = Instant::now();
        let is_relative = mouse.usFlags & MOUSE_MOVE_ABSOLUTE == 0;
        if is_relative && (mouse.lLastX != 0 || mouse.lLastY != 0) {
            let sensitivity = self.settings.sensitivity();
            let delta = sensitivity.angle_delta(mouse.lLastX as f64, mouse.lLastY as f64);
            self.aim_angles.yaw_degrees += delta.yaw_degrees;
            self.aim_angles.pitch_degrees += delta.pitch_degrees;
            let fov = sensitivity
                .profile
                .horizontal_field_of_view(self.settings.display_mode());
            if let Some(projection) = PerspectiveProjection::new(
                fov,
                self.field.screen_width,
                self.field.screen_height,
                AIM_INSET,
            ) {
                self.aim_angles = projection.clamped(self.aim_angles);
                let point = projection.point(self.aim_angles);
                self.crosshair = AimPoint::new(point.x, point.y);
            }
        }
        let buttons = mouse.Anonymous.Anonymous.usButtonFlags as u32;
        if buttons & RI_MOUSE_RIGHT_BUTTON_DOWN != 0 {
            self.end_round();
            return;
        }
        if buttons & RI_MOUSE_LEFT_BUTTON_DOWN != 0 {
            self.fire();
        }
        if self.last_paint_request.elapsed() >= Duration::from_millis(8)
            || buttons & RI_MOUSE_LEFT_BUTTON_DOWN != 0
        {
            self.last_paint_request = Instant::now();
            InvalidateRect(self.hwnd, null(), 0);
        }
    }

    fn fire(&mut self) {
        self.last_activity = Instant::now();
        let hit = self.field.hit_test(self.crosshair);
        self.board.register_shot(hit.is_some());
        if let Some(index) = hit {
            self.field.spawn(index, &mut self.rng);
        }
    }

    unsafe fn tick(&mut self) {
        match &mut self.mode {
            Mode::Idle => {}
            Mode::Playing => {
                if self.last_activity.elapsed() >= Duration::from_secs(90) {
                    self.end_round();
                } else {
                    let elapsed = self.round_started.elapsed().as_secs();
                    if elapsed != self.last_elapsed_second {
                        self.last_elapsed_second = elapsed;
                        InvalidateRect(self.hwnd, null(), 0);
                    }
                }
            }
            Mode::Armed {
                shown_at,
                hover_started,
            } => {
                if shown_at.elapsed() >= Duration::from_secs(10) {
                    self.end_round();
                    return;
                }
                let mut point = POINT { x: 0, y: 0 };
                GetCursorPos(&mut point);
                ScreenToClient(self.hwnd, &mut point);
                let dx = point.x - 40;
                let dy = point.y - 40;
                let inside = dx * dx + dy * dy <= 28 * 28;
                if inside {
                    let started = hover_started.get_or_insert_with(Instant::now);
                    if started.elapsed() >= Duration::from_secs(2) {
                        self.begin_round();
                        return;
                    }
                } else {
                    *hover_started = None;
                }
                InvalidateRect(self.hwnd, null(), 0);
            }
        }
    }

    unsafe fn receive_event(&mut self, packet: &COPYDATASTRUCT) -> bool {
        if packet.dwData != IPC_MAGIC
            || packet.cbData == 0
            || packet.cbData as usize > MAXIMUM_EVENT_BYTES
            || packet.lpData.is_null()
        {
            return false;
        }
        let bytes = std::slice::from_raw_parts(packet.lpData as *const u8, packet.cbData as usize);
        let Ok(event) = serde_json::from_slice::<HookEvent>(bytes) else {
            return false;
        };
        if event.requests_attention() {
            self.last_agent_status = "Agent needs you".to_owned();
            self.end_round();
        } else if event.starts_new_work() {
            self.last_agent_status = format!("{} working", event.provider);
            if self.settings.auto_start_on_agent_work {
                self.arm();
            }
        } else {
            self.last_agent_status = format!("{} working", event.provider);
        }
        true
    }
}

pub fn run() -> Result<(), String> {
    unsafe {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let instance = GetModuleHandleW(null());
        if instance.is_null() {
            return Err("Cannot resolve module handle".to_owned());
        }
        register_class(instance, WINDOW_CLASS, Some(overlay_proc))?;
        register_class(instance, SETTINGS_CLASS, Some(settings_proc))?;
        let class_name = wide(WINDOW_CLASS);
        let title = wide("AgentAim");
        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
            class_name.as_ptr(),
            title.as_ptr(),
            WS_POPUP,
            0,
            0,
            80,
            80,
            null_mut(),
            null_mut(),
            instance,
            null_mut(),
        );
        if hwnd.is_null() {
            return Err(format!("Cannot create overlay window: {}", GetLastError()));
        }
        SetLayeredWindowAttributes(hwnd, COLOR_KEY, 0, LWA_COLORKEY);
        APP = Some(AppState::new(hwnd, Settings::load()));
        register_raw_input(hwnd)?;
        add_tray_icon()?;
        SetTimer(hwnd, TIMER_ID, 50, None);
        if let Some(app) = APP.as_mut() {
            app.arm();
        }

        let mut message: MSG = zeroed();
        while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        Ok(())
    }
}

pub fn show_fatal_error(error: &str) {
    unsafe {
        let title = wide("AgentAim failed to start");
        let message = wide(error);
        MessageBoxW(
            null_mut(),
            message.as_ptr(),
            title.as_ptr(),
            MB_ICONERROR | MB_OK,
        );
    }
}

unsafe extern "system" fn overlay_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_PAINT => {
            paint(hwnd);
            0
        }
        WM_ERASEBKGND => 1,
        WM_INPUT => {
            if let Some(app) = APP.as_mut() {
                app.process_raw_input(lparam);
            }
            0
        }
        WM_KEYDOWN => {
            if matches!(wparam as u32, value if value == VK_ESCAPE as u32 || value == 0x51) {
                if let Some(app) = APP.as_mut() {
                    app.end_round();
                }
            }
            0
        }
        WM_TIMER if wparam == TIMER_ID => {
            if let Some(app) = APP.as_mut() {
                app.tick();
            }
            0
        }
        WM_COPYDATA => {
            if lparam == 0 {
                return 0;
            }
            let packet = &*(lparam as *const COPYDATASTRUCT);
            APP.as_mut().is_some_and(|app| app.receive_event(packet)) as LRESULT
        }
        TRAY_MESSAGE => {
            handle_tray(hwnd, lparam as u32);
            0
        }
        WM_COMMAND => {
            handle_command(wparam & 0xffff);
            0
        }
        WM_DESTROY => {
            remove_tray_icon();
            if let Some(app) = APP.as_mut() {
                app.end_round();
            }
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

unsafe fn paint(hwnd: HWND) {
    let mut paint: PAINTSTRUCT = zeroed();
    let dc = BeginPaint(hwnd, &mut paint);
    let mut client: RECT = zeroed();
    GetClientRect(hwnd, &mut client);
    let background = CreateSolidBrush(COLOR_KEY);
    FillRect(dc, &client, background);
    DeleteObject(background);

    let Some(app) = APP.as_ref() else {
        EndPaint(hwnd, &paint);
        return;
    };
    match &app.mode {
        Mode::Idle => {}
        Mode::Armed { hover_started, .. } => {
            let base_pen = CreatePen(PS_SOLID, 4, rgb(130, 140, 150));
            let old_pen = SelectObject(dc, base_pen);
            let hollow = GetStockObject(5);
            let old_brush = SelectObject(dc, hollow);
            Ellipse(dc, 12, 12, 68, 68);
            SelectObject(dc, old_brush);
            SelectObject(dc, old_pen);
            DeleteObject(base_pen);
            if let Some(started) = hover_started {
                let progress = (started.elapsed().as_secs_f64() / 2.0).clamp(0.0, 1.0);
                let pen = CreatePen(PS_SOLID, 5, rgb(48, 214, 255));
                let old = SelectObject(dc, pen);
                let inset = (18.0 * (1.0 - progress)) as i32;
                Ellipse(dc, 12 + inset, 12 + inset, 68 - inset, 68 - inset);
                SelectObject(dc, old);
                DeleteObject(pen);
            }
        }
        Mode::Playing => paint_game(dc, &client, app),
    }
    EndPaint(hwnd, &paint);
}

unsafe fn paint_game(dc: windows_sys::Win32::Graphics::Gdi::HDC, client: &RECT, app: &AppState) {
    for target in app.field.snapshot() {
        let radius = target.diameter / 2.0;
        let brush = CreateSolidBrush(rgb(31, 210, 235));
        let pen = CreatePen(PS_SOLID, 3, rgb(235, 255, 255));
        let old_brush = SelectObject(dc, brush);
        let old_pen = SelectObject(dc, pen);
        Ellipse(
            dc,
            (target.center.x - radius) as i32,
            (target.center.y - radius) as i32,
            (target.center.x + radius) as i32,
            (target.center.y + radius) as i32,
        );
        SelectObject(dc, old_pen);
        SelectObject(dc, old_brush);
        DeleteObject(pen);
        DeleteObject(brush);
    }

    let shadow = CreateSolidBrush(rgb(25, 25, 25));
    let old = SelectObject(dc, shadow);
    Ellipse(
        dc,
        app.crosshair.x as i32 - 5,
        app.crosshair.y as i32 - 5,
        app.crosshair.x as i32 + 5,
        app.crosshair.y as i32 + 5,
    );
    SelectObject(dc, old);
    DeleteObject(shadow);
    let dot = CreateSolidBrush(rgb(255, 255, 255));
    let old = SelectObject(dc, dot);
    Ellipse(
        dc,
        app.crosshair.x as i32 - 3,
        app.crosshair.y as i32 - 3,
        app.crosshair.x as i32 + 3,
        app.crosshair.y as i32 + 3,
    );
    SelectObject(dc, old);
    DeleteObject(dot);

    SetBkMode(dc, TRANSPARENT as i32);
    SetTextColor(dc, rgb(235, 245, 250));
    draw_text(
        dc,
        &format!("Score  {}", app.board.score()),
        32,
        28,
        260,
        30,
        DT_LEFT,
    );
    draw_text(
        dc,
        &format!("Streak  {}", app.board.streak()),
        client.right - 280,
        28,
        240,
        30,
        DT_RIGHT,
    );
    let elapsed = app.round_started.elapsed().as_secs();
    draw_text(
        dc,
        &format!("{}:{:02}", elapsed / 60, elapsed % 60),
        32,
        client.bottom - 48,
        140,
        28,
        DT_LEFT,
    );
    draw_text(
        dc,
        &app.last_agent_status,
        client.right / 2 - 180,
        client.bottom - 48,
        360,
        28,
        DT_CENTER,
    );
    draw_text(
        dc,
        "Esc / Q / right click to exit",
        client.right - 360,
        client.bottom - 48,
        328,
        28,
        DT_RIGHT,
    );
}

unsafe fn draw_text(
    dc: windows_sys::Win32::Graphics::Gdi::HDC,
    text: &str,
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    format: u32,
) {
    let text = wide(text);
    let mut rect = RECT {
        left,
        top,
        right: left + width,
        bottom: top + height,
    };
    DrawTextW(
        dc,
        text.as_ptr(),
        -1,
        &mut rect,
        format | DT_SINGLELINE | DT_VCENTER,
    );
}

unsafe fn add_tray_icon() -> Result<(), String> {
    let Some(app) = APP.as_mut() else {
        return Err("app state missing".to_owned());
    };
    let mut icon = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: app.hwnd,
        uID: 1,
        uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
        uCallbackMessage: TRAY_MESSAGE,
        hIcon: LoadIconW(null_mut(), IDI_APPLICATION),
        ..Default::default()
    };
    copy_wide(&mut icon.szTip, "AgentAim — right click for menu");
    if Shell_NotifyIconW(NIM_ADD, &icon) == 0 {
        return Err("Cannot create notification area icon".to_owned());
    }
    icon.Anonymous.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &icon);
    app.tray_icon = icon;
    Ok(())
}

unsafe fn remove_tray_icon() {
    if let Some(app) = APP.as_ref() {
        Shell_NotifyIconW(NIM_DELETE, &app.tray_icon);
    }
}

unsafe fn handle_tray(hwnd: HWND, message: u32) {
    let message = message & 0xffff;
    if matches!(message, WM_RBUTTONUP | WM_CONTEXTMENU) {
        show_tray_menu(hwnd);
    } else if message == WM_LBUTTONDBLCLK {
        if let Some(app) = APP.as_mut() {
            app.begin_round();
        }
    }
}

unsafe fn show_tray_menu(hwnd: HWND) {
    let menu = CreatePopupMenu();
    if menu.is_null() {
        return;
    }
    append_menu(menu, MF_STRING, ID_START, "Start training");
    append_menu(menu, MF_STRING, ID_SETTINGS, "Settings…");
    append_menu(menu, MF_SEPARATOR, 0, "");
    let checked = APP
        .as_ref()
        .is_some_and(|app| app.settings.auto_start_on_agent_work);
    append_menu(
        menu,
        MF_STRING | if checked { MF_CHECKED } else { 0 },
        ID_AUTOSTART,
        "Start when an agent works",
    );
    append_menu(menu, MF_SEPARATOR, 0, "");
    append_menu(menu, MF_STRING, ID_QUIT, "Quit AgentAim");
    let mut point = POINT { x: 0, y: 0 };
    GetCursorPos(&mut point);
    SetForegroundWindow(hwnd);
    let command = TrackPopupMenu(
        menu,
        TPM_RETURNCMD | TPM_RIGHTBUTTON,
        point.x,
        point.y,
        0,
        hwnd,
        null(),
    );
    DestroyMenu(menu);
    if command != 0 {
        handle_command(command as usize);
    }
}

unsafe fn handle_command(command: usize) {
    match command {
        ID_START => {
            if let Some(app) = APP.as_mut() {
                app.begin_round();
            }
        }
        ID_SETTINGS => show_settings(),
        ID_AUTOSTART => {
            if let Some(app) = APP.as_mut() {
                app.settings.auto_start_on_agent_work = !app.settings.auto_start_on_agent_work;
                let _ = app.settings.save();
            }
        }
        ID_QUIT => {
            if let Some(app) = APP.as_ref() {
                DestroyWindow(app.hwnd);
            }
        }
        _ => {}
    }
}

unsafe fn show_settings() {
    let Some(app) = APP.as_mut() else { return };
    if !app.settings_hwnd.is_null() {
        SetForegroundWindow(app.settings_hwnd);
        return;
    }
    let instance = GetModuleHandleW(null());
    let class = wide(SETTINGS_CLASS);
    let title = wide("AgentAim Settings");
    let hwnd = CreateWindowExW(
        WS_EX_DLGMODALFRAME,
        class.as_ptr(),
        title.as_ptr(),
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        430,
        350,
        app.hwnd,
        null_mut(),
        instance,
        null_mut(),
    );
    if !hwnd.is_null() {
        app.settings_hwnd = hwnd;
        ShowWindow(hwnd, SW_SHOW);
        SetForegroundWindow(hwnd);
    }
}

unsafe extern "system" fn settings_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_CREATE => {
            create_settings_controls(hwnd);
            populate_settings_controls(hwnd);
            0
        }
        WM_COMMAND => {
            let control_id = wparam & 0xffff;
            let notification = ((wparam >> 16) & 0xffff) as u32;
            if control_id == ID_PROFILE as usize && notification == CBN_SELCHANGE {
                convert_profile_in_settings(hwnd);
                return 0;
            }
            match control_id {
                ID_SAVE => save_settings_controls(hwnd),
                ID_CANCEL => {
                    DestroyWindow(hwnd);
                }
                _ => {}
            }
            0
        }
        WM_CLOSE => {
            DestroyWindow(hwnd);
            0
        }
        WM_DESTROY => {
            if let Some(app) = APP.as_mut() {
                app.settings_hwnd = null_mut();
            }
            0
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

unsafe fn convert_profile_in_settings(hwnd: HWND) {
    let Some(app) = APP.as_ref() else { return };
    let Ok(value) = get_control_text(hwnd, ID_SENSITIVITY).parse::<f64>() else {
        return;
    };
    let selected = SendDlgItemMessageW(hwnd, ID_PROFILE, CB_GETCURSEL, 0, 0);
    let new_profile = if selected == 1 {
        GameProfile::CounterStrike2
    } else {
        GameProfile::Valorant
    };
    let old_profile = if GetWindowLongPtrW(hwnd, GWLP_USERDATA) == 1 {
        GameProfile::CounterStrike2
    } else {
        GameProfile::Valorant
    };
    if new_profile == old_profile {
        return;
    }
    let current = Sensitivity::new(old_profile, value, app.settings.dpi)
        .unwrap_or_else(|| app.settings.sensitivity());
    let converted = current.converted(new_profile);
    set_control_text(hwnd, ID_SENSITIVITY, &format!("{:.9}", converted.value));
    SetWindowLongPtrW(
        hwnd,
        GWLP_USERDATA,
        if new_profile == GameProfile::CounterStrike2 {
            1
        } else {
            0
        },
    );
}

unsafe fn create_settings_controls(hwnd: HWND) {
    label(hwnd, "Game", 24, 26, 120, 24);
    control(
        hwnd,
        "COMBOBOX",
        "",
        CBS_DROPDOWNLIST as u32 | WS_CHILD | WS_VISIBLE | WS_TABSTOP,
        155,
        22,
        235,
        160,
        ID_PROFILE,
    );
    label(hwnd, "Display", 24, 70, 120, 24);
    control(
        hwnd,
        "COMBOBOX",
        "",
        CBS_DROPDOWNLIST as u32 | WS_CHILD | WS_VISIBLE | WS_TABSTOP,
        155,
        66,
        235,
        160,
        ID_DISPLAY,
    );
    label(hwnd, "In-game sensitivity", 24, 114, 130, 24);
    control(
        hwnd,
        "EDIT",
        "",
        WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
        155,
        110,
        235,
        26,
        ID_SENSITIVITY,
    );
    label(hwnd, "Mouse DPI (optional)", 24, 158, 130, 24);
    control(
        hwnd,
        "EDIT",
        "",
        WS_CHILD | WS_VISIBLE | WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
        155,
        154,
        235,
        26,
        ID_DPI,
    );
    control(
        hwnd,
        "BUTTON",
        "Start when an agent works",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX as u32,
        24,
        198,
        300,
        28,
        ID_AUTO_CHECK,
    );
    control(
        hwnd,
        "BUTTON",
        "Launch at sign-in",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX as u32,
        24,
        232,
        300,
        28,
        ID_LOGIN_CHECK,
    );
    control(
        hwnd,
        "BUTTON",
        "Save",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON as u32,
        210,
        280,
        85,
        30,
        ID_SAVE as i32,
    );
    control(
        hwnd,
        "BUTTON",
        "Cancel",
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON as u32,
        305,
        280,
        85,
        30,
        ID_CANCEL as i32,
    );
}

unsafe fn populate_settings_controls(hwnd: HWND) {
    let Some(app) = APP.as_ref() else { return };
    combo_add(hwnd, ID_PROFILE, "VALORANT");
    combo_add(hwnd, ID_PROFILE, "Counter-Strike 2");
    SendDlgItemMessageW(
        hwnd,
        ID_PROFILE,
        CB_SETCURSEL,
        (app.settings.profile == "cs2") as usize,
        0,
    );
    SetWindowLongPtrW(
        hwnd,
        GWLP_USERDATA,
        if app.settings.profile == "cs2" { 1 } else { 0 },
    );
    combo_add(hwnd, ID_DISPLAY, "16:9");
    combo_add(hwnd, ID_DISPLAY, "4:3 stretched");
    SendDlgItemMessageW(
        hwnd,
        ID_DISPLAY,
        CB_SETCURSEL,
        (app.settings.display_mode == "4:3") as usize,
        0,
    );
    set_control_text(
        hwnd,
        ID_SENSITIVITY,
        &format!("{:.9}", app.settings.sensitivity),
    );
    set_control_text(
        hwnd,
        ID_DPI,
        &app.settings
            .dpi
            .map(|value| format!("{value:.0}"))
            .unwrap_or_default(),
    );
    SendDlgItemMessageW(
        hwnd,
        ID_AUTO_CHECK,
        BM_SETCHECK,
        if app.settings.auto_start_on_agent_work {
            BST_CHECKED as usize
        } else {
            BST_UNCHECKED as usize
        },
        0,
    );
    SendDlgItemMessageW(
        hwnd,
        ID_LOGIN_CHECK,
        BM_SETCHECK,
        if app.settings.launch_at_login {
            BST_CHECKED as usize
        } else {
            BST_UNCHECKED as usize
        },
        0,
    );
}

unsafe fn save_settings_controls(hwnd: HWND) {
    let sensitivity = get_control_text(hwnd, ID_SENSITIVITY).parse::<f64>().ok();
    let dpi_text = get_control_text(hwnd, ID_DPI);
    let dpi = if dpi_text.trim().is_empty() {
        Some(None)
    } else {
        dpi_text.parse::<f64>().ok().map(Some)
    };
    let Some(sensitivity) = sensitivity else {
        settings_error(hwnd, "Sensitivity must be a positive number.");
        return;
    };
    let Some(dpi) = dpi else {
        settings_error(hwnd, "DPI must be empty or a positive number.");
        return;
    };
    if sensitivity <= 0.0
        || !sensitivity.is_finite()
        || dpi.is_some_and(|value| value <= 0.0 || !value.is_finite())
    {
        settings_error(hwnd, "Sensitivity and DPI must be positive finite numbers.");
        return;
    }
    let Some(app) = APP.as_mut() else { return };
    app.settings.profile = if SendDlgItemMessageW(hwnd, ID_PROFILE, CB_GETCURSEL, 0, 0) == 1 {
        "cs2"
    } else {
        "valorant"
    }
    .to_owned();
    app.settings.display_mode = if SendDlgItemMessageW(hwnd, ID_DISPLAY, CB_GETCURSEL, 0, 0) == 1 {
        "4:3"
    } else {
        "16:9"
    }
    .to_owned();
    app.settings.sensitivity = sensitivity;
    app.settings.dpi = dpi;
    app.settings.auto_start_on_agent_work =
        SendDlgItemMessageW(hwnd, ID_AUTO_CHECK, BM_GETCHECK, 0, 0) == BST_CHECKED as isize;
    app.settings.launch_at_login =
        SendDlgItemMessageW(hwnd, ID_LOGIN_CHECK, BM_GETCHECK, 0, 0) == BST_CHECKED as isize;
    match app.settings.save() {
        Ok(()) => {
            DestroyWindow(hwnd);
        }
        Err(error) => settings_error(hwnd, &format!("Could not save settings: {error}")),
    }
}

unsafe fn label(hwnd: HWND, text: &str, x: i32, y: i32, width: i32, height: i32) {
    control(
        hwnd,
        "STATIC",
        text,
        WS_CHILD | WS_VISIBLE,
        x,
        y,
        width,
        height,
        0,
    );
}

#[allow(clippy::too_many_arguments)]
unsafe fn control(
    hwnd: HWND,
    class: &str,
    text: &str,
    style: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    id: i32,
) -> HWND {
    let class = wide(class);
    let text = wide(text);
    CreateWindowExW(
        0,
        class.as_ptr(),
        text.as_ptr(),
        style,
        x,
        y,
        width,
        height,
        hwnd,
        id as usize as _,
        GetModuleHandleW(null()),
        null_mut(),
    )
}

unsafe fn combo_add(hwnd: HWND, id: i32, value: &str) {
    let value = wide(value);
    SendDlgItemMessageW(hwnd, id, CB_ADDSTRING, 0, value.as_ptr() as isize);
}

unsafe fn set_control_text(hwnd: HWND, id: i32, value: &str) {
    let value = wide(value);
    SetDlgItemTextW(hwnd, id, value.as_ptr());
}

unsafe fn get_control_text(hwnd: HWND, id: i32) -> String {
    let control = GetDlgItem(hwnd, id);
    let length = GetWindowTextLengthW(control).max(0) as usize;
    let mut buffer = vec![0u16; length + 1];
    GetWindowTextW(control, buffer.as_mut_ptr(), buffer.len() as i32);
    String::from_utf16_lossy(&buffer[..length])
}

unsafe fn settings_error(hwnd: HWND, message: &str) {
    let message = wide(message);
    let title = wide("AgentAim Settings");
    MessageBoxW(
        hwnd,
        message.as_ptr(),
        title.as_ptr(),
        MB_OK | MB_ICONWARNING,
    );
}

unsafe fn register_class(
    instance: *mut c_void,
    name: &str,
    procedure: WNDPROC,
) -> Result<(), String> {
    let class_name = wide(name);
    let class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: procedure,
        hInstance: instance,
        hCursor: LoadCursorW(null_mut(), IDC_ARROW),
        hbrBackground: GetStockObject(WHITE_BRUSH) as HBRUSH,
        lpszClassName: class_name.as_ptr(),
        ..Default::default()
    };
    if RegisterClassExW(&class) == 0 {
        return Err(format!("Cannot register {name}: {}", GetLastError()));
    }
    Ok(())
}

unsafe fn register_raw_input(hwnd: HWND) -> Result<(), String> {
    let device = RAWINPUTDEVICE {
        usUsagePage: 0x01,
        usUsage: 0x02,
        dwFlags: RIDEV_INPUTSINK | RIDEV_NOLEGACY,
        hwndTarget: hwnd,
    };
    if RegisterRawInputDevices(&device, 1, size_of::<RAWINPUTDEVICE>() as u32) == 0 {
        return Err(format!("Cannot register Raw Input: {}", GetLastError()));
    }
    Ok(())
}

unsafe fn append_menu(menu: HMENU, flags: u32, id: usize, title: &str) {
    let title = wide(title);
    AppendMenuW(menu, flags, id, title.as_ptr());
}

fn settings_path() -> PathBuf {
    std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("AgentAim")
        .join("settings.json")
}

fn startup_path() -> Result<PathBuf, String> {
    let app_data = std::env::var_os("APPDATA").ok_or("APPDATA is unavailable")?;
    Ok(PathBuf::from(app_data)
        .join("Microsoft")
        .join("Windows")
        .join("Start Menu")
        .join("Programs")
        .join("Startup")
        .join("AgentAim.cmd"))
}

fn set_startup(enabled: bool) -> Result<(), String> {
    let path = startup_path()?;
    if enabled {
        let executable = std::env::current_exe().map_err(|error| error.to_string())?;
        std::fs::write(
            &path,
            format!("@start \"\" \"{}\"\r\n", executable.display()),
        )
        .map_err(|error| error.to_string())
    } else if path.exists() {
        std::fs::remove_file(path).map_err(|error| error.to_string())
    } else {
        Ok(())
    }
}

fn seed() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0x4141_494D)
}

fn rgb(red: u8, green: u8, blue: u8) -> COLORREF {
    red as u32 | ((green as u32) << 8) | ((blue as u32) << 16)
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn copy_wide<const N: usize>(destination: &mut [u16; N], value: &str) {
    let value = wide(value);
    let count = value.len().min(N);
    destination[..count].copy_from_slice(&value[..count]);
}
