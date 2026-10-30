<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import {
  useTunnels,
  type Provider,
  type TunnelOrder,
} from "./composables/useTunnels";
import amneziawgLogo from "./assets/providers/amneziawg.svg";
import happLogo from "./assets/providers/happ.svg";
import {
  useGamepad,
  type PadButton,
  type PadScheme,
} from "./composables/useGamepad";
import ButtonGlyph from "./components/ButtonGlyph.vue";
import AnimatedText from "./components/AnimatedText.vue";
import OptionsMenu, { type MenuItem } from "./components/OptionsMenu.vue";
import WelcomeScreen from "./components/WelcomeScreen.vue";
import { LANGS, lang, languageName, setLang, t } from "./i18n";

const WELCOMED_KEY = "bpvpn.welcomed";
const firstLaunch = localStorage.getItem(WELCOMED_KEY) === null;
const welcomeOpen = ref(firstLaunch);

function closeWelcome() {
  welcomeOpen.value = false;
  localStorage.setItem(WELCOMED_KEY, "1");
}

const {
  tunnels,
  selected,
  activeTunnel,
  isOn,
  busy,
  error,
  ready,
  scanned,
  pending,
  stopping,
  autoConnect,
  order,
  orders,
  turnOff,
  highlight,
  apply,
  step,
  setAutoConnect,
  setOrder,
  exit,
} = useTunnels({ skipAutoConnect: firstLaunch });

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

// --- options menu ----------------------------------------------------------

const orderLabels = computed<Record<TunnelOrder, string>>(() => ({
  name: t.value.orderName,
  running: t.value.orderRunning,
  amneziawg: "AmneziaWG",
  happ: "Happ",
}));

const menuOpen = ref(false);
const menuIndex = ref(0);

const menuItems = computed<MenuItem[]>(() => [
  {
    id: "order",
    label: t.value.menuOrder,
    value: orderLabels.value[order.value],
  },
  {
    id: "autoConnect",
    label: t.value.menuAutoConnect,
    value: autoConnect.value ? t.value.on : t.value.off,
  },
  {
    id: "scheme",
    label: t.value.menuScheme,
    value: scheme.value === "xbox" ? "Xbox" : "PlayStation",
  },
  {
    id: "language",
    label: t.value.menuLanguage,
    value: languageName(lang.value),
  },
  { id: "about", label: t.value.menuAbout },
  { id: "exit", label: t.value.menuExit },
]);

const menuActionLabel = computed(() => {
  const id = menuItems.value[menuIndex.value].id;
  if (id === "exit") return t.value.actionExit;
  return id === "about" ? t.value.actionOpen : t.value.actionChange;
});

function openMenu() {
  menuIndex.value = 0;
  menuOpen.value = true;
}

function moveMenu(direction: 1 | -1) {
  const count = menuItems.value.length;
  menuIndex.value = (menuIndex.value + direction + count) % count;
}

function changeItem(direction: 1 | -1) {
  switch (menuItems.value[menuIndex.value].id) {
    case "order": {
      const count = orders.value.length;
      const index = orders.value.indexOf(order.value);
      setOrder(orders.value[(index + direction + count) % count]);
      break;
    }
    case "autoConnect":
      setAutoConnect(!autoConnect.value);
      break;
    case "scheme":
      toggleScheme();
      break;
    case "language": {
      const index = LANGS.indexOf(lang.value);
      setLang(LANGS[(index + direction + LANGS.length) % LANGS.length]);
      break;
    }
  }
}

/// A does the same as stepping right, so a row can be worked with one button --
/// except the rows that act rather than hold a setting, which only answer to A:
/// a stick pushed sideways must not be able to close the app.
function confirmItem() {
  const { id } = menuItems.value[menuIndex.value];
  if (id === "exit") {
    void exit();
  } else if (id === "about") {
    menuOpen.value = false;
    welcomeOpen.value = true;
  } else {
    changeItem(1);
  }
}

function pickItem(index: number) {
  menuIndex.value = index;
  confirmItem();
}

function pressInMenu(button: PadButton) {
  switch (button) {
    case "up":
      moveMenu(-1);
      break;
    case "down":
      moveMenu(1);
      break;
    case "left":
      changeItem(-1);
      break;
    case "right":
      changeItem(1);
      break;
    case "a":
      confirmItem();
      break;
    case "b":
    case "start":
      menuOpen.value = false;
      break;
  }
}

function press(button: PadButton) {
  if (welcomeOpen.value) {
    if (button === "a") closeWelcome();
    return;
  }

  // Ahead of the busy check: nothing in the menu touches the connection, so a
  // tunnel still dialling is no reason to ignore it.
  if (menuOpen.value) {
    pressInMenu(button);
    return;
  }
  if (button === "start") {
    openMenu();
    return;
  }
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
  clock.value = new Date().toLocaleTimeString(t.value.htmlLocale, {
    hour: "2-digit",
    minute: "2-digit",
  });
}

