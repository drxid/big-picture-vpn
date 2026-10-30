import { onMounted, onUnmounted, ref } from "vue";

/// Logical inputs the UI reacts to, so gamepad and keyboard share handlers.
export type PadButton =
  | "a"
  | "b"
  | "x"
  | "y"
  | "up"
  | "down"
  | "left"
  | "right"
  | "start"
  | "back";

export type PadScheme = "xbox" | "playstation";

/// Indices from the W3C "standard" gamepad mapping. Steam Input normalises
/// both Xbox pads and DualSense to this layout, so one table covers every
/// controller the app supports.
const BUTTON_MAP: Record<number, PadButton> = {
  0: "a",
  1: "b",
  2: "x",
  3: "y",
  8: "back",
  9: "start",
  12: "up",
  13: "down",
  14: "left",
  15: "right",
};

/// B does two jobs: a tap closes the menu, a hold exits, and exiting has to be
/// deliberate. So its tap is delivered on release, once it is known not to have
/// been a hold -- delivered on press, a hold would close the menu on the way.
const HOLD_BUTTON: PadButton = "b";
const HOLD_INDEX = 1;
const HOLD_MS = 2000;

/// Stick deflection that counts as a press, and the point it has to fall back
/// below before it can fire again -- without the gap, a stick resting near the
/// threshold machine-guns the menu.
const AXIS_ON = 0.6;
const AXIS_OFF = 0.35;

/// The tunnel list is horizontal and the options menu vertical, so both sticks
/// report both directions: 0 and 1 are the left stick, 2 and 3 the right one.
const AXES: { index: number; negative: PadButton; positive: PadButton }[] = [
  { index: 0, negative: "left", positive: "right" },
  { index: 1, negative: "up", positive: "down" },
  { index: 2, negative: "left", positive: "right" },
  { index: 3, negative: "up", positive: "down" },
];

/// How long to wait before suggesting the user press something. Shown
/// immediately it reads as an error message on a perfectly working app; the
/// pad is simply invisible to the page until its first button press.
const HINT_DELAY_MS = 10_000;

/// What the Gamepad API reports. Kept for the dev-only diagnostic overlay,
/// which is how the Steam Input behaviour was originally pinned down.
export interface PadInfo {
  index: number;
  id: string;
  mapping: string;
  buttons: number;
  axes: number;
  pressed: number[];
}

/// Guess the face-button scheme from the device name. Checked Xbox-first
/// because "Xbox Wireless Controller" also contains "wireless controller",
/// which some DualShock drivers report as their whole name.
function detectScheme(id: string): PadScheme | null {
  const name = id.toLowerCase();
  if (/xbox|xinput|045e/.test(name)) return "xbox";
  if (/dualsense|dualshock|playstation|sony|054c/.test(name)) return "playstation";
  return null;
}

