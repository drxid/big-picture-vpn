//! Discovery and control of AmneziaWG tunnels.
//!
//! Two facts drive the design, both established by testing against a live
//! install rather than assumed:
//!
//! * Each config becomes its own Windows service named
//!   `AmneziaWGTunnel$<config name>`. Toggling the VPN is just starting or
//!   stopping that service, which takes well under a second.
//! * A user granted START/STOP on the service can do this with no elevation
//!   and no UAC prompt -- essential, because a UAC dialog raised from Steam
//!   Big Picture appears behind the fullscreen overlay and cannot be
//!   dismissed with a gamepad. `scripts/setup-tunnels.ps1` grants that right.
//!
//! Tunnels are enumerated from the registry rather than the SCM: the services
//! key is readable by ordinary users and carries the config path too.

use serde::{Deserialize, Serialize};
use std::ffi::OsStr;
use std::path::PathBuf;
use std::process::Command;
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use windows_service::service::{ServiceAccess, ServiceState};
use windows_service::service_manager::{ServiceManager, ServiceManagerAccess};
use winreg::enums::{HKEY_LOCAL_MACHINE, KEY_READ};
use winreg::RegKey;

const SERVICE_PREFIX: &str = "AmneziaWGTunnel$";
const SERVICES_KEY: &str = r"SYSTEM\CurrentControlSet\Services";

/// Privileged fallback. Rights granted directly on the tunnel service survive
/// only until AmneziaWG recreates it -- which it does on every deactivate /
/// reactivate cycle, resetting the descriptor. The scheduled task does not
/// depend on the service, so it keeps working; see scripts/tunnel-control.ps1.
const TASK_NAME: &str = "BigPictureVPN-Control";
const TASK_TIMEOUT: Duration = Duration::from_secs(30);
/// Observed round trip is well under two seconds, so silence past this means
/// the request was dropped rather than still being worked on.
const TASK_RETRY_AFTER: Duration = Duration::from_secs(5);

/// Starting and stopping are asynchronous; these bound the wait for the
/// service to leave StartPending/StopPending. Observed timings are ~0.3 s to
/// stop and ~0.6 s to start, so this is a generous ceiling.
const SETTLE_TIMEOUT: Duration = Duration::from_secs(20);
const POLL_INTERVAL: Duration = Duration::from_millis(150);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tunnel {
    /// Config name, e.g. "-PC". Note it may legitimately start with a dash.
    pub name: String,
    pub service_name: String,
    pub display_name: String,
    pub config_path: Option<String>,
    pub state: String,
    pub running: bool,
}

fn service_name_for(tunnel: &str) -> String {
    format!("{SERVICE_PREFIX}{tunnel}")
}

fn state_label(state: ServiceState) -> &'static str {
    match state {
        ServiceState::Stopped => "Stopped",
        ServiceState::StartPending => "StartPending",
        ServiceState::StopPending => "StopPending",
        ServiceState::Running => "Running",
        ServiceState::ContinuePending => "ContinuePending",
        ServiceState::PausePending => "PausePending",
        ServiceState::Paused => "Paused",
    }
}

/// A failed operation, and whether it failed for lack of rights -- which is
/// what decides between reporting an error and retrying through the task.
struct ControlError {
    denied: bool,
    message: String,
}

fn describe(err: &windows_service::Error, action: &str, tunnel: &str) -> ControlError {
    let code = match err {
        windows_service::Error::Winapi(io) => io.raw_os_error(),
        _ => None,
    };
    // 5 = access denied, 1060 = no such service. Both are retried through the
    // privileged helper: the first because AmneziaWG reset the descriptor, the
    // second because it deletes a tunnel's service when the tunnel is switched
    // off, and recreating it needs administrator rights.
    let denied = matches!(code, Some(5) | Some(1060));
    ControlError {
        denied,
        message: format!("Не удалось {action} туннель «{tunnel}»: {err}"),
    }
}

fn plain(message: String) -> ControlError {
    ControlError {
        denied: false,
        message,
    }
}

fn connect() -> Result<ServiceManager, String> {
    ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
        .map_err(|e| format!("Нет доступа к диспетчеру служб Windows: {e}"))
}

