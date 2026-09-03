import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// The shell is built as a library, not an app: index.html is hand-written and
// staged by rake, so vite only has to emit one predictable pair of files
// (dist/main.js and dist/style.css) for stage_page! to copy next to it. A normal
// app build would emit its own index.html and hash the asset names, which the
// static page could not reference.
export default defineConfig(({ mode }) => ({
  plugins: [react(), tailwindcss()],
  // Library mode does not substitute process.env.NODE_ENV the way an app build
  // does, so React would resolve to its development build: three times the size,
  // with the dev-only warnings and checks still running in the browser. Not
  // under vitest, where the production build has no act() for the test renderer.
  define: mode === "test" ? {} : { "process.env.NODE_ENV": JSON.stringify("production") },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    cssCodeSplit: false,
    lib: {
      entry: "src/main.tsx",
      formats: ["es"],
      fileName: () => "main.js",
      cssFileName: "style", // otherwise the package name becomes the file name
    },
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["src/test-setup.ts"],
    include: ["src/**/*.test.{ts,tsx}"],
  },
}));
