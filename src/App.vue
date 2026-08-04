<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import { useTunnels } from "./composables/useTunnels";
import {
  useGamepad,
  type PadButton,
  type PadScheme,
} from "./composables/useGamepad";
import ButtonGlyph from "./components/ButtonGlyph.vue";
import AnimatedText from "./components/AnimatedText.vue";

const {
  tunnels,
  selected,
  activeTunnel,
  isOn,
  busy,
  error,
  ready,
  pending,
  autoConnect,
  turnOff,
  highlight,
  apply,
  step,
  setAutoConnect,
  exit,
} = useTunnels();

/// True when the highlighted tunnel is the one carrying traffic. Everything the
/// main button does and says follows from this.
const selectedIsLive = computed(
  () => selected.value !== null && activeTunnel.value?.name === selected.value,
);

/// One button does the whole job: it disconnects the highlighted tunnel if that
/// is the one running, and otherwise connects it -- replacing whatever was
/// running before. Splitting this across two buttons meant the pad had a
/// "connect" and a "toggle" that overlapped, which is one decision too many for
/// a screen operated from a sofa.
async function primary() {
  if (selectedIsLive.value) await turnOff();
  else await apply();
}

const SCHEME_KEY = "bpvpn.padScheme";
const manualScheme = ref<PadScheme | null>(
  localStorage.getItem(SCHEME_KEY) as PadScheme | null,
);

function toggleScheme() {
  manualScheme.value = scheme.value === "xbox" ? "playstation" : "xbox";
  localStorage.setItem(SCHEME_KEY, manualScheme.value);
}

function press(button: PadButton) {
  if (busy.value) return;

  switch (button) {
    case "a":
      void primary();
      break;
    // The tunnel list runs left to right, so it is driven by the horizontal
    // directions -- d-pad or either stick.
    case "left": {
      const name = step(-1);
      if (name) highlight(name);
      break;
    }
    case "right": {
      const name = step(1);
      if (name) highlight(name);
      break;
    }
    case "start":
      setAutoConnect(!autoConnect.value);
      break;
    case "b":
      toggleScheme();
      break;
  }
}

const {
  connected,
  showHint,
  padActivity,
  pads,
  lastRaw,
  holdProgress,
  detectedScheme,
  beginPointerHold,
  endPointerHold,
} = useGamepad({ onPress: press, onHold: () => void exit() });

/// The pad's own name wins only until the user overrides it -- under Steam
/// Input every controller claims to be an Xbox pad, so the override is the
/// only way a DualSense owner gets the right shapes.
const scheme = computed<PadScheme>(
  () => manualScheme.value ?? detectedScheme.value ?? "xbox",
);

// --- pointer visibility ----------------------------------------------------

/// The cursor is meaningless on a TV but essential at a desk, so it follows
/// whichever device was used last: a click brings it back, touching the pad
/// takes it away again.
///
/// A click, not movement -- a mouse nudged on the desk, or one that reports a
/// stray move on its own, would otherwise put a pointer on a screen nobody is
/// driving with a mouse.
const pointerVisible = ref(false);

function showPointer() {
  pointerVisible.value = true;
}

watch(padActivity, () => {
  pointerVisible.value = false;
});

// --- clock -----------------------------------------------------------------

const clock = ref("");
let clockTimer: number | undefined;

function tickClock() {
  clock.value = new Date().toLocaleTimeString("ru-RU", {
    hour: "2-digit",
    minute: "2-digit",
  });
}

onMounted(() => {
  tickClock();
  clockTimer = window.setInterval(tickClock, 10_000);
  window.addEventListener("mousedown", showPointer);
});

onUnmounted(() => {
  if (clockTimer) clearInterval(clockTimer);
  window.removeEventListener("mousedown", showPointer);
});

// --- copy ------------------------------------------------------------------

const headline = computed(() => {
  if (!ready.value) return "Проверяю";
  if (busy.value) return isOn.value ? "Отключаю" : "Подключаю";
  return isOn.value ? "Защищено" : "Без защиты";
});

