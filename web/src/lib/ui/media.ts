/**
 * Image URLs, and asking the CDN for the size we actually need.
 *
 * GroupMe serves resized copies, and the two media hosts do it differently.
 * Both were measured rather than assumed, because both punish a guess.
 *
 * `i.groupme.com` takes a *suffix*. From a 1024x1024 original:
 *
 *     (none)      1024x1024   207 KB
 *     .large        960x960   122 KB
 *     .preview      200x200    13 KB
 *     .avatar         60x60   2.5 KB
 *
 * `m.groupme.com` instead *replaces* the `.original` segment, and accepts a
 * different, smaller vocabulary. From a 720x1280 upload:
 *
 *     .original              5104 KB
 *     .large                  126 KB
 *     .small                   31 KB
 *
 * The trap, and it is a nasty one: an unrecognised variant does not 404. It
 * silently serves the original. `.preview` and `.avatar` are not valid on
 * `m.groupme.com`, so asking for one there hands back five megabytes to fill a
 * 180-pixel box — which is exactly the bug this function was written to fix,
 * measured at forty times more bytes than needed.
 */

export type ImageVariant = "avatar" | "preview" | "large" | "full";

const I_HOST = "i.groupme.com";
const M_HOST = "m.groupme.com";

export function variant(url: string | null, want: ImageVariant): string | null {
	if (!url) return null;
	if (want === "full") return url;

	if (url.includes(M_HOST)) {
		// Only `large` and `small` exist here. Anything smaller than a preview
		// maps to `small`; everything else to `large`.
		const seg = want === "large" ? "large" : "small";
		return url.includes(".original.") ? url.replace(".original.", `.${seg}.`) : url;
	}

	if (!url.includes(I_HOST)) return url;
	// A variant of a variant is the one case that really does 404.
	if (/\.(avatar|preview|large)$/.test(url)) return url;
	return `${url}.${want}`;
}

/** Pick a variant from the size it will be drawn at, in CSS pixels. */
export function forSize(url: string | null, cssPx: number): string | null {
	// Assume a 2x display. Below 30pt the 60px avatar copy is already enough,
	// and it is a fortieth of the bytes.
	if (cssPx <= 30) return variant(url, "avatar");
	if (cssPx <= 100) return variant(url, "preview");
	if (cssPx <= 480) return variant(url, "large");
	return url;
}

/**
 * Pixel dimensions, read from the URL.
 *
 * Every GroupMe media host puts the size in the path, and each puts it in a
 * different place:
 *
 *     i.groupme.com/486x281.jpeg.6381f1f6...
 *     m.groupme.com/uploads/659c.../3024x4032.original.jpeg
 *     v.groupme.com/117088005/2026-08-31.../7ee0c134.1126x2436r0.mp4
 *
 * So scan every dot-separated piece of every path component rather than
 * assuming a position. Reading only the first component is right for one host
 * and wrong for the other two, which shows up as every photo posted through
 * the newer uploader falling back to a guessed box and drawing cropped.
 *
 * Knowing this before the bytes arrive is what lets the transcript reserve the
 * right space, so an image loading does not shove everything below it down.
 */
export function declaredSize(url: string | null): { width: number; height: number } | null {
	if (!url) return null;
	let path: string;
	try {
		path = new URL(url).pathname;
	} catch {
		return null;
	}

	for (const component of path.split("/")) {
		for (const piece of component.split(".")) {
			// `r0` and anything after it is a rotation flag, not a dimension.
			const m = /^(\d{1,5})x(\d{1,5})(?:r\d+)?$/.exec(piece);
			if (!m) continue;
			const width = Number(m[1]);
			const height = Number(m[2]);
			if (width > 0 && width <= 20000 && height > 0 && height <= 20000) {
				return { width, height };
			}
		}
	}
	return null;
}

/** Fit a declared size into a box, shrinking only. */
export function fitBox(
	size: { width: number; height: number } | null,
	maxWidth: number,
	maxHeight: number,
): { width: number; height: number } {
	if (!size) return { width: Math.min(360, maxWidth), height: 240 };
	const scale = Math.min(maxWidth / size.width, maxHeight / size.height, 1);
	return { width: Math.round(size.width * scale), height: Math.round(size.height * scale) };
}

/**
 * A stable colour for someone with no avatar.
 *
 * Hashed from the id rather than the name, so a nickname change does not
 * repaint somebody a different colour mid-conversation.
 */
export function initialsColor(id: string): string {
	let h = 5381;
	for (let i = 0; i < id.length; i++) h = ((h << 5) + h + id.charCodeAt(i)) | 0;
	const hue = Math.abs(h) % 360;
	return `oklch(0.62 0.13 ${hue})`;
}

export function initials(name: string): string {
	const words = name.trim().split(/\s+/).filter(Boolean);
	if (!words.length) return "?";
	const first = [...(words[0] ?? "")][0] ?? "";
	const last = words.length > 1 ? ([...(words[words.length - 1] ?? "")][0] ?? "") : "";
	return (first + last).toUpperCase();
}