/// `"C:\...\amneziawg.exe" /tunnelservice "C:\...\-PC.conf.dpapi"` -> the
/// quoted config path at the end.
fn extract_config_path(image_path: &str) -> Option<String> {
    let quoted: Vec<&str> = image_path.split('"').skip(1).step_by(2).collect();
    quoted
        .into_iter()
        .rev()
        .find(|s| s.to_ascii_lowercase().contains(".conf"))
        .map(|s| s.to_string())
}

fn query_state(manager: &ServiceManager, service_name: &str) -> Option<ServiceState> {
    let service = manager
        .open_service(service_name, ServiceAccess::QUERY_STATUS)
        .ok()?;
    service.query_status().ok().map(|s| s.current_state)
}

/// Every tunnel the user has, whether or not it currently has a service.
///
/// Two sources, because neither is sufficient alone. Services are read from the
/// registry, which ordinary users can do. But AmneziaWG *deletes* a tunnel's
/// service when the tunnel is switched off, so a VPN that is simply off leaves
/// no service at all -- and the config directory it would be listed from is
/// admin-only. The privileged helper publishes that inventory to
/// `%ProgramData%\BigPictureVPN\tunnels.json`, which fills the gap.
pub fn list_tunnels() -> Result<Vec<Tunnel>, String> {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let services = hklm
        .open_subkey_with_flags(SERVICES_KEY, KEY_READ)
        .map_err(|e| format!("Не удалось прочитать список служб: {e}"))?;

    let manager = connect()?;
    let mut tunnels = Vec::new();

    for service_name in services.enum_keys().flatten() {
        let Some(name) = service_name.strip_prefix(SERVICE_PREFIX) else {
            continue;
        };
        if name.is_empty() {
            continue;
        }

        let key = match services.open_subkey_with_flags(&service_name, KEY_READ) {
            Ok(k) => k,
            Err(_) => continue,
        };
        let image_path: String = key.get_value("ImagePath").unwrap_or_default();
        let display_name: String = key
            .get_value("DisplayName")
            .unwrap_or_else(|_| name.to_string());

        let state = query_state(&manager, &service_name);

        tunnels.push(Tunnel {
            name: name.to_string(),
            service_name: service_name.clone(),
            display_name,
            config_path: extract_config_path(&image_path),
            state: state.map(state_label).unwrap_or("Unknown").to_string(),
            running: state == Some(ServiceState::Running),
        });
    }

    // Add configs the helper reported that have no service right now. Their
    // state is known without asking anyone: no service means not running.
    for name in read_inventory() {
        if tunnels.iter().any(|t| t.name == name) {
            continue;
        }
        tunnels.push(Tunnel {
            service_name: service_name_for(&name),
            display_name: name.clone(),
            name,
            config_path: None,
            state: "Stopped".to_string(),
            running: false,
        });
    }

    tunnels.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    Ok(tunnels)
}

/// Read a file the helper wrote, tolerating a byte-order mark.
///
/// Anything written from PowerShell with `Set-Content -Encoding UTF8` carries a
/// BOM, and serde_json treats that leading character as malformed input. Files
/// are written with WriteAllText now, but stripping it here costs nothing and
/// makes the two sides independent.
fn read_helper_file(path: PathBuf) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    Some(text.trim_start_matches('\u{feff}').to_string())
}

/// Tunnel names from the helper's inventory file. Absent or unparseable is not
/// an error: the app still works from services alone, it just cannot offer a
/// config whose service does not exist yet.
fn read_inventory() -> Vec<String> {
    let Ok(dir) = data_dir() else {
        return Vec::new();
    };
    let Some(text) = read_helper_file(dir.join("tunnels.json")) else {
        return Vec::new();
    };
    match serde_json::from_str::<Inventory>(&text) {
        Ok(inventory) => inventory.tunnels.into_iter().map(|t| t.name).collect(),
        Err(_) => Vec::new(),
    }
}

#[derive(Deserialize)]
struct Inventory {
    tunnels: Vec<InventoryEntry>,
}

#[derive(Deserialize)]
struct InventoryEntry {
    name: String,
}

/// Ask the helper to refresh the inventory of configs.
///
/// Called at startup: the config directory is admin-only, so this is the only
/// way to learn about a tunnel that is currently switched off.
pub fn refresh_inventory() -> Result<(), String> {
    via_task("list", "")
}

