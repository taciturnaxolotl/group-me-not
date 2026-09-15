/**
 * Appearance.
 *
 * Three settings, not two: dark, light, and following the system. "System" has
 * to be a real stored value rather than the absence of a choice, because
 * otherwise there is no way to go back to it once someone has picked a side.
 *
 * The chosen theme is applied by an inline script in `index.html` before the
 * first paint. Doing it here instead would mean one frame of the wrong colours
 * on every reload, which is the flash everybody recognises and nobody likes.
 */

export type ThemePref = "system" | "light" | "dark";

const KEY = "gmn.settings";

interface Settings {
	theme: ThemePref;
}

function read(): Settings {
	try {
		const raw = JSON.parse(localStorage.getItem(KEY) ?? "{}") as Partial<Settings>;
		return { theme: raw.theme ?? "system" };
	} catch {
		return { theme: "system" };
	}
}

export class Appearance {
	pref = $state<ThemePref>(read().theme);

	constructor() {
		// Following the system means following it as it changes, not just as
		// it was at startup.
		const media = window.matchMedia("(prefers-color-scheme: dark)");
		media.addEventListener("change", () => {
			if (this.pref === "system") this.#apply();
		});
		this.#apply();
	}

	/** Cycle in the order someone would expect from a single button. */
	next(): void {
		this.pref = this.pref === "system" ? "light" : this.pref === "light" ? "dark" : "system";
		localStorage.setItem(KEY, JSON.stringify({ theme: this.pref }));
		this.#apply();
	}

	get resolved(): "light" | "dark" {
		if (this.pref !== "system") return this.pref;
		return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
	}

	get label(): string {
		return this.pref === "system" ? "System theme" : this.pref === "dark" ? "Dark" : "Light";
	}

	get glyph(): string {
		return this.pref === "system" ? "◐" : this.pref === "dark" ? "●" : "○";
	}

	#apply(): void {
		document.documentElement.dataset.theme = this.resolved;
	}
}