watch(lang, tickClock);

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
  if (!ready.value) return t.value.headlineChecking;
  if (busy.value) {
    return pending.value ? t.value.headlineConnecting : t.value.headlineDisconnecting;
  }
  return isOn.value ? t.value.headlineOn : t.value.headlineOff;
});

const subline = computed(() => {
  if (!ready.value) return t.value.sublineChecking;
  if (busy.value) return t.value.sublineBusy;
  if (route.value) return route.value.text;
  return t.value.sublineOff;
});

/// The sentence naming the active tunnel: the app with its logo, then its
/// config. Happ has no config name to offer, only the server chosen inside it,
/// so it stands alone. Its solid H also reads larger than the AmneziaWG line
/// art at the same height, hence the smaller size.
const route = computed(() => {
  const tunnel = activeTunnel.value;
  if (!ready.value || busy.value || !tunnel) return null;
  const logo = logos[tunnel.provider];
  const prefix = t.value.routePrefix;
  if (tunnel.provider === "happ") {
    return {
      text: prefix + tunnel.name,
      logo,
      logoHeight: "0.95em",
      configAt: undefined,
    };
  }
  const app = "AmneziaWG ";
  return {
    text: prefix + app + tunnel.name,
    logo,
    logoHeight: "1.25em",
    configAt: prefix.length + app.length,
  };
});

const primaryLabel = computed(() =>
  selectedIsLive.value ? t.value.actionDisconnect : t.value.actionConnect,
);

const holdLabel = computed(() => {
  if (holdProgress.value > 0) return t.value.actionHold;
  return menuOpen.value ? t.value.actionClose : t.value.actionQuit;
});

/// Drives the ambient colour behind everything. It marks one state and one
/// only -- protected and settled. Checking, connecting and sitting unprotected
/// all leave the screen plain black, which is what keeps the wash meaning
/// something rather than decorating everything.
const mood = computed(() =>
  ready.value && isOn.value && !busy.value ? "on" : "idle",
);

const logos: Record<Provider, string> = { amneziawg: amneziawgLogo, happ: happLogo };

const isDev = import.meta.env.DEV;
</script>

<template>
  <main
    class="screen"
    :class="[`mood-${mood}`, { pointer: pointerVisible, 'menu-open': menuOpen }]"
  >
    <!-- Ambient wash. Purely decorative, hence aria-hidden and pointer-events
         none; it must never sit between the user and a control. -->
    <div class="ambient" aria-hidden="true">
      <span class="blob blob-a"></span>
    </div>

    <!-- A watermark, only while protected. The sentence under the headline says
         which app it is; this only keeps the empty side of the screen company. -->
    <Transition name="mark">
      <img
        v-if="mood === 'on' && activeTunnel && !menuOpen && !welcomeOpen"
        :key="activeTunnel.provider"
        class="active-logo"
        :src="logos[activeTunnel.provider]"
        alt=""
        aria-hidden="true"
      />
    </Transition>

    <header class="topbar">
      <span class="wordmark">Big&nbsp;Picture&nbsp;VPN</span>
      <span class="clock">{{ clock }}</span>
    </header>

    <div class="body">
      <WelcomeScreen
        v-if="welcomeOpen"
        :tunnels="tunnels"
        :scanned="scanned"
        :logos="logos"
      />
      <template v-else>
      <section class="hero">
        <div class="state" :class="{ on: isOn, busy }">
          <span class="beacon" aria-hidden="true"></span>
          <h1 class="headline"><AnimatedText :text="headline" /></h1>
        </div>
        <p class="subline">
          <AnimatedText
            :text="subline"
            :stagger="9"
            :icon="route?.logo"
            :icon-at="t.routePrefix.length"
            :icon-height="route?.logoHeight"
            :bright-from="route?.configAt"
          />
        </p>
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
            disconnecting: tunnel.name === stopping,
          }"
          :style="{ '--delay': `${index * 60}ms` }"
          @click="highlight(tunnel.name)"
        >
          <span class="card-top">
            <span class="card-dot" aria-hidden="true"></span>
            <span class="card-state">{{
              tunnel.name === pending
                ? t.cardConnecting
                : tunnel.name === stopping
                  ? t.cardDisconnecting
                  : tunnel.running
                    ? t.cardRunning
                    : t.cardStopped
            }}</span>
          </span>
          <img class="card-logo" :src="logos[tunnel.provider]" alt="" aria-hidden="true" />
          <span class="card-name">{{ tunnel.name }}</span>
        </button>
        </section>

        <section class="rail" v-else-if="ready">
          <div class="card placeholder">
          <span class="card-name">{{ t.emptyTitle }}</span>
          <span class="card-note">{{ t.emptyNote }}</span>
          </div>
        </section>
      </div>

      <p class="error" v-if="error">{{ error }}</p>
      </template>

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

    <Transition name="menu">
      <OptionsMenu
        v-if="menuOpen"
        :items="menuItems"
        :index="menuIndex"
        @pick="pickItem"
      />
    </Transition>

    <footer class="footbar">
      <div class="settings">
        <button class="setting" v-if="!welcomeOpen" @click="press('start')">
          <ButtonGlyph button="start" :scheme="scheme" />
          <span>{{ t.menu }}</span>
        </button>
        <Transition name="fade">
          <span class="setting nudge" v-if="showHint && !connected">
            {{ t.pressAnyButton }}
          </span>
        </Transition>
      </div>

      <div class="actions">
        <button class="action" v-if="welcomeOpen" @click="press('a')">
          <ButtonGlyph button="a" :scheme="scheme" />
          <span>{{ t.actionStart }}</span>
        </button>
        <template v-else-if="menuOpen">
          <button class="action" @click="press('a')">
            <ButtonGlyph button="a" :scheme="scheme" />
            <span>{{ menuActionLabel }}</span>
          </button>
        </template>
        <template v-else>
          <!-- Always in the layout. The list arrives after the footer has begun
               its entrance, so adding the button then pops it in mid-fade and
               shoves its neighbours aside. -->
          <button
            class="action"
            :class="{ absent: tunnels.length < 2 }"
            :disabled="tunnels.length < 2"
            @click="press('right')"
          >
            <ButtonGlyph button="leftright" :scheme="scheme" />
            <span>{{ t.actionSelect }}</span>
          </button>
          <button class="action" @click="primary()">
            <ButtonGlyph button="a" :scheme="scheme" />
            <span>{{ primaryLabel }}</span>
          </button>
        </template>
        <!-- Held, not clicked, with the mouse too: the confirmation the hold
             provides should not be bypassable just because a mouse is around. -->
        <button
          class="action"
          :class="{ arming: holdProgress > 0 }"
          @mousedown="beginPointerHold"
          @mouseup="endPointerHold"
          @mouseleave="endPointerHold"
          @click="menuOpen && press('b')"
        >
          <ButtonGlyph button="b" :scheme="scheme" :progress="holdProgress" />
          <span>{{ holdLabel }}</span>
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

