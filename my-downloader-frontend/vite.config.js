import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      // Proxy API calls to backend during dev so no CORS issues
      "/api": {
        target: "http://localhost:3000",
        changeOrigin: true,
      },
      "/files": {
        target: "http://localhost:3000",
        changeOrigin: true,
      },
    },
  },
});