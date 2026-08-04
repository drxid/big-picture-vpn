import { computed, onMounted, onUnmounted, ref } from "vue";
import { invoke } from "@tauri-apps/api/core";

export interface Tunnel {
  name: string;
  serviceName: string;
  displayName: string;
  configPath: string | null;
  state: string;
  running: boolean;
}

const STORAGE_SELECTED = "bpvpn.selected";
const STORAGE_AUTOCONNECT = "bpvpn.autoConnect";

/// Status is cheap to read (a service query, no network), so polling keeps the
/// display honest even when the tunnel is changed from outside the app.
const POLL_MS = 2000;

/// Opening the frontend in a plain browser has no Tauri backend behind it.
/// Rather than showing an error wall, dev builds fall back to fixtures, so the
/// interface can be worked on without rebuilding the Rust side each time.
const HAS_TAURI = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
const USE_FIXTURES = import.meta.env.DEV && !HAS_TAURI;

let fixtures: Tunnel[] = [
  {
    name: "-PC",
    serviceName: "AmneziaWGTunnel$-PC",
    displayName: "AmneziaWG Tunnel: -PC",
    configPath: null,
    state: "Running",
    running: true,
  },
  {
    name: "Amsterdam",
    serviceName: "AmneziaWGTunnel$Amsterdam",
    displayName: "AmneziaWG Tunnel: Amsterdam",
    configPath: null,
    state: "Stopped",
    running: false,
  },
];

function markRunning(name: string | null) {
  fixtures = fixtures.map((t) => ({
    ...t,
    running: t.name === name,
    state: t.name === name ? "Running" : "Stopped",
  }));
}

async function call<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  if (!USE_FIXTURES) return invoke<T>(command, args);

  // Roughly the real timings: ~0.3 s to stop, ~0.6 s to start.
  await new Promise((resolve) => setTimeout(resolve, 400));
  switch (command) {
    case "list_tunnels":
      return fixtures as T;
    case "switch_tunnel":
      markRunning(String(args?.name));
      break;
    case "stop_tunnel":
      markRunning(null);
      break;
  }
  return undefined as T;
}