const subline = computed(() => {
  if (!ready.value) return "Читаю состояние туннелей";
  if (busy.value) return "Это займёт пару секунд";
  if (isOn.value) return `Трафик идёт через ${activeTunnel.value?.name}`;
  return "Трафик идёт напрямую, без туннеля";
});

const primaryLabel = computed(() =>
  selectedIsLive.value ? "Выключить" : "Подключить",
);

/// Drives the ambient colour behind everything. It marks one state and one
/// only -- protected and settled. Checking, connecting and sitting unprotected
/// all leave the screen plain black, which is what keeps the wash meaning
/// something rather than decorating everything.
const mood = computed(() =>
  ready.value && isOn.value && !busy.value ? "on" : "idle",
);

const isDev = import.meta.env.DEV;
</script>

<template>
  <main class="screen" :class="[`mood-${mood}`, { pointer: pointerVisible }]">
    <!-- Ambient wash. Purely decorative, hence aria-hidden and pointer-events
         none; it must never sit between the user and a control. -->
    <div class="ambient" aria-hidden="true">
      <span class="blob blob-a"></span>
    </div>

    <header class="topbar">
      <span class="wordmark">Big&nbsp;Picture&nbsp;VPN</span>
      <span class="clock">{{ clock }}</span>
    </header>

    <div class="body">
      <section class="hero">
        <div class="state" :class="{ on: isOn, busy }">
          <span class="beacon" aria-hidden="true"></span>
          <h1 class="headline"><AnimatedText :text="headline" /></h1>
        </div>
        <p class="subline"><AnimatedText :text="subline" :stagger="9" /></p>
      </section>

      <!-- Fixed-height slot. Without it the hero sits centred while the list is
           still loading and jumps upward the moment tunnels arrive. -->
      <div class="rail-slot">
        <section class="rail" v-if="tunnels.length">
        <button
          v-for="(tunnel, index) in tunnels"
          :key="tunnel.name"
          class="card"
          :class="{
            current: tunnel.name === selected,
            live: tunnel.running,
            connecting: tunnel.name === pending,
          }"
          :style="{ '--delay': `${index * 60}ms` }"
          @click="highlight(tunnel.name)"
        >
          <span class="card-top">
            <span class="card-dot" aria-hidden="true"></span>
            <span class="card-state">{{
              tunnel.name === pending
                ? "Подключаю"
                : tunnel.running
                  ? "Работает"
                  : "Остановлен"
            }}</span>
          </span>
          <span class="card-name">{{ tunnel.name }}</span>
        </button>
        </section>

        <section class="rail" v-else-if="ready">
          <div class="card placeholder">
          <span class="card-name">Туннелей нет</span>
          <span class="card-note">
            Не нашёл ни одного конфига AmneziaWG. Если конфиги есть, значит не
            установлена служебная задача — запусти от администратора:
            scripts\setup-scheduled-task.ps1
          </span>
          </div>
        </section>
      </div>

      <p class="error" v-if="error">{{ error }}</p>

      <section class="diagnostic" v-if="isDev">
        <b>Отладка геймпада</b>
        <p v-if="!pads.length">Gamepad API не видит контроллер.</p>
        <ul v-else>
          <li v-for="pad in pads" :key="pad.index">
            #{{ pad.index }} · {{ pad.id }} · mapping {{ pad.mapping }}
            <template v-if="pad.pressed.length">
              · нажато [{{ pad.pressed.join(", ") }}]
            </template>
          </li>
        </ul>
        <p v-if="lastRaw" class="diagnostic-raw">{{ lastRaw }}</p>
      </section>
    </div>

    <footer class="footbar">
      <div class="settings">
        <button class="setting" @click="setAutoConnect(!autoConnect)">
          <ButtonGlyph button="start" :scheme="scheme" />
          <span>Автозапуск: {{ autoConnect ? "вкл" : "выкл" }}</span>
        </button>
        <button class="setting" @click="toggleScheme">
          <ButtonGlyph button="b" :scheme="scheme" />
          <span>Кнопки: {{ scheme === "xbox" ? "Xbox" : "PlayStation" }}</span>
        </button>
        <Transition name="fade">
          <span class="setting nudge" v-if="showHint && !connected">
            Нажми любую кнопку на геймпаде
          </span>
        </Transition>
      </div>

      <div class="actions">
        <button class="action" v-if="tunnels.length > 1" @click="press('right')">
          <ButtonGlyph button="leftright" :scheme="scheme" />
          <span>Выбрать</span>
        </button>
        <button class="action" @click="primary()">
          <ButtonGlyph button="a" :scheme="scheme" />
          <span>{{ primaryLabel }}</span>
        </button>
        <!-- Held, not clicked, with the mouse too: the confirmation the hold
             provides should not be bypassable just because a mouse is around. -->
        <button
          class="action"
          :class="{ arming: holdProgress > 0 }"
          @mousedown="beginPointerHold"
          @mouseup="endPointerHold"
          @mouseleave="endPointerHold"
        >
          <ButtonGlyph button="y" :scheme="scheme" :progress="holdProgress" />
          <span>{{ holdProgress > 0 ? "Не отпускай" : "Выход" }}</span>
        </button>
      </div>
    </footer>
  </main>
