//! The command surface the UI calls through `window.__TAURI__.core.invoke`.

use chrono::Utc;
use leaguevault_core::lcu::apply_snapshot;
use leaguevault_core::models::Account;
use leaguevault_core::view::{build_payload, SitePayload};
use serde::Serialize;
use tauri::State;
use uuid::Uuid;

use crate::automation;
use crate::lcu::Client as LcuClient;
use crate::state::AppState;

fn host_name() -> String {
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_else(|_| "this PC".into())
}

/// The whole vault, in the shape the dashboard renderer reads. Logins are
/// included because this is the owner's own machine, never a published page.
#[tauri::command]
pub fn list_accounts(state: State<AppState>) -> SitePayload {
    state.with_accounts(|accounts| {
        build_payload(accounts, "League Vault", &host_name(), true, Utc::now())
    })
}

/// The full account record, for the editor.
#[tauri::command]
pub fn get_account(state: State<AppState>, id: String) -> Option<Account> {
    let id = Uuid::parse_str(&id).ok()?;
    state.with_accounts(|accounts| accounts.iter().find(|a| a.id == id).cloned())
}

/// Inserts or updates an account. Returns its id.
#[tauri::command]
pub fn save_account(state: State<AppState>, mut account: Account) -> Result<String, String> {
    account.normalize();
    let id = account.id.to_string();
    state.mutate(|accounts| {
        match accounts.iter_mut().find(|a| a.id == account.id) {
            Some(existing) => {
                // Preserve the sealed password — the editor never carries it.
                let keep = existing.encrypted_password.clone();
                *existing = account;
                existing.encrypted_password = keep;
            }
            None => accounts.push(account),
        }
    })?;
    Ok(id)
}

#[tauri::command]
pub fn delete_account(state: State<AppState>, id: String) -> Result<(), String> {
    let id = Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    state.mutate(|accounts| accounts.retain(|a| a.id != id))
}

/// Seals a password with the vault key and stores it. An empty string clears it.
#[tauri::command]
pub fn set_password(state: State<AppState>, id: String, password: String) -> Result<(), String> {
    let id = Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    let sealed = if password.is_empty() {
        None
    } else {
        Some(state.vault().seal(&password).ok_or("could not encrypt the password")?)
    };
    state.mutate(|accounts| {
        if let Some(a) = accounts.iter_mut().find(|a| a.id == id) {
            a.encrypted_password = sealed;
        }
    })
}

#[tauri::command]
pub fn has_password(state: State<AppState>, id: String) -> bool {
    let id = match Uuid::parse_str(&id) {
        Ok(i) => i,
        Err(_) => return false,
    };
    state.with_accounts(|accounts| {
        accounts
            .iter()
            .find(|a| a.id == id)
            .map(|a| a.encrypted_password.is_some())
            .unwrap_or(false)
    })
}

/// Reads one account's password back (for copy / autofill). Owner's machine only.
fn open_password(state: &AppState, id: Uuid) -> Option<String> {
    let sealed = state.with_accounts(|accounts| {
        accounts.iter().find(|a| a.id == id).and_then(|a| a.encrypted_password.clone())
    })?;
    state.vault().open(&sealed)
}

#[tauri::command]
pub fn copy_password(state: State<AppState>, id: String) -> Result<String, String> {
    let id = Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    open_password(&state, id).ok_or_else(|| "no password is stored for this account".into())
}

#[derive(Serialize)]
pub struct ClientStatus {
    pub installed: bool,
    pub riot_client_running: bool,
    pub league_running: bool,
    pub client_connected: bool,
}

#[tauri::command]
pub fn client_status() -> ClientStatus {
    ClientStatus {
        installed: automation::is_installed(),
        riot_client_running: automation::is_riot_client_running(),
        league_running: automation::is_league_running(),
        client_connected: crate::lcu::find_lockfile().is_ok(),
    }
}

/// Reads live data from the running client and folds it into the account.
#[tauri::command]
pub fn refresh_account(state: State<AppState>, id: String) -> Result<SitePayload, String> {
    let id = Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    let client = LcuClient::connect().map_err(|e| e.to_string())?;
    let snapshot = client.capture_snapshot().map_err(|e| e.to_string())?;
    state.mutate(|accounts| {
        if let Some(a) = accounts.iter_mut().find(|a| a.id == id) {
            apply_snapshot(a, &snapshot);
        }
    })?;
    Ok(list_accounts(state))
}

/// Refreshes whichever account is signed in right now, matching on PUUID; if no
/// account matches, nothing changes. Returns the updated payload.
#[tauri::command]
pub fn refresh_current(state: State<AppState>) -> Result<SitePayload, String> {
    let client = LcuClient::connect().map_err(|e| e.to_string())?;
    let snapshot = client.capture_snapshot().map_err(|e| e.to_string())?;
    let puuid = snapshot.summoner.puuid.clone();
    state.mutate(|accounts| {
        if let Some(a) = accounts
            .iter_mut()
            .find(|a| a.puuid.as_deref() == Some(puuid.as_str()))
        {
            apply_snapshot(a, &snapshot);
        }
    })?;
    Ok(list_accounts(state))
}

#[tauri::command]
pub fn launch_league() -> Result<(), String> {
    automation::launch_league().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn open_launcher() -> Result<(), String> {
    automation::open_launcher().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn kill_league() -> Result<(), String> {
    automation::kill_league().map_err(|e| e.to_string())
}

/// Opens the launcher and types the account's stored credentials into it.
#[tauri::command]
pub fn sign_in(state: State<AppState>, id: String) -> Result<(), String> {
    let id = Uuid::parse_str(&id).map_err(|e| e.to_string())?;
    let username = state
        .with_accounts(|accounts| accounts.iter().find(|a| a.id == id).map(|a| a.login_username.clone()))
        .filter(|u| !u.is_empty())
        .ok_or("this account has no login name saved")?;
    let password = open_password(&state, id).ok_or("this account has no password saved")?;
    if !automation::is_riot_client_running() {
        automation::open_launcher().map_err(|e| e.to_string())?;
        std::thread::sleep(std::time::Duration::from_millis(2500));
    }
    automation::autofill_login(&username, &password).map_err(|e| e.to_string())
}
