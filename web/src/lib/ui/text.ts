import type { Mention } from "../model/types";

/**
 * Turning message text into things a renderer can draw.
 *
 * GroupMe's wire format carries no markup at all. There is no bold, no italic,
 * nothing to escape. "Formatting" is exactly three things: links, mentions,
 * and the convention that a message of nothing but emoji is drawn large.
 * Anything richer would be invented, and inventing a wire format is how
 * clients start disagreeing with each other about what a message says.
 */

export type Segment =
	| { kind: "text"; text: string }
	| { kind: "link"; text: string; href: string }
	| { kind: "mention"; text: string; userId: string };

/**
 * Link detection.
 *
 * Deliberately conservative. It matches an explicit scheme or a bare `www.`
 * and nothing else, because the alternative — treating anything with a dot in
 * it as a link — turns "see you at 3.30" and "node.js" into hyperlinks, and a
 * false positive here is a link somebody clicks by accident.
 *
 * The trailing-punctuation trim matters more than it looks: people end
 * sentences with links, and swallowing the full stop produces a 404.
 */
const LINK_RE = /\b(?:https?:\/\/|www\.)[^\s<>[\]{}|\\^`]+/gi;

const TRAILING_PUNCT = /[.,;:!?)\]}'"]+$/;

export function parseSegments(text: string, mentions: Mention[]): Segment[] {
	if (!text) return [];

	// Mentions come first because their offsets are absolute positions in the
	// original string. Splitting on links first would invalidate every offset
	// after the first link.
	const marks: { start: number; end: number; seg: Segment }[] = [];

	for (const m of mentions) {
		const slice = text.slice(m.start, m.start + m.length);
		if (!slice) continue;
		marks.push({
			start: m.start,
			end: m.start + m.length,
			seg: { kind: "mention", text: slice, userId: m.userId },
		});
	}

	LINK_RE.lastIndex = 0;
	for (const match of text.matchAll(LINK_RE)) {
		const start = match.index;
		let raw = match[0];
		const trimmed = raw.replace(TRAILING_PUNCT, "");
		raw = trimmed || raw;
		const end = start + raw.length;
		// A link inside a mention's span is part of somebody's display name,
		// not a link. The mention wins.
		if (marks.some((k) => start < k.end && end > k.start)) continue;
		marks.push({
			start,
			end,
			seg: { kind: "link", text: raw, href: raw.startsWith("www.") ? `https://${raw}` : raw },
		});
	}

	marks.sort((a, b) => a.start - b.start);

	const out: Segment[] = [];
	let cursor = 0;
	for (const mark of marks) {
		if (mark.start < cursor) continue;
		if (mark.start > cursor) out.push({ kind: "text", text: text.slice(cursor, mark.start) });
		out.push(mark.seg);
		cursor = mark.end;
	}
	if (cursor < text.length) out.push({ kind: "text", text: text.slice(cursor) });
	return out;
}

/**
 * How many emoji, if the message is nothing but emoji.
 *
 * Returns 0 for anything else. Counted in grapheme clusters so that a family
 * with four people and three skin tones counts as one character rather than
 * eleven, which is what `.length` would say.
 *
 * The cap of eight is a judgement rather than a rule: one emoji is a gesture
 * and should land like one, eight are closer to a sentence and have to fit on
 * a line. Past that it is a wall and gets ordinary treatment.
 */
export function emojiOnlyCount(text: string): number {
	const trimmed = text.trim();
	if (!trimmed) return 0;

	const segmenter = graphemes();
	let count = 0;
	for (const { segment } of segmenter.segment(trimmed)) {
		if (!segment.trim()) continue;
		if (!isEmojiCluster(segment)) return 0;
		count++;
		if (count > 8) return 0;
	}
	return count;
}

let _segmenter: Intl.Segmenter | null = null;
function graphemes(): Intl.Segmenter {
	_segmenter ??= new Intl.Segmenter("und", { granularity: "grapheme" });
	return _segmenter;
}

function isEmojiCluster(cluster: string): boolean {
	for (const ch of cluster) {
		const code = ch.codePointAt(0) ?? 0;
		// Zero-width joiner, variation selector and skin-tone modifiers are
		// part of a cluster rather than characters in their own right.
		if (code === 0x200d || code === 0xfe0f || (code >= 0x1f3fb && code <= 0x1f3ff)) continue;
		if (/\p{Extended_Pictographic}/u.test(ch)) continue;
		// Regional indicators, which is how flags are built.
		if (code >= 0x1f1e6 && code <= 0x1f1ff) continue;
		// The replacement character, which is what a GroupMe powerup sticker
		// leaves behind in `text` for clients that cannot draw it. A message
		// that is one sticker should read as one sticker.
		if (code === 0xfffd) continue;
		return false;
	}
	return true;
}

/** Font size for an emoji-only message. One is a gesture; eight are a line. */
export function emojiScale(count: number): string {
	if (count <= 1) return "2.75rem";
	if (count <= 3) return "2.25rem";
	if (count <= 5) return "1.75rem";
	return "1.375rem";
}

/**
 * Locate `@name` runs when sending, so mentions point at the right words.
 *
 * Offsets are computed at send time rather than while typing, because a name
 * in the text is not enough to identify a person — two members can share one,
 * and text gets edited after the fact. Searching forward and never revisiting
 * a stretch handles the same person named twice, and drops a mention whose
 * text has since been deleted instead of pointing it at whatever now sits
 * there.
 *
 * Offsets are UTF-16 code units, which is what the server expects and what JS
 * string indices already are — the one place this is easier on the web than
 * on a platform whose strings count grapheme clusters.
 */
export function locateMentions(
	text: string,
	named: { userId: string; name: string }[],
): { user_ids: string[]; loci: [number, number][] } | null {
	const userIds: string[] = [];
	const loci: [number, number][] = [];
	let searchFrom = 0;

	for (const person of named) {
		const needle = `@${person.name}`;
		const at = text.indexOf(needle, searchFrom);
		if (at < 0) continue;
		userIds.push(person.userId);
		loci.push([at, needle.length]);
		searchFrom = at + needle.length;
	}

	return userIds.length ? { user_ids: userIds, loci } : null;
}

/** The `@run` the caret is sitting in, for the autocomplete popup. */
export function mentionQuery(text: string, caret: number): { query: string; start: number } | null {
	const upto = text.slice(0, caret);
	const at = upto.lastIndexOf("@");
	if (at < 0) return null;

	// An `@` glued to the end of a word is an email address, not a mention.
	if (at > 0) {
		const before = upto[at - 1]!;
		if (!/\s/.test(before)) return null;
	}

	const run = upto.slice(at + 1);
	// A completed name ends the query, so "@Kieran " stops offering matches.
	if (/\s/.test(run)) return null;
	return { query: run, start: at };
}