</template>

<style scoped>
.screen {
  position: relative;
  display: grid;
  grid-template-rows: auto 1fr auto;
  height: 100%;
  /* Wide side padding keeps everything clear of TV overscan. */
  padding: 3.2rem 4.4rem 2.6rem;
  gap: 1.6rem;
  isolation: isolate;
}

/* --- ambient background -------------------------------------------------- */

.ambient {
  position: fixed;
  inset: 0;
  z-index: -1;
  overflow: hidden;
  pointer-events: none;
}

.blob {
  position: absolute;
  border-radius: 50%;
  /* Heavy blur plus low opacity: the colour should be felt rather than seen,
     and never compete with the text in front of it. */
  filter: blur(150px);
  opacity: 0.05;
  transition: background 1200ms ease, opacity 1200ms ease;
  will-change: transform;
}

/* One wash only, anchored to the top corner behind the status line. A second
   one in the opposite corner framed the screen and started to read as a
   gradient background rather than as atmosphere. */
.blob-a {
  width: 52vw;
  height: 52vw;
  top: -14vw;
  left: -10vw;
  animation: drift-a 38s ease-in-out infinite;
}

.mood-on .blob-a {
  background: #1f9d55;
}

/* Nothing to signal: fade the wash out entirely rather than tint it grey. */
.mood-idle .blob {
  opacity: 0;
}

@keyframes drift-a {
  0%, 100% { transform: translate3d(0, 0, 0) scale(1); }
  50% { transform: translate3d(6vw, 4vh, 0) scale(1.12); }
}

/* --- top bar ------------------------------------------------------------- */

.topbar {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  animation: rise 500ms ease both;
}

.wordmark {
  font-family: var(--font-display);
  font-size: 0.82rem;
  font-weight: 600;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--text-faint);
}

.clock {
  font-size: 0.82rem;
  color: var(--text-faint);
  font-variant-numeric: tabular-nums;
}

/* --- body ---------------------------------------------------------------- */

.body {
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 2.2rem;
  min-height: 0;
}

.hero {
  animation: rise 560ms 60ms ease both;
}

.state {
  display: flex;
  align-items: center;
  gap: 1.1rem;
}

.headline {
  margin: 0;
  font-family: var(--font-display);
  /* The one loud element on the screen: state has to be legible across a
     room, before any text is actually read. */
  font-size: 4.4rem;
  font-weight: 700;
  letter-spacing: -0.035em;
  line-height: 1;
}

.beacon {
  width: 0.78rem;
  height: 0.78rem;
  border-radius: 50%;
  flex: none;
  background: var(--text-faint);
  /* Same optical correction as the card dots, scaled to the heading. At this
     size the offset is large enough to be obvious if it is wrong either way. */
  margin-top: 0.55rem;
  transition: background 240ms ease, box-shadow 240ms ease;
}

.state.on .beacon {
  background: var(--live);
  box-shadow: 0 0 0 0.34rem color-mix(in srgb, var(--live) 16%, transparent);
  animation: breathe 2.8s ease-in-out infinite;
}

.state.busy .beacon {
  background: var(--accent);
  animation: breathe 900ms ease-in-out infinite;
}

