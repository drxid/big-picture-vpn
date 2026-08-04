mod tunnel;

use tunnel::Tunnel;

#[tauri::command]
fn list_tunnels() -> Result<Vec<Tunnel>, String> {
    tunnel::list_tunnels()
}

#[tauri::command]
fn active_tunnel() -> Result<Option<String>, String> {
    tunnel::active()
}

/// Refresh the list of configs via the privileged helper.
///
/// Needed because a tunnel that is switched off has no service and lives only
/// in AmneziaWG's admin-only config directory, so it is invisible to this
/// process otherwise.
#[tauri::command]
fn refresh_inventory() -> Result<(), String> {
    tunnel::refresh_inventory()
}

#[tauri::command]
fn start_tunnel(name: String) -> Result<(), String> {
    tunnel::start(&name)
}

#[tauri::command]
fn stop_tunnel(name: String) -> Result<(), String> {
    tunnel::stop(&name)
}

/// Activate one tunnel and stop every other one.
#[tauri::command]
fn switch_tunnel(name: String) -> Result<(), String> {
    tunnel::switch(&name)
}

/// Needed because the app runs fullscreen on a TV, where the window has no
/// close button within reach of a gamepad.
#[tauri::command]
fn exit_app(app: tauri::AppHandle) {
    app.exit(0);
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }

            // The app ships fullscreen and undecorated, like a game -- that is
            // set in tauri.conf.json so it holds from the first frame, with no
            // visible window resize on startup. Development drops out of
            // fullscreen so devtools and the terminal stay reachable.
            #[cfg(debug_assertions)]
            {
                use tauri::Manager;
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.set_fullscreen(false);
                    let _ = window.set_decorations(true);
                    let _ = window.set_resizable(true);
                }
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_tunnels,
            active_tunnel,
            refresh_inventory,
            start_tunnel,
            stop_tunnel,
            switch_tunnel,
            exit_app
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
