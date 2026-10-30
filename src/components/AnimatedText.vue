<script setup lang="ts">
/// Text that changes letter by letter rather than all at once.
///
/// The status line is the largest thing on screen, so swapping it in one frame
/// reads as a glitch. Staggering the letters turns the change into a small
/// event, which is also what makes "Подключаю" feel like something in progress.
import { computed } from "vue";

const props = withDefaults(
  defineProps<{
    text: string;
    /// Per-character delay. Long lines need a smaller step, or the tail of the
    /// sentence is still arriving seconds after the head.
    stagger?: number;
    /// A logo set into the line as one more character, placed before the
    /// character at `iconAt`, so it arrives and leaves with the letters.
    icon?: string;
    iconAt?: number;
    iconHeight?: string;
    /// Characters from here on are drawn in the full text colour.
    brightFrom?: number;
  }>(),
  { stagger: 32, iconHeight: "1.25em" },
);

/// Split into characters, keeping spaces as their own cells so the stagger
/// timing stays even across words.
const chars = computed(() => Array.from(props.text));

const CHAR_IN_MS = 460;
const CHAR_OUT_MS = 260;
const LEAVE_STEP_RATIO = 0.55;

/// Vue measures a transition from the root element, and here only the child
/// characters are animated -- so it finds no duration, ends the transition on
/// the next frame and cuts the stagger off before it starts. These tell it how
/// long the whole cascade actually runs.
const enterDuration = computed(
  () => chars.value.length * props.stagger + CHAR_IN_MS,
);
const leaveDuration = computed(
  () => chars.value.length * props.stagger * LEAVE_STEP_RATIO + CHAR_OUT_MS,
);
</script>

<template>
  <Transition
    name="stagger"
    mode="out-in"
    :duration="{ enter: enterDuration, leave: leaveDuration }"
  >
    <span
      class="word"
      :key="text"
      :aria-label="text"
      :style="{ '--step': `${stagger}ms` }"
    >
      <template v-for="(char, index) in chars" :key="`${index}-${char}`">
        <img
          v-if="icon && index === iconAt"
          class="char icon"
          :src="icon"
          :style="{ '--i': index, height: iconHeight }"
          alt=""
          aria-hidden="true"
        />
        <span
          class="char"
          :class="{ bright: brightFrom !== undefined && index >= brightFrom }"
          :style="{ '--i': index }"
          aria-hidden="true"
          >{{ char === " " ? " " : char }}</span
        >
      </template>
    </span>
  </Transition>
</template>

<style scoped>
.word {
  display: inline-flex;
  align-items: center;
  /* Letters are laid out individually, so the browser cannot kern across them;
     the negative tracking on the heading compensates. */
  white-space: pre;
}

.char {
  display: inline-block;
  will-change: transform, opacity, filter;
}

.bright {
  color: var(--text);
}

/* Centring the box leaves a logo sitting high: capitals are centred below the
   middle of the line box, which also reserves room for descenders. `top`, not
   `transform`, because the letter animation owns that. */
.icon {
  position: relative;
  top: 0.05em;
  width: auto;
  margin-right: 0.35em;
}

/* Leaving: letters fall away front to back, quickly. */
.stagger-leave-active .char {
  animation: char-out 260ms cubic-bezier(0.4, 0, 1, 1) both;
  animation-delay: calc(var(--i) * var(--step) * 0.55);
}

/* Arriving: letters rise into place, slightly slower and with a little
   overshoot, so the new word lands rather than appears. */
.stagger-enter-active .char {
  animation: char-in 460ms cubic-bezier(0.16, 1, 0.3, 1) both;
  animation-delay: calc(var(--i) * var(--step));
}

@keyframes char-out {
  to {
    opacity: 0;
    transform: translateY(-0.22em) scale(0.94);
    filter: blur(4px);
  }
}

@keyframes char-in {
  from {
    opacity: 0;
    transform: translateY(0.3em) scale(0.96);
    filter: blur(6px);
  }
  to {
    opacity: 1;
    transform: translateY(0) scale(1);
    filter: blur(0);
  }
}

@media (prefers-reduced-motion: reduce) {
  .stagger-enter-active .char,
  .stagger-leave-active .char {
    animation: none;
  }
}
</style>