.subline {
  margin: 0.9rem 0 0;
  /* Held to a comfortable measure: a line running the full width of a TV is
     tiring to read from a sofa. */
  max-width: 46ch;
  font-size: 1.06rem;
  color: var(--text-dim);
}

/* --- tunnel rail --------------------------------------------------------- */

/* Reserves the list's height from the first frame. The height matches a card,
   so nothing shifts when the tunnels finally arrive -- the list fades in where
   the empty space already was. */
.rail-slot {
  min-height: 8.6rem;
  display: flex;
  align-items: flex-start;
}

.rail {
  display: flex;
  gap: 0.9rem;
  align-items: stretch;
  animation: rise 600ms 140ms ease both;
}

.card {
  position: relative;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  gap: 1.6rem;
  min-width: 15rem;
  padding: 1.15rem 1.3rem;
  text-align: left;
  background: var(--surface);
  /* Transparent rather than absent: the box keeps its size, so nothing shifts
     when the highlight arrives. */
  border: 1.5px solid transparent;
  border-radius: 0.95rem;
  animation: rise 500ms ease both;
  animation-delay: var(--delay, 0ms);
  transition: background 200ms ease, border-color 200ms ease,
    transform 200ms ease;
}

/* Grey, not amber. The highlight only means "the stick is pointing here", and
   a coloured frame at this size claims more attention than that deserves --
   colour on this screen is reserved for state, not for the cursor. */
.card.current {
  border-color: var(--border-strong);
  background: var(--surface-raised);
  transform: translateY(-2px);
}

/* The card being connected is the only insistent thing on the screen: a light
   travels around its perimeter, with a blurred copy behind it for the glow.
   Both layers share one rotating angle so they stay in step. */
@property --angle {
  syntax: "<angle>";
  initial-value: 0deg;
  inherits: false;
}

/* The rotation lives on the pseudo-elements, not the card. Redeclaring the
   card's own `animation` would restart its entrance animation the moment
   connecting begins, making it blink out and back in. */
.card.connecting {
  border-color: transparent;
}

/* The travelling border itself. Painted over the whole box, then masked down
   to the 1.5px frame. */