/// Poll until the service reaches `target`.
///
/// A vanished service is reported explicitly: AmneziaWG deletes a tunnel
/// service whose config cannot connect, so "gone" means a broken config, not
/// a transient failure.
fn wait_for(
    manager: &ServiceManager,
    service_name: &str,
    target: ServiceState,
) -> Result<(), ControlError> {
    let tunnel = service_name.strip_prefix(SERVICE_PREFIX).unwrap_or(service_name);
    let deadline = Instant::now() + SETTLE_TIMEOUT;

    loop {
        match manager.open_service(service_name, ServiceAccess::QUERY_STATUS) {
            Ok(service) => match service.query_status() {
                Ok(status) if status.current_state == target => return Ok(()),
                Ok(_) => {}
                Err(e) => return Err(describe(&e, "прочитать статус", tunnel)),
            },
            Err(_) => {
                return Err(plain(format!(
                    "Служба туннеля «{tunnel}» исчезла. AmneziaWG удаляет службу, \
                     если конфиг не может подключиться. Проверь конфиг в AmneziaWG, \
                     затем запусти scripts\\setup-tunnels.ps1 -Activate '{tunnel}'"
                )))
            }
        }

        if Instant::now() >= deadline {
            return Err(plain(format!(
                "Туннель «{tunnel}» не перешёл в состояние {} за {} с",
                state_label(target),
                SETTLE_TIMEOUT.as_secs()
            )));
        }
        sleep(POLL_INTERVAL);
    }
}

fn direct_start(tunnel: &str) -> Result<(), ControlError> {
    let manager = connect().map_err(plain)?;
    let service_name = service_name_for(tunnel);

    if query_state(&manager, &service_name) == Some(ServiceState::Running) {
        return Ok(());
    }

    let service = manager
        .open_service(&service_name, ServiceAccess::START | ServiceAccess::QUERY_STATUS)
        .map_err(|e| describe(&e, "запустить", tunnel))?;
    service
        .start(&[] as &[&OsStr])
        .map_err(|e| describe(&e, "запустить", tunnel))?;

    wait_for(&manager, &service_name, ServiceState::Running)
}

fn direct_stop(tunnel: &str) -> Result<(), ControlError> {
    let manager = connect().map_err(plain)?;
    let service_name = service_name_for(tunnel);

    if query_state(&manager, &service_name) == Some(ServiceState::Stopped) {
        return Ok(());
    }

    let service = manager
        .open_service(&service_name, ServiceAccess::STOP | ServiceAccess::QUERY_STATUS)
        .map_err(|e| describe(&e, "остановить", tunnel))?;
    service
        .stop()
        .map_err(|e| describe(&e, "остановить", tunnel))?;

    wait_for(&manager, &service_name, ServiceState::Stopped)
}

/// Whether Windows currently has a service for this tunnel.
///
/// Not a detail: AmneziaWG removes the service when a tunnel is switched off,
/// so "no service" is the normal state of a VPN that is simply off, and it
/// decides which path can turn it back on.
fn service_exists(tunnel: &str) -> bool {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    hklm.open_subkey_with_flags(
        format!("{SERVICES_KEY}\\{}", service_name_for(tunnel)),
        KEY_READ,
    )
    .is_ok()
}

pub fn start(tunnel: &str) -> Result<(), String> {
    // Recreating a missing service needs administrator rights, so there is no
    // point trying the direct path first -- it can only fail.
    if !service_exists(tunnel) {
        return via_task("start", tunnel);
    }
    match direct_start(tunnel) {
        Ok(()) => Ok(()),
        Err(e) if e.denied => via_task("start", tunnel),
        Err(e) => Err(e.message),
    }
}

pub fn stop(tunnel: &str) -> Result<(), String> {
    // No service means AmneziaWG already removed it, i.e. the tunnel is off.
    if !service_exists(tunnel) {
        return Ok(());
    }
    match direct_stop(tunnel) {
        Ok(()) => Ok(()),
        Err(e) if e.denied => via_task("stop", tunnel),
        Err(e) => Err(e.message),
    }
}