export function useTunnels() {
  const tunnels = ref<Tunnel[]>([]);
  const selected = ref<string | null>(localStorage.getItem(STORAGE_SELECTED));
  const busy = ref(false);
  const error = ref<string | null>(null);
  const ready = ref(false);
  /// The tunnel currently being connected, if any.
  const pending = ref<string | null>(null);

  const autoConnect = ref(localStorage.getItem(STORAGE_AUTOCONNECT) !== "false");

  const current = computed(
    () => tunnels.value.find((t) => t.name === selected.value) ?? null,
  );
  const activeTunnel = computed(() => tunnels.value.find((t) => t.running) ?? null);
  const isOn = computed(() => activeTunnel.value !== null);

  let timer: number | undefined;

  async function refresh() {
    try {
      tunnels.value = await call<Tunnel[]>("list_tunnels");

      // Keep the highlight pointing at something real, but never move it on
      // the user. It is a cursor now, not a mirror of what is running -- an
      // earlier version re-pinned it to the active tunnel on every poll, which
      // silently undid every press of the stick two seconds later.
      const stillThere =
        selected.value !== null && tunnels.value.some((t) => t.name === selected.value);
      if (!stillThere && tunnels.value.length) {
        const running = tunnels.value.find((t) => t.running);
        setSelected((running ?? tunnels.value[0]).name);
      }
    } catch (e) {
      error.value = String(e);
    }
  }

  function setSelected(name: string) {
    selected.value = name;
    localStorage.setItem(STORAGE_SELECTED, name);
  }

  function setAutoConnect(value: boolean) {
    autoConnect.value = value;
    localStorage.setItem(STORAGE_AUTOCONNECT, String(value));
  }

  async function run(action: () => Promise<void>) {
    if (busy.value) return;
    busy.value = true;
    error.value = null;
    try {
      await action();
    } catch (e) {
      error.value = String(e);
    } finally {
      await refresh();
      busy.value = false;
    }
  }

  /// Turning on always goes through switch_tunnel: it stops any other tunnel
  /// first, since two active configs fight over the default route.
  async function turnOn(name?: string) {
    const target = name ?? selected.value;
    if (!target) return;
    // Which card to animate. `busy` alone cannot say where the work is
    // happening, and during a switch the answer is not the running tunnel.
    pending.value = target;
    try {
      await run(() => call("switch_tunnel", { name: target }));
    } finally {
      pending.value = null;
    }
  }

  async function turnOff() {
    const target = activeTunnel.value?.name ?? selected.value;
    if (!target) return;
    await run(() => call("stop_tunnel", { name: target }));
  }

  async function toggle() {
    if (isOn.value) await turnOff();
    else await turnOn();
  }

  /// Move the highlight. Deliberately inert: browsing the list must not touch
  /// the connection, or every step through it drops the tunnel and dials
  /// another one.
  function highlight(name: string) {
    setSelected(name);
  }

  /// Connect the highlighted tunnel, replacing whatever is running.
  ///
  /// This is the one place a switch happens, so it is always an explicit act.
  ///
  /// Switching stops the current tunnel before starting the new one, so a
  /// config that cannot connect would otherwise leave the machine with no VPN
  /// at all -- and AmneziaWG deletes the service of such a config, so the
  /// failure is silent from the user's side. On failure the previous tunnel is
  /// restored and the original error kept.
  async function apply() {
    const target = selected.value;
    if (!target) return;

    const previous = activeTunnel.value?.name ?? null;
    if (previous === target) return;

    await turnOn(target);

    if (previous && !isOn.value) {
      const failure = error.value;
      await turnOn(previous);
      setSelected(previous);
      if (failure) {
        error.value = isOn.value
          ? `${failure} Вернул «${previous}».`
          : `${failure} Вернуть «${previous}» тоже не вышло.`;
      }
    }
  }

  /// True when the highlight has moved off the running tunnel, i.e. there is
  /// something for `apply` to do. Drives whether the hint is shown at all.
  const canApply = computed(
    () => selected.value !== null && activeTunnel.value?.name !== selected.value,
  );

  function step(direction: 1 | -1) {
    if (!tunnels.value.length) return null;
    const index = tunnels.value.findIndex((t) => t.name === selected.value);
    const next = (index + direction + tunnels.value.length) % tunnels.value.length;
    return tunnels.value[next].name;
  }

  async function exit() {
    await call("exit_app");
  }

  onMounted(async () => {
    // Show something immediately. Reading services from the registry is
    // instant, unlike everything below, which goes through the privileged
    // helper -- and a screen stuck on "checking" reads as a hang.
    await refresh();
    ready.value = true;

    // A tunnel that is switched off has no service, and its config lives in an
    // admin-only directory -- so without this the list would look empty
    // whenever the VPN is actually off. Failure is not fatal: the app still
    // works with whatever services exist.
    try {
      await call("refresh_inventory");
      await refresh();
    } catch (e) {
      error.value = String(e);
    }

    // Autostart: only acts when nothing is already up, so launching the app
    // never disturbs a tunnel the user already had running.
    if (autoConnect.value && !isOn.value && selected.value) {
      await turnOn();
    }

    timer = window.setInterval(() => {
      if (!busy.value) void refresh();
    }, POLL_MS);
  });

  onUnmounted(() => {
    if (timer) clearInterval(timer);
  });

  return {
    tunnels,
    selected,
    current,
    activeTunnel,
    isOn,
    busy,
    error,
    ready,
    pending,
    autoConnect,
    refresh,
    toggle,
    turnOn,
    turnOff,
    highlight,
    apply,
    canApply,
    step,
    setAutoConnect,
    exit,
  };
}
