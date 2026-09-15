/**
 * Time, in the two vocabularies an interface needs.
 *
 * A clock in a transcript and a clock in a sidebar answer different questions.
 * The transcript wants "when, exactly" because messages either side of it are
 * minutes apart. The sidebar wants "how long ago, roughly" because the row
 * next to it might be from March.
 */

const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto", style: "narrow" });

const clock = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
const clockWithDay = new Intl.DateTimeFormat(undefined, {
	weekday: "short",
	hour: "numeric",
	minute: "2-digit",
});
const shortDate = new Intl.DateTimeFormat(undefined, { month: "numeric", day: "numeric" });
const fullStamp = new Intl.DateTimeFormat(undefined, { dateStyle: "full", timeStyle: "short" });

/** `9:41 AM`. What sits beside a message. */
export function messageTime(epochSeconds: number): string {
	return clock.format(epochSeconds * 1000);
}

/** The full thing, for a tooltip. */
export function exactTime(epochSeconds: number): string {
	return fullStamp.format(epochSeconds * 1000);
}

/**
 * The sidebar's timestamp, which changes shape as things age.
 *
 * `now` under a minute, then minutes, then a clock time for today, then a
 * weekday for this week, then a date. Every step is the shortest thing that is
 * still unambiguous at that distance.
 */
export function listTime(epochSeconds: number): string {
	const ms = epochSeconds * 1000;
	const diff = Date.now() - ms;
	if (diff < 60_000) return "now";
	if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m`;

	const d = new Date(ms);
	const now = new Date();
	const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
	if (ms >= startOfToday) return clock.format(ms);

	const daysAgo = Math.round((startOfToday - new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()) / 86_400_000);
	if (daysAgo === 1) return "Yesterday";
	if (daysAgo < 7) return d.toLocaleDateString(undefined, { weekday: "short" });
	return shortDate.format(ms);
}

/** "3 minutes ago", for screen readers, where "3m" reads badly. */
export function spokenTime(epochSeconds: number): string {
	const diff = Date.now() - epochSeconds * 1000;
	if (diff < 60_000) return "just now";
	if (diff < 3_600_000) return rtf.format(-Math.floor(diff / 60_000), "minute");
	if (diff < 86_400_000) return rtf.format(-Math.floor(diff / 3_600_000), "hour");
	return clockWithDay.format(epochSeconds * 1000);
}