/// Make `tunnel` the only active one.
///
/// Tunnels are stopped first because each config installs its own default
/// route; two active at once fight over 0.0.0.0/0 and the winner is undefined.
/// The privileged helper enforces the same rule on its side, so falling back
/// to it does not skip the check.
pub fn switch(tunnel: &str) -> Result<(), String> {
    for other in list_tunnels()? {
        if other.name != tunnel && other.running {
            stop(&other.name)?;
        }
    }
    start(tunnel)
}

/// The tunnel currently running, if any.
pub fn active() -> Result<Option<String>, String> {
    Ok(list_tunnels()?.into_iter().find(|t| t.running).map(|t| t.name))
}

// --- privileged fallback ---------------------------------------------------

#[derive(Serialize)]
struct ControlRequest<'a> {
    id: String,
    action: &'a str,
    tunnel: &'a str,
    /// Unix seconds. The helper rejects anything stale, so a leftover request
    /// file cannot be replayed later.
    issued: u64,
}

#[derive(Deserialize)]
struct ControlOutcome {
    id: String,
    ok: bool,
    #[serde(default)]
    error: String,
}

/// Shared with the helper, which runs as SYSTEM and therefore cannot use the
/// user's profile directory.
fn data_dir() -> Result<PathBuf, String> {
    let base = std::env::var("ProgramData")
        .map_err(|_| "Переменная окружения ProgramData не задана".to_string())?;
    Ok(PathBuf::from(base).join("BigPictureVPN"))
}

fn unique_id() -> (String, u64) {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    (
        format!("{}-{}", now.as_secs(), now.subsec_nanos()),
        now.as_secs(),
    )
}

const SETUP_HINT: &str = "Запусти от администратора: scripts\\setup-scheduled-task.ps1";

/// Ask the scheduled task to do what this process is not allowed to do.
///
/// Used only after a direct attempt was refused, so the fast path stays fast
/// and this runs only when AmneziaWG has reset the service descriptor.
fn via_task(action: &str, tunnel: &str) -> Result<(), String> {
    let dir = data_dir()?;
    if !dir.is_dir() {
        return Err(format!(
            "Нет прав на управление туннелем «{tunnel}», а служебная задача не установлена. \
             {SETUP_HINT}"
        ));
    }

    let (id, issued) = unique_id();
    let request = ControlRequest {
        id: id.clone(),
        action,
        tunnel,
        issued,
    };
    let body = serde_json::to_string(&request)
        .map_err(|e| format!("Не удалось сформировать запрос: {e}"))?;

    let request_path = dir.join("request.json");
    let result_path = dir.join("result.json");

    // Drop any previous answer, so a stale one cannot be mistaken for ours.
    let _ = std::fs::remove_file(&result_path);
    std::fs::write(&request_path, body)
        .map_err(|e| format!("Не удалось записать запрос в {}: {e}", request_path.display()))?;

    run_task()?;

    // Retry once mid-wait. `schtasks /run` returns success but starts nothing
    // when the previous run is still marked Running, which happens routinely
    // because requests come back to back. The task is registered with
    // MultipleInstances=Queue so this should not arise, but a task registered
    // by an older version of the setup script would still drop the request,
    // and hanging for the full timeout is a bad way to find that out.
    let retry_at = Instant::now() + TASK_RETRY_AFTER;
    let deadline = Instant::now() + TASK_TIMEOUT;
    let mut retried = false;

    loop {
        if let Some(text) = read_helper_file(result_path.clone()) {
            if let Ok(outcome) = serde_json::from_str::<ControlOutcome>(&text) {
                if outcome.id == id {
                    return if outcome.ok {
                        Ok(())
                    } else {
                        Err(outcome.error)
                    };
                }
            }
        }
        if !retried && Instant::now() >= retry_at {
            retried = true;
            run_task()?;
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "Служебная задача не ответила за {} с. {SETUP_HINT}",
                TASK_TIMEOUT.as_secs()
            ));
        }
        sleep(POLL_INTERVAL);
    }
}

fn run_task() -> Result<(), String> {
    let status = Command::new("schtasks.exe")
        .args(["/run", "/tn", TASK_NAME])
        .status()
        .map_err(|e| format!("Не удалось запустить служебную задачу: {e}. {SETUP_HINT}"))?;
    if !status.success() {
        return Err(format!(
            "Служебная задача не запустилась (код {}). {SETUP_HINT}",
            status.code().unwrap_or(-1)
        ));
    }
    Ok(())
}
