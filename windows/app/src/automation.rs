//! Driving the Riot Client and League client on Windows.
//!
//! On macOS these features used NSWorkspace, Accessibility and CGEvent. The
//! Windows equivalents are: process control through the shell (`tasklist` /
//! `taskkill` and launching `RiotClientServices.exe`), and input injection with
//! `SendInput` for the login autofill. Locating the login fields precisely wants
//! UIAutomation and a live client to tune against; the autofill here focuses the
//! client window and types into it, which is the mechanism the Mac app used too.

use std::path::PathBuf;
use std::process::Command;

#[derive(Debug, thiserror::Error)]
pub enum AutomationError {
    #[error("the Riot Client is not installed where expected")]
    NotInstalled,
    #[error("could not start a process: {0}")]
    Spawn(String),
    #[error("input injection is only available on Windows")]
    Unsupported,
}

const LEAGUE_PROCS: &[&str] = &["LeagueClientUx.exe", "LeagueClient.exe"];

/// Finds `RiotClientServices.exe` via the installs manifest, then the usual paths.
pub fn riot_client_path() -> Option<PathBuf> {
    // The installs manifest records the live path; prefer it.
    let manifest = PathBuf::from(r"C:\ProgramData\Riot Games\RiotClientInstalls.json");
    if let Ok(text) = std::fs::read_to_string(&manifest) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
            for key in ["rc_live", "rc_default", "rc_beta"] {
                if let Some(p) = v.get(key).and_then(|x| x.as_str()) {
                    let path = PathBuf::from(p);
                    if path.exists() {
                        return Some(path);
                    }
                }
            }
        }
    }
    for p in [
        r"C:\Riot Games\Riot Client\RiotClientServices.exe",
        r"C:\Program Files\Riot Games\Riot Client\RiotClientServices.exe",
        r"C:\Program Files (x86)\Riot Games\Riot Client\RiotClientServices.exe",
    ] {
        let path = PathBuf::from(p);
        if path.exists() {
            return Some(path);
        }
    }
    None
}

pub fn is_installed() -> bool {
    riot_client_path().is_some()
}

/// Opens the Riot Client to its login screen.
pub fn open_launcher() -> Result<(), AutomationError> {
    let exe = riot_client_path().ok_or(AutomationError::NotInstalled)?;
    spawn(&exe, &[])
}

/// Starts League for the signed-in account via the documented launch arguments.
pub fn launch_league() -> Result<(), AutomationError> {
    let exe = riot_client_path().ok_or(AutomationError::NotInstalled)?;
    spawn(
        &exe,
        &["--launch-product=league_of_legends", "--launch-patchline=live"],
    )
}

/// Force-closes only the League client, never the Riot Client.
pub fn kill_league() -> Result<(), AutomationError> {
    for proc in LEAGUE_PROCS {
        let _ = Command::new("taskkill").args(["/IM", proc, "/F", "/T"]).output();
    }
    Ok(())
}

/// Whether a League client process is currently running.
pub fn is_league_running() -> bool {
    process_running(LEAGUE_PROCS)
}

/// Whether the Riot Client itself is running.
pub fn is_riot_client_running() -> bool {
    process_running(&["RiotClientServices.exe", "RiotClientUx.exe"])
}

fn process_running(names: &[&str]) -> bool {
    let out = match Command::new("tasklist").arg("/FO").arg("CSV").arg("/NH").output() {
        Ok(o) => o,
        Err(_) => return false,
    };
    let text = String::from_utf8_lossy(&out.stdout).to_lowercase();
    names.iter().any(|n| text.contains(&n.to_lowercase()))
}

fn spawn(exe: &PathBuf, args: &[&str]) -> Result<(), AutomationError> {
    Command::new(exe)
        .args(args)
        .spawn()
        .map(|_| ())
        .map_err(|e| AutomationError::Spawn(e.to_string()))
}

// ---- Input injection (SendInput) ------------------------------------------

/// Types the username, Tab, then the password into the focused Riot Client login
/// form. The caller focuses the client window first (see `focus_riot_client`).
#[cfg(windows)]
pub fn autofill_login(username: &str, password: &str) -> Result<(), AutomationError> {
    focus_riot_client();
    std::thread::sleep(std::time::Duration::from_millis(400));
    type_text(username);
    tap_key(windows::Win32::UI::Input::KeyboardAndMouse::VK_TAB);
    type_text(password);
    Ok(())
}

#[cfg(not(windows))]
pub fn autofill_login(_username: &str, _password: &str) -> Result<(), AutomationError> {
    Err(AutomationError::Unsupported)
}

/// Brings the Riot Client window to the foreground so the typing lands in it.
#[cfg(windows)]
fn focus_riot_client() {
    use windows::core::w;
    use windows::Win32::UI::WindowsAndMessaging::{FindWindowW, SetForegroundWindow};
    unsafe {
        // The client's main window class/title; fall back to the title text.
        if let Ok(hwnd) = FindWindowW(None, w!("Riot Client")) {
            if !hwnd.is_invalid() {
                let _ = SetForegroundWindow(hwnd);
            }
        }
    }
}

#[cfg(windows)]
fn type_text(text: &str) {
    for ch in text.encode_utf16() {
        send_unicode(ch);
    }
}

#[cfg(windows)]
fn send_unicode(unit: u16) {
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE,
        VIRTUAL_KEY,
    };
    unsafe {
        let mut down = INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: VIRTUAL_KEY(0),
                    wScan: unit,
                    dwFlags: KEYEVENTF_UNICODE,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };
        let mut up = down;
        up.Anonymous.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        let size = std::mem::size_of::<INPUT>() as i32;
        SendInput(&[down, up], size);
        let _ = &mut down;
    }
}

#[cfg(windows)]
fn tap_key(vk: windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY) {
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, KEYBD_EVENT_FLAGS,
    };
    unsafe {
        let mut down = INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: vk,
                    wScan: 0,
                    dwFlags: KEYBD_EVENT_FLAGS(0),
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };
        let mut up = down;
        up.Anonymous.ki.dwFlags = KEYEVENTF_KEYUP;
        let size = std::mem::size_of::<INPUT>() as i32;
        SendInput(&[down, up], size);
        let _ = &mut down;
    }
}