export function useGamepad(handlers: {
  onPress: (button: PadButton) => void;
  onHold: () => void;
}) {
  /// False until a pad reports in. Chromium hides gamepads from a page until
  /// one of their buttons is pressed, so this starts false even with a
  /// controller connected.
  const connected = ref(false);

  /// Only true once the pad has stayed silent long enough that a nudge is
  /// warranted.
  const showHint = ref(false);

  /// Bumped on any pad input. The UI watches it to hide the mouse cursor.
  const padActivity = ref(0);

  /// 0..1 while the exit button is held, reset the moment it is released.
  const holdProgress = ref(0);

  /// Null when the pad's name says nothing useful -- which is the normal case
  /// under Steam Input, where a DualSense arrives as an Xbox 360 pad.
  const detectedScheme = ref<PadScheme | null>(null);

  const pads = ref<PadInfo[]>([]);
  const lastRaw = ref<string>("");
  let lastSnapshot = 0;

  let frame = 0;
  let hintTimer: number | undefined;
  const held = new Set<string>();

  let holdStart: number | null = null;
  let holdFired = false;
  let keyboardHold = false;
  let pointerHold = false;

  function noteActivity() {
    padActivity.value = performance.now();
    showHint.value = false;
  }

  function edge(key: string, isDown: boolean, button: PadButton) {
    if (isDown) {
      if (!held.has(key)) {
        held.add(key);
        noteActivity();
        if (button !== HOLD_BUTTON) handlers.onPress(button);
      }
    } else if (held.delete(key) && button === HOLD_BUTTON && !holdFired) {
      handlers.onPress(button);
    }
  }

  function axis(
    padIndex: number,
    axisIndex: number,
    value: number,
    negative: PadButton,
    positive: PadButton,
  ) {
    const negKey = `${padIndex}:${axisIndex}:-`;
    const posKey = `${padIndex}:${axisIndex}:+`;

    if (value <= -AXIS_ON) edge(negKey, true, negative);
    else if (value > -AXIS_OFF) held.delete(negKey);

    if (value >= AXIS_ON) edge(posKey, true, positive);
    else if (value < AXIS_OFF) held.delete(posKey);
  }

  function poll() {
    const live = navigator.getGamepads ? navigator.getGamepads() : [];
    let any = false;
    let exitHeld = keyboardHold || pointerHold;
    let scheme: PadScheme | null = null;
    const snapshot: PadInfo[] = [];

    for (const pad of live) {
      if (!pad) continue;
      any = true;
      scheme = scheme ?? detectScheme(pad.id);

      const pressedIndices: number[] = [];
      pad.buttons.forEach((button, index) => {
        if (button.pressed) pressedIndices.push(index);
        const name = BUTTON_MAP[index];
        if (name) edge(`${pad.index}:${name}`, button.pressed, name);
      });

      if (pad.buttons[HOLD_INDEX]?.pressed) {
        exitHeld = true;
        noteActivity();
      }
      if (pressedIndices.length) {
        lastRaw.value = `pad ${pad.index}: кнопки [${pressedIndices.join(", ")}]`;
      }

      for (const { index, negative, positive } of AXES) {
        axis(pad.index, index, pad.axes[index] ?? 0, negative, positive);
      }

      snapshot.push({
        index: pad.index,
        id: pad.id,
        mapping: pad.mapping || "(нет)",
        buttons: pad.buttons.length,
        axes: pad.axes.length,
        pressed: pressedIndices,
      });
    }

    const now = performance.now();

    if (exitHeld) {
      if (holdStart === null) {
        holdStart = now;
        holdFired = false;
      }
      const elapsed = now - holdStart;
      holdProgress.value = Math.min(1, elapsed / HOLD_MS);
      if (!holdFired && elapsed >= HOLD_MS) {
        holdFired = true;
        handlers.onHold();
      }
    } else if (holdStart !== null || holdProgress.value !== 0) {
      holdStart = null;
      holdFired = false;
      holdProgress.value = 0;
    }

    detectedScheme.value = scheme;
    if (any && !connected.value) showHint.value = false;
    connected.value = any;

    if (now - lastSnapshot > 200) {
      lastSnapshot = now;
      pads.value = snapshot;
    }

    frame = requestAnimationFrame(poll);
  }

  /// The keyboard mirrors the pad so the app stays usable at a desk. Escape
  /// mirrors the exit button in full: a tap closes the menu, a hold exits --
  /// otherwise there would be a way out that skips the confirmation the hold
  /// exists to provide.
  const KEY_MAP: Record<string, PadButton> = {
    Enter: "a",
    " ": "a",
    ArrowLeft: "left",
    ArrowRight: "right",
    ArrowUp: "up",
    ArrowDown: "down",
    Backspace: "b",
    // The options menu. Both layouts of the same physical key, as below.
    m: "start",
    M: "start",
    ь: "start",
    Ь: "start",
    // Connect the highlighted tunnel. Both layouts of the same physical key,
    // since this machine is used with a Russian keyboard as often as a Latin one.
    x: "x",
    X: "x",
    ч: "x",
    Ч: "x",
  };

  function onKeyDown(event: KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault();
      keyboardHold = true;
      return;
    }
    if (event.repeat) return;
    const button = KEY_MAP[event.key];
    if (button) {
      event.preventDefault();
      handlers.onPress(button);
    }
  }

  function onKeyUp(event: KeyboardEvent) {
    if (event.key !== "Escape" || !keyboardHold) return;
    keyboardHold = false;
    if (!holdFired) handlers.onPress(HOLD_BUTTON);
  }

  /// Losing focus while holding would otherwise freeze the ring part-filled.
  function onBlur() {
    keyboardHold = false;
    pointerHold = false;
    held.clear();
  }

  function onConnect(event: GamepadEvent) {
    lastRaw.value = `подключён: ${event.gamepad.id}`;
    showHint.value = false;
  }

  function onDisconnect(event: GamepadEvent) {
    lastRaw.value = `отключён: ${event.gamepad.id}`;
  }

  /// Lets the exit button be held with a mouse as well as a thumb.
  function beginPointerHold() {
    pointerHold = true;
  }

  function endPointerHold() {
    pointerHold = false;
  }

  onMounted(() => {
    frame = requestAnimationFrame(poll);
    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("keyup", onKeyUp);
    window.addEventListener("blur", onBlur);
    window.addEventListener("gamepadconnected", onConnect);
    window.addEventListener("gamepaddisconnected", onDisconnect);

    hintTimer = window.setTimeout(() => {
      if (!connected.value) showHint.value = true;
    }, HINT_DELAY_MS);
  });

  onUnmounted(() => {
    cancelAnimationFrame(frame);
    if (hintTimer) clearTimeout(hintTimer);
    window.removeEventListener("keydown", onKeyDown);
    window.removeEventListener("keyup", onKeyUp);
    window.removeEventListener("blur", onBlur);
    window.removeEventListener("gamepadconnected", onConnect);
    window.removeEventListener("gamepaddisconnected", onDisconnect);
  });

  return {
    connected,
    showHint,
    padActivity,
    pads,
    lastRaw,
    holdProgress,
    detectedScheme,
    beginPointerHold,
    endPointerHold,
  };
}
