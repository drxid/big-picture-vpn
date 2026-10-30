<script setup lang="ts">
/// Shown once, on first launch, and again from the menu. Answers why the app
/// exists and whether it found anything to control, since a person who installed
/// it for one client may not have the other.
import { computed } from "vue";
import type { Provider, Tunnel } from "../composables/useTunnels";
import { t } from "../i18n";

const props = defineProps<{
  tunnels: Tunnel[];
  /// False until the slow inventory is in: a config list that has not arrived
  /// yet must not read as "not found".
  scanned: boolean;
  logos: Record<Provider, string>;
}>();

const configs = computed(
  () => props.tunnels.filter((tunnel) => tunnel.provider === "amneziawg").length,
);
const hasHapp = computed(() =>
  props.tunnels.some((tunnel) => tunnel.provider === "happ"),
);

const clients = computed(() => [
  {
    name: "AmneziaWG",
    logo: props.logos.amneziawg,
    found: configs.value > 0,
    status:
      configs.value > 0
        ? t.value.welcomeConfigs(configs.value)
        : props.scanned
          ? t.value.welcomeMissing
          : t.value.welcomeSearching,
  },
  {
    name: "Happ",
    logo: props.logos.happ,
    found: hasHapp.value,
    status: hasHapp.value
      ? t.value.welcomeInstalled
      : props.scanned
        ? t.value.welcomeMissing
        : t.value.welcomeSearching,
  },
]);

const noClients = computed(
  () => props.scanned && !configs.value && !hasHapp.value,
);
</script>

<template>
  <section class="welcome">
    <h1 class="title">{{ t.welcomeTitle }}</h1>
    <p class="lead">{{ t.welcomeLead }}</p>

    <ul class="clients">
      <li
        v-for="client in clients"
        :key="client.name"
        class="client"
        :class="{ found: client.found }"
      >
        <img class="logo" :src="client.logo" alt="" aria-hidden="true" />
        <span class="name">{{ client.name }}</span>
        <span class="status">{{ client.status }}</span>
      </li>
    </ul>

    <p class="note">{{ noClients ? t.welcomeNoClients : t.welcomeSteam }}</p>
  </section>
</template>

<style scoped>
.welcome {
  max-width: 44rem;
  animation: welcome-in 560ms 60ms ease both;
}

.title {
  margin: 0;
  font-family: var(--font-display);
  font-size: clamp(2.6rem, 5vw, 4.2rem);
  font-weight: 700;
  line-height: 1.06;
  letter-spacing: -0.03em;
}

.lead {
  margin: 1.2rem 0 0;
  font-size: 1.12rem;
  line-height: 1.55;
  color: var(--text-dim);
}

.clients {
  display: flex;
  gap: 2.6rem;
  margin: 2.2rem 0 0;
  padding: 0;
  list-style: none;
}

.client {
  display: grid;
  grid-template-columns: auto auto;
  column-gap: 0.75rem;
  align-items: center;
}

/* Same rule as the tunnel cards: a logo is only in colour when it is live. */
.logo {
  grid-row: span 2;
  height: 2.5rem;
  width: auto;
  filter: grayscale(1);
  opacity: 0.32;
  transition: filter 400ms ease, opacity 400ms ease;
}

.client.found .logo {
  filter: none;
  opacity: 1;
}

.name {
  font-family: var(--font-display);
  font-size: 1.12rem;
  font-weight: 600;
}

.status {
  font-size: 0.84rem;
  color: var(--text-dim);
}

.note {
  margin: 2.2rem 0 0;
  font-size: 0.94rem;
  line-height: 1.5;
  color: var(--text-muted);
}

@keyframes welcome-in {
  from {
    opacity: 0;
    transform: translateY(0.6rem);
  }
}
</style>
