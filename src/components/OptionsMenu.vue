<script lang="ts">
export interface MenuItem {
  id: string;
  label: string;
  /// Absent on rows that do something rather than hold a setting.
  value?: string;
}
</script>

<script setup lang="ts">
/// The options panel. Holds no state of its own: which row is current and what
/// a press does both live with the input handling in App.vue, so the pad, the
/// keyboard and the mouse all go through one path.
import { t } from "../i18n";

defineProps<{
  items: MenuItem[];
  index: number;
}>();

defineEmits<{
  pick: [index: number];
}>();
</script>

<template>
  <aside class="menu" :aria-label="t.menu">
    <h2 class="title">{{ t.menu }}</h2>
    <button
      v-for="(item, i) in items"
      :key="item.id"
      class="row"
      :class="{ current: i === index, action: item.value === undefined }"
      @click="$emit('pick', i)"
    >
      <span class="label">{{ item.label }}</span>
      <span class="value" v-if="item.value !== undefined">
        <svg class="chevron" viewBox="0 0 8 14" aria-hidden="true">
          <path d="M6.5 1.5 1.5 7l5 5.5" />
        </svg>
        <span>{{ item.value }}</span>
        <svg class="chevron" viewBox="0 0 8 14" aria-hidden="true">
          <path d="M1.5 1.5 6.5 7l-5 5.5" />
        </svg>
      </span>
    </button>
  </aside>
</template>

<style scoped>
/* Centred on the whole screen. Margins rather than a transform, because the
   open and close transition owns `transform`. */
.menu {
  position: absolute;
  inset: 0;
  z-index: 2;
  height: fit-content;
  margin: auto;
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  width: min(36rem, 46vw);
  padding: 1.6rem 1.3rem 1.3rem;
  background: var(--surface-raised);
  border: 1.5px solid var(--border);
  border-radius: 0.95rem;
}

.title {
  margin: 0 0 1rem 1rem;
  font-family: var(--font-display);
  font-size: 1.9rem;
  font-weight: 700;
  letter-spacing: -0.01em;
  color: var(--text);
}

.row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1.5rem;
  min-height: 3.5rem;
  padding: 0 1rem;
  font-size: 1.12rem;
  text-align: left;
  color: var(--text-muted);
  background: transparent;
  /* Same cursor as the tunnel cards: grey, because it only says where the
     stick is pointing. */
  border: 1.5px solid transparent;
  border-radius: 0.7rem;
  transition: background 160ms ease, border-color 160ms ease, color 160ms ease;
}

.row.current {
  color: var(--text);
  background: var(--surface);
  border-color: var(--border-strong);
}

/* Set apart from the settings: these act rather than hold a value. */
.row:not(.action) + .row.action {
  margin-top: 1.4rem;
}

.row:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

.value {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  font-weight: 600;
  color: var(--text);
}

/* Only the current row answers to left and right, so only it shows arrows.
   Hidden, not removed, or every value would shift sideways as the cursor moves. */
.chevron {
  width: 0.5rem;
  height: 0.875rem;
  fill: none;
  stroke: var(--text-dim);
  stroke-width: 1.6;
  stroke-linecap: round;
  stroke-linejoin: round;
  visibility: hidden;
}

.row.current .chevron {
  visibility: visible;
}
</style>