/* The screen stays visible behind the menu, so the list can be watched
   reordering, but steps back so the eye goes to the panel. */
.body {
  transition: opacity 240ms ease;
}

.menu-open .body {
  opacity: 0.32;
}

.menu-enter-active,
.menu-leave-active {
  transition: opacity 200ms ease, transform 260ms cubic-bezier(0.2, 0.7, 0.2, 1);
}

.menu-enter-from,
.menu-leave-to {
  opacity: 0;
  transform: scale(0.97);
}

/* --- active provider ------------------------------------------------------ */

/* Faint enough to pass behind the card rail, however far the list runs. Colour
   is dropped on purpose: at this opacity it would only read as dirt. */
.active-logo {
  position: absolute;
  top: 50%;
  right: 9rem;
  z-index: -1;
  height: min(58vh, 38rem);
  width: auto;
  transform: translateY(-50%);
  filter: grayscale(1) brightness(1.5);
  opacity: 0.06;
  pointer-events: none;
}

.mark-enter-active {
  transition: opacity 900ms ease, transform 900ms cubic-bezier(0.2, 0.7, 0.2, 1);
}

.mark-leave-active {
  transition: opacity 240ms ease;
}

.mark-enter-from {
  opacity: 0;
  transform: translateY(-50%) scale(0.965);
}

.mark-leave-to {
  opacity: 0;
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

/* Colour on a logo means the same as colour anywhere else here: this one is
   running. Until then it is only a label, so it stays grey and quiet. */
.card-logo {
  position: absolute;
  top: 1.05rem;
  right: 1.2rem;
  height: 1.9rem;
  width: auto;
  filter: grayscale(1);
  opacity: 0.32;
  transition: filter 400ms ease, opacity 400ms ease;
}

.card.current .card-logo {
  opacity: 0.6;
}

.card.live .card-logo {
  filter: none;
  opacity: 1;
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

/* On the contents, not the card: redeclaring the card's own `animation` would
   replay its entrance, the same trap as the connecting border above. */
.card.disconnecting > * {
  animation: breathe 800ms ease-in-out infinite;
}

.card-state {
  position: relative;
  font-size: 0.78rem;
  letter-spacing: 0.04em;
  color: var(--text-faint);
}

.card.live .card-state,
.card.connecting .card-state,
.card.disconnecting .card-state {
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
  transition: opacity 320ms ease;
}

.action.absent {
  opacity: 0;
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
