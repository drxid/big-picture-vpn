//! Control of the Happ proxy client.
//!
//! Happ is a different animal from AmneziaWG, and these facts come from testing
//! against a live 4.6.1 install rather than from documentation -- the commands
//! below are not documented anywhere:
//!
//! * The tunnel belongs to the GUI process, not to the `HappService` daemon:
//!   killing `Happ.exe` takes the tunnel down with it. So the GUI is the thing
//!   to talk to, and `happ://connect` / `happ://disconnect` passed to its exe
//!   are forwarded to the running instance. Both are idempotent and need no
//!   elevation, so unlike AmneziaWG the privileged helper plays no part.
//! * If Happ is not running, the same call starts it. A trailing `--autostart`
//!   keeps the window in the tray; without it the window opens on top of Big
//!   Picture.
//! * Happ reports nothing back, so success is read from the network adapter it
//!   creates, which exists only while connected. Its name depends on the tunnel
//!   engine (`happ-xray`, `happ-tun`), hence the prefix match.

use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

use ipconfig::{get_adapters, OperStatus};

use crate::i18n::tr;
use crate::tunnel::Tunnel;

/// The name shown in the list, which also selects this backend in commands. The
/// space matters: AmneziaWG config names cannot contain one, so no config can
/// collide with it.
pub const NAME: &str = "Happ VPN";

const PROVIDER: &str = "happ";
const SERVICE_NAME: &str = "HappService";
const ADAPTER_PREFIX: &str = "happ-";
/// Keeps tasklist's console from flashing over a fullscreen game.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Observed timings are ~1 s to disconnect and ~2 s to connect, including a
/// cold start of the GUI, so this is a generous ceiling.
const SETTLE_TIMEOUT: Duration = Duration::from_secs(15);
const POLL_INTERVAL: Duration = Duration::from_millis(150);

fn exe_path() -> Option<PathBuf> {
    let base = std::env::var("ProgramFiles").ok()?;
    let path = PathBuf::from(base).join(r"FlyFrogLLC\Happ\Happ.exe");
    path.is_file().then_some(path)
}

fn tunnel_is_up() -> bool {
    let Ok(adapters) = get_adapters() else {
        return false;
    };
    adapters.iter().any(|adapter| {
        adapter.friendly_name().starts_with(ADAPTER_PREFIX)
            && adapter.oper_status() == OperStatus::IfOperStatusUp
    })
}

/// The list entry for Happ, or nothing if it is not installed.
pub fn tunnel() -> Option<Tunnel> {
    exe_path()?;
    let running = tunnel_is_up();
    Some(Tunnel {
        name: NAME.to_string(),
        provider: PROVIDER,
        service_name: SERVICE_NAME.to_string(),
        display_name: NAME.to_string(),
        config_path: None,
        state: if running { "Running" } else { "Stopped" }.to_string(),
        running,
    })
}

fn gui_running() -> bool {
    Command::new("tasklist.exe")
        .args(["/fi", "imagename eq Happ.exe", "/fo", "csv", "/nh"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).contains("Happ.exe"))
        .unwrap_or(false)
}

fn send(command: &str) -> Result<(), String> {
    let exe = exe_path()
        .ok_or_else(|| tr(format!("{NAME} не установлен"), format!("{NAME} is not installed")))?;
    let link = format!("happ://{command}");
    // The order matters both ways. A running instance only looks at the first
    // argument, so `--autostart` there makes it silently ignore the command;
    // a cold start only stays in the tray if `--autostart` does come first.
    let args = if gui_running() {
        [link.as_str(), "--autostart"]
    } else {
        ["--autostart", link.as_str()]
    };
    // Not waited for: on a cold start this process is the GUI itself and stays
    // running, and it has to, because the tunnel lives and dies with it.
    Command::new(exe)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| {
            tr(
                format!("Не удалось запустить Happ: {e}"),
                format!("Could not start Happ: {e}"),
            )
        })?;
    Ok(())
}

fn wait_for(up: bool) -> bool {
    let deadline = Instant::now() + SETTLE_TIMEOUT;
    loop {
        if tunnel_is_up() == up {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        sleep(POLL_INTERVAL);
    }
}

pub fn start() -> Result<(), String> {
    if tunnel_is_up() {
        return Ok(());
    }
    send("connect")?;
    if wait_for(true) {
        return Ok(());
    }
    let seconds = SETTLE_TIMEOUT.as_secs();
    Err(tr(
        format!("Happ не поднял туннель за {seconds} с. Проверь, что в нём выбран сервер и включён режим TUN"),
        format!("Happ did not bring the tunnel up in {seconds} s. Check that a server is selected and TUN mode is on"),
    ))
}

pub fn stop() -> Result<(), String> {
    if !tunnel_is_up() {
        return Ok(());
    }
    send("disconnect")?;
    if wait_for(false) {
        return Ok(());
    }
    let seconds = SETTLE_TIMEOUT.as_secs();
    Err(tr(
        format!("Happ не отключился за {seconds} с"),
        format!("Happ did not disconnect in {seconds} s"),
    ))
}
