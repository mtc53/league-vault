//! Persistence and password encryption, ported from `Sources/Storage.swift`.
//!
//! Kept platform-independent: the app layer decides where the data file lives
//! (`%APPDATA%\LeagueVault\accounts.json` on Windows) and where the AES key is
//! kept (Windows Credential Manager / DPAPI), and hands both in here.

use crate::models::Account;
use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use rand::RngCore;
use std::path::Path;

/// Encrypts stored passwords with an AES-256-GCM key, matching the macOS app's
/// format: base64 of `nonce(12) || ciphertext || tag(16)` — i.e. the "combined"
/// box CryptoKit produces. The key itself is owned by the platform layer.
pub struct Vault {
    cipher: Aes256Gcm,
}

impl Vault {
    /// `key` must be 32 bytes. The platform layer loads it from the OS keystore.
    pub fn new(key: &[u8]) -> Option<Vault> {
        if key.len() != 32 {
            return None;
        }
        Aes256Gcm::new_from_slice(key).ok().map(|cipher| Vault { cipher })
    }

    /// Mints a fresh random 32-byte key for first run.
    pub fn new_key() -> [u8; 32] {
        let mut k = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut k);
        k
    }

    pub fn seal(&self, plaintext: &str) -> Option<String> {
        if plaintext.is_empty() {
            return None;
        }
        let mut nonce_bytes = [0u8; 12];
        rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);
        let ct = self.cipher.encrypt(nonce, plaintext.as_bytes()).ok()?;
        let mut combined = Vec::with_capacity(12 + ct.len());
        combined.extend_from_slice(&nonce_bytes);
        combined.extend_from_slice(&ct);
        Some(B64.encode(combined))
    }

    pub fn open(&self, sealed: &str) -> Option<String> {
        let combined = B64.decode(sealed).ok()?;
        if combined.len() < 12 + 16 {
            return None;
        }
        let (nonce_bytes, ct) = combined.split_at(12);
        let nonce = Nonce::from_slice(nonce_bytes);
        let plain = self.cipher.decrypt(nonce, ct).ok()?;
        String::from_utf8(plain).ok()
    }
}

/// Reads `accounts.json`, normalizing each account. Missing file → empty vault.
pub fn load_accounts(path: &Path) -> Result<Vec<Account>, String> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let data = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mut accounts: Vec<Account> = serde_json::from_str(&data).map_err(|e| e.to_string())?;
    for a in &mut accounts {
        a.normalize();
    }
    Ok(accounts)
}

/// Writes `accounts.json` atomically (write to a temp file, then rename).
pub fn save_accounts(path: &Path, accounts: &[Account]) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_string_pretty(accounts).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json.as_bytes()).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Account;

    #[test]
    fn seal_then_open_roundtrips() {
        let key = Vault::new_key();
        let v = Vault::new(&key).unwrap();
        let sealed = v.seal("hunter2").unwrap();
        assert_ne!(sealed, "hunter2");
        assert_eq!(v.open(&sealed).as_deref(), Some("hunter2"));
    }

    #[test]
    fn open_fails_with_a_different_key() {
        let a = Vault::new(&Vault::new_key()).unwrap();
        let b = Vault::new(&Vault::new_key()).unwrap();
        let sealed = a.seal("secret").unwrap();
        assert_eq!(b.open(&sealed), None);
    }

    #[test]
    fn empty_password_seals_to_none() {
        let v = Vault::new(&Vault::new_key()).unwrap();
        assert_eq!(v.seal(""), None);
    }

    #[test]
    fn save_then_load_roundtrips() {
        let dir = std::env::temp_dir().join(format!("lv-test-{}", uuid::Uuid::new_v4()));
        let path = dir.join("accounts.json");
        let mut a = Account::new();
        a.label = "Test".into();
        a.game_name = "Someone".into();
        save_accounts(&path, &[a.clone()]).unwrap();
        let loaded = load_accounts(&path).unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].label, "Test");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn missing_file_is_empty() {
        let path = std::env::temp_dir().join("definitely-not-there-lv.json");
        assert!(load_accounts(&path).unwrap().is_empty());
    }
}