.card.connecting::before {
  content: "";
  position: absolute;
  inset: -1.5px;
  border-radius: inherit;
  padding: 1.5px;
  background: conic-gradient(
    from var(--angle),
    transparent 0deg,
    color-mix(in srgb, var(--accent) 35%, transparent) 40deg,
    var(--accent) 70deg,
    #fff0cc 84deg,
    var(--accent) 98deg,
    color-mix(in srgb, var(--accent) 35%, transparent) 128deg,
    transparent 190deg,
    transparent 360deg
  );
  -webkit-mask:
    linear-gradient(#000 0 0) content-box,
    linear-gradient(#000 0 0);
  -webkit-mask-composite: xor;
  mask:
    linear-gradient(#000 0 0) content-box,
    linear-gradient(#000 0 0);
  mask-composite: exclude;
  pointer-events: none;
  /* The light bleeds off the line itself rather than from a panel behind the
     card, which is what keeps the card's own surface untouched. */
  filter: drop-shadow(0 0 6px color-mix(in srgb, var(--accent) 70%, transparent));
  animation: orbit 3s linear infinite;
}

/* A blurred copy of the sweep, offset outward, so the halo hangs around the
   block. Masked to a ring for the same reason as the border: an unmasked blur
   spills into the middle of the card and washes out the tunnel name. */
.card.connecting::after {
  content: "";
  position: absolute;
  inset: -8px;
  border-radius: 1.25rem;
  padding: 10px;
  background: conic-gradient(
    from var(--angle),
    transparent 0deg,
    color-mix(in srgb, var(--accent) 40%, transparent) 70deg,
    var(--accent) 90deg,
    color-mix(in srgb, var(--accent) 40%, transparent) 110deg,
    transparent 185deg,
    transparent 360deg
  );
  -webkit-mask:
    linear-gradient(#000 0 0) content-box,
    linear-gradient(#000 0 0);
  -webkit-mask-composite: xor;
  mask:
    linear-gradient(#000 0 0) content-box,
    linear-gradient(#000 0 0);
  mask-composite: exclude;
  filter: blur(7px);
  opacity: 0.5;
  pointer-events: none;
  animation: orbit 3s linear infinite;
}

.card:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 3px;
}

.card-top {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.card-dot {
  width: 0.42rem;
  height: 0.42rem;
  border-radius: 50%;
  background: var(--text-faint);
  flex: none;
  /* Optical, not geometric. Centring the boxes leaves the dot sitting above
     the letters, because the line box reserves room for ascenders and
     descenders that "Работает" and "Остановлен" barely use. */
  margin-top: 0.16rem;
  transition: background 200ms ease;
}

.card.live .card-dot {
  background: var(--live);
}

.card.connecting .card-dot {
  background: var(--accent);
  animation: breathe 1.8s ease-in-out infinite;
}

.card-state {
  position: relative;
  font-size: 0.78rem;
  letter-spacing: 0.04em;
  color: var(--text-faint);
}

.card.live .card-state,
.card.connecting .card-state {
  color: var(--text-dim);
}

.card-name {
  position: relative;
  font-family: var(--font-display);
  font-size: 1.5rem;
  font-weight: 600;
  letter-spacing: -0.015em;
}

.card.placeholder {
  min-width: 28rem;
  gap: 0.6rem;
}

.card-note {
  font-size: 0.82rem;
  line-height: 1.5;
  color: var(--text-faint);
}

/* --- error --------------------------------------------------------------- */

.error {
  margin: 0;
  padding: 0.85rem 1.1rem;
  font-size: 0.9rem;
  line-height: 1.5;
  color: var(--danger);
  background: color-mix(in srgb, var(--danger) 9%, transparent);
  border: 1.5px solid color-mix(in srgb, var(--danger) 26%, transparent);
  border-radius: 0.75rem;
}

/* --- dev-only diagnostic ------------------------------------------------- */

.diagnostic {
  padding: 0.8rem 1rem;
  font-size: 0.72rem;
  line-height: 1.55;
  color: var(--text-dim);
  border: 1px dashed var(--border-strong);
  border-radius: 0.7rem;
}

.diagnostic ul {
  margin: 0.4rem 0 0;
  padding-left: 1.1rem;
}

.diagnostic p {
  margin: 0.4rem 0 0;
}

.diagnostic-raw {
  color: var(--accent);
}

/* --- footer -------------------------------------------------------------- */

.footbar {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 2rem;
  animation: rise 640ms 220ms ease both;
}

.settings {
  display: flex;
  align-items: center;
  gap: 1.4rem;
  font-size: 0.84rem;
}

.setting {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0;
  background: none;
  border: none;
  /* Secondary controls: grey rather than white, but bright enough to read as
     available rather than disabled. */
  color: var(--text-muted);
  transition: color 180ms ease;
}

.settings :deep(.glyph) {
  --glyph-face: var(--glyph-muted);
  color: var(--bg);
  width: 1.8em;
  height: 1.8em;
}

.setting:hover,
.setting:focus-visible {
  color: var(--text);
  outline: none;
}

.setting:hover :deep(.glyph) {
  --glyph-face: #ffffff;
}

.setting.nudge {
  color: var(--accent);
  cursor: default;
}

/* Actions sit bottom-right, where a console interface puts them. */
.actions {
  display: flex;
  align-items: center;
  gap: 1.7rem;
  font-size: 0.94rem;
}

.action {
  display: flex;
  align-items: center;
  gap: 0.62rem;
  padding: 0;
  background: none;
  border: none;
  color: var(--text);
}

.action:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 6px;
  border-radius: 0.5rem;
}

.action.arming {
  color: var(--accent);
}

/* --- motion -------------------------------------------------------------- */

.fade-enter-active,
.fade-leave-active {
  transition: opacity 400ms ease;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

@keyframes rise {
  from {
    opacity: 0;
    transform: translateY(0.6rem);
  }
  to {
    opacity: 1;
    transform: translateY(0);
  }
}

@keyframes breathe {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.55;
  }
}

/* Drives both the border and its glow. Linear, so the light moves at a
   constant pace rather than easing at the corners. */
@keyframes orbit {
  from {
    --angle: 0deg;
  }
  to {
    --angle: 360deg;
  }
}
</style>
