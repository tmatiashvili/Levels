import { defineConfig } from "vitest/config";

// Node environment: the relay uses only Web APIs (fetch types, crypto.subtle,
// TextEncoder) that Node 20+ provides, so the Workers pool isn't needed.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});
