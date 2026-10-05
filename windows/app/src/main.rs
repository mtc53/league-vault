// Hide the console window on Windows release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod automation;
mod commands;
mod lcu;
mod secret;
mod state;

use state::AppState;

fn main() {
    let app_state = match AppState::load() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("League Vault could not open its vault: {e}");
            std::process::exit(1);
        }
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(app_state)
        .invoke_handler(tauri::generate_handler![
            commands::list_accounts,
            commands::get_account,
            commands::save_account,
            commands::delete_account,
            commands::set_password,
            commands::has_password,
            commands::copy_password,
            commands::client_status,
            commands::refresh_account,
            commands::refresh_current,
            commands::launch_league,
            commands::open_launcher,
            commands::kill_league,
            commands::sign_in,
        ])
        .run(tauri::generate_context!())
        .expect("error while running League Vault");
}
