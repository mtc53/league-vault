//! The app's in-memory vault and where it lives on disk.

use std::path::PathBuf;
use std::sync::Mutex;

use leaguevault_core::models::Account;
use leaguevault_core::store::{self, Vault};

use crate::secret::{self, VaultKey};

/// `%APPDATA%\LeagueVault` on Windows, mirroring the Mac app's
/// `~/Library/Application Support/LeagueVault`.
pub fn data_dir() -> PathBuf {
    if let Ok(appdata) = std::env::var("APPDATA") {
        return PathBuf::from(appdata).join("LeagueVault");
    }
    // A sensible fallback for development on other platforms.
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".leaguevault")
}

fn accounts_path() -> PathBuf {
    data_dir().join("accounts.json")
}

pub struct AppState {
    inner: Mutex<Inner>,
}

struct Inner {
    accounts: Vec<Account>,
    key: VaultKey,
}

impl AppState {
    /// Loads the vault key (creating one on first run) and the accounts file.
    pub fn load() -> Result<AppState, String> {
        let dir = data_dir();
        let key = secret::load_or_create(&dir).map_err(|e| e.to_string())?;
        let accounts = store::load_accounts(&accounts_path())?;
        Ok(AppState { inner: Mutex::new(Inner { accounts, key }) })
    }

    pub fn with_accounts<R>(&self, f: impl FnOnce(&[Account]) -> R) -> R {
        let inner = self.inner.lock().unwrap();
        f(&inner.accounts)
    }

    /// Runs `f` against the mutable account list, persisting the result atomically.
    pub fn mutate<R>(&self, f: impl FnOnce(&mut Vec<Account>) -> R) -> Result<R, String> {
        let mut inner = self.inner.lock().unwrap();
        let out = f(&mut inner.accounts);
        store::save_accounts(&accounts_path(), &inner.accounts)?;
        Ok(out)
    }

    /// Builds the password cipher from the stored key.
    pub fn vault(&self) -> Vault {
        let inner = self.inner.lock().unwrap();
        Vault::new(&inner.key).expect("vault key is 32 bytes")
    }

    pub fn clone_accounts(&self) -> Vec<Account> {
        self.inner.lock().unwrap().accounts.clone()
    }
}
