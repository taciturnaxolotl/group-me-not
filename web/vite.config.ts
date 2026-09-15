import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import tailwindcss from "@tailwindcss/vite";
import { fileURLToPath } from "node:url";

export default defineConfig({
	plugins: [tailwindcss(), svelte()],
	resolve: {
		alias: { $lib: fileURLToPath(new URL("./src/lib", import.meta.url)) },
		// `.svelte.ts` modules are imported without the `.ts`, the way
		// SvelteKit does it, so Vite has to be told to look for it.
		extensions: [".mjs", ".js", ".mts", ".ts", ".jsx", ".tsx", ".json", ".svelte"],
	},
	server: { port: 5273 },
	build: { target: "es2022", sourcemap: true },
});
