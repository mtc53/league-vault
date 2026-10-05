//! Where the vault's AES key lives on Windows.
//!
//! The macOS app kept the password-encryption key in the login Keychain. The
//! Windows equivalent is a key file in the app's data directory, itself sealed
//! with DPAPI (`CryptProtectData`) so only the signed-in Windows user — on this
//! machine — can unseal it. The key never sits in plaintext on disk.

use std::path::{Path, PathBuf};

use leaguevault_core::store::Vault;

/// A 32-byte AES-256 key for sealing stored passwords.
pub type VaultKey = [u8; 32];

#[derive(Debug, thiserror::Error)]
pub enum SecretError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("the key file is corrupt or was written by a different Windows user")]
    Unprotect,
    #[error("could not protect the key with DPAPI")]
    Protect,
    #[error("key storage is only implemented on Windows")]
    Unsupported,
}

fn key_path(dir: &Path) -> PathBuf {
    dir.join("vault.key")
}

/// Loads the vault key, creating and sealing a fresh random one the first time.
pub fn load_or_create(dir: &Path) -> Result<VaultKey, SecretError> {
    let path = key_path(dir);
    if path.exists() {
        let sealed = std::fs::read(&path)?;
        let raw = unprotect(&sealed)?;
        if raw.len() == 32 {
            let mut key = [0u8; 32];
            key.copy_from_slice(&raw);
            return Ok(key);
        }
        // A wrong-sized blob means a corrupt file; fall through and mint a new one.
    }
    let key = Vault::new_key();
    let sealed = protect(&key)?;
    std::fs::create_dir_all(dir)?;
    std::fs::write(&path, sealed)?;
    Ok(key)
}

// ---- DPAPI ----------------------------------------------------------------

#[cfg(windows)]
fn protect(data: &[u8]) -> Result<Vec<u8>, SecretError> {
    use windows::Win32::Foundation::{HLOCAL, LocalFree};
    use windows::Win32::Security::Cryptography::{CryptProtectData, CRYPT_INTEGER_BLOB};

    unsafe {
        let mut input = CRYPT_INTEGER_BLOB {
            cbData: data.len() as u32,
            pbData: data.as_ptr() as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB::default();
        let ok = CryptProtectData(
            &mut input,
            None,
            None,
            None,
            None,
            0,
            &mut output,
        );
        if ok.is_err() {
            return Err(SecretError::Protect);
        }
        let slice = std::slice::from_raw_parts(output.pbData, output.cbData as usize);
        let out = slice.to_vec();
        let _ = LocalFree(HLOCAL(output.pbData as *mut _));
        Ok(out)
    }
}

#[cfg(windows)]
fn unprotect(data: &[u8]) -> Result<Vec<u8>, SecretError> {
    use windows::Win32::Foundation::{HLOCAL, LocalFree};
    use windows::Win32::Security::Cryptography::{CryptUnprotectData, CRYPT_INTEGER_BLOB};

    unsafe {
        let mut input = CRYPT_INTEGER_BLOB {
            cbData: data.len() as u32,
            pbData: data.as_ptr() as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB::default();
        let ok = CryptUnprotectData(
            &mut input,
            None,
            None,
            None,
            None,
            0,
            &mut output,
        );
        if ok.is_err() {
            return Err(SecretError::Unprotect);
        }
        let slice = std::slice::from_raw_parts(output.pbData, output.cbData as usize);
        let out = slice.to_vec();
        let _ = LocalFree(HLOCAL(output.pbData as *mut _));
        Ok(out)
    }
}

#[cfg(not(windows))]
fn protect(_data: &[u8]) -> Result<Vec<u8>, SecretError> {
    Err(SecretError::Unsupported)
}

#[cfg(not(windows))]
fn unprotect(_data: &[u8]) -> Result<Vec<u8>, SecretError> {
    Err(SecretError::Unsupported)
}
