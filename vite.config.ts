import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

// Tauri expects a fixed port and fails if it is taken, rather than silently
// serving the app somewhere the webview is not looking.
export default defineConfig({
  plugins: [vue()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: {
      // Rust sources are rebuilt by cargo, not by vite.
      ignored: ["**/src-tauri/**"],
    },
  },
});
