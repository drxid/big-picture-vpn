<script setup lang="ts">
/// A single controller button, drawn to match the pad in the user's hands.
///
/// Steam Input reports a DualSense as an Xbox 360 pad, so the face-button
/// scheme cannot be detected reliably and is a user setting. The shapes are
/// drawn rather than typed as text because PlayStation glyphs render
/// inconsistently across fonts, and a wrong glyph on a TV reads as a bug.
import { computed } from "vue";

const props = withDefaults(
  defineProps<{
    button: "a" | "b" | "x" | "y" | "leftright" | "start";
    scheme?: "xbox" | "playstation";
    /// 0..1 -- draws a ring that fills as the button is held.
    progress?: number;
  }>(),
  { scheme: "xbox", progress: 0 },
);

const XBOX_LETTER: Record<string, string> = { a: "A", b: "B", x: "X", y: "Y" };

/// The hold ring sits outside the button face rather than on top of it: over a
/// white disc a ring drawn on the edge is hard to read at TV distance.
const FACE_RADIUS = 14;
const RING_RADIUS = 16.4;
const CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS;

const dashOffset = computed(
  () => CIRCUMFERENCE * (1 - Math.min(1, Math.max(0, props.progress))),
);
</script>

<template>
  <span class="glyph">
    <svg class="ring" viewBox="0 0 36 36" aria-hidden="true">
      <circle class="face" cx="18" cy="18" :r="FACE_RADIUS" />
      <circle
        v-if="progress > 0"
        class="ring-fill"
        cx="18"
        cy="18"
        :r="RING_RADIUS"
        :stroke-dasharray="CIRCUMFERENCE"
        :stroke-dashoffset="dashOffset"
      />
    </svg>

    <svg
      v-if="button === 'leftright'"
      class="mark"
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path d="M5.5 12 L10 8.5 V15.5 Z" />
      <path d="M18.5 12 L14 15.5 V8.5 Z" />
    </svg>

    <!-- Menu / Options: three bars on both Xbox and DualSense, so one shape
         serves either scheme. -->
    <svg
      v-else-if="button === 'start'"
      class="mark stroked"
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path d="M7 8.5 H17 M7 12 H17 M7 15.5 H17" />
    </svg>

    <template v-else-if="scheme === 'playstation'">
      <svg class="mark stroked" viewBox="0 0 24 24" aria-hidden="true">
        <template v-if="button === 'a'">
          <path d="M7.5 7.5 L16.5 16.5 M16.5 7.5 L7.5 16.5" />
        </template>
        <template v-else-if="button === 'b'">
          <circle cx="12" cy="12" r="5" />
        </template>
        <template v-else-if="button === 'x'">
          <rect x="7.2" y="7.2" width="9.6" height="9.6" rx="1.2" />
        </template>
        <template v-else>
          <path d="M12 6.6 L17.4 16.6 H6.6 Z" />
        </template>
      </svg>
    </template>

    <span v-else class="letter">{{ XBOX_LETTER[button] }}</span>
  </span>
</template>

<style scoped>
.glyph {
  position: relative;
  display: inline-grid;
  place-items: center;
  width: 2.15em;
  height: 2.15em;
  flex: none;
  /* The symbol sits on a white face, so it is drawn in the background colour
     rather than the text colour. */
  color: var(--bg);
}

.ring {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  /* Start the fill at 12 o'clock and run clockwise. */
  transform: rotate(-90deg);
  overflow: visible;
}

.face {
  fill: var(--glyph-face, #ffffff);
}

.ring-fill {
  fill: none;
  stroke: var(--accent);
  stroke-width: 2.6;
  stroke-linecap: round;
  /* No transition: the value is driven per frame while the button is held,
     and easing it would lag behind the user's thumb. */
}

.mark {
  position: relative;
  width: 62%;
  height: 62%;
  fill: currentColor;
}

.mark.stroked {
  fill: none;
  stroke: currentColor;
  /* Slightly heavier than a hairline: these shapes are small and sit on a
     bright face, where thin strokes disappear at TV distance. */
  stroke-width: 2.4;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.letter {
  position: relative;
  font-family: var(--font-display);
  font-size: 0.86em;
  font-weight: 700;
  line-height: 1;
  color: currentColor;
}
</style>
