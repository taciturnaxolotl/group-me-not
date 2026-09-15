/**
 * Message ids, and why they are not numbers.
 *
 * GroupMe message ids are 18-digit decimal strings: `"178935540721753871"`.
 * That is past `Number.MAX_SAFE_INTEGER`, so `Number(id)` silently rounds and
 * two adjacent messages can compare equal. They are also the sort key for the
 * entire app, so getting this wrong corrupts message order in a way that only
 * shows up under load, months later, in a busy group.
 *
 * The rules, once and in one place:
 *
 *   - store and pass ids as strings, always
 *   - order with `cmpId`, never with `<` or `Number()`
 *   - the ids are monotonic per conversation, so ordering by id *is* ordering
 *     by time, and is more reliable than `created_at`, which is whole seconds
 *     and ties constantly
 */

/** Numeric compare of two decimal id strings. Negative if `a` is older. */
export function cmpId(a: string, b: string): number {
	// Fast path: same length means a plain lexicographic compare is already
	// numeric, which is true for the overwhelming majority of comparisons
	// since all live ids are 18 digits.
	if (a.length === b.length) return a < b ? -1 : a > b ? 1 : 0;
	return a.length < b.length ? -1 : 1;
}

export const olderThan = (a: string, b: string) => cmpId(a, b) < 0;
export const newerThan = (a: string, b: string) => cmpId(a, b) > 0;

export function maxId(a: string | null, b: string | null): string | null {
	if (!a) return b;
	if (!b) return a;
	return cmpId(a, b) >= 0 ? a : b;
}

export function minId(a: string | null, b: string | null): string | null {
	if (!a) return b;
	if (!b) return a;
	return cmpId(a, b) <= 0 ? a : b;
}

/**
 * A client-side id for a message we have not sent yet.
 *
 * Sorts after every real id because it is longer, which is exactly what we
 * want: pending messages belong at the bottom of the list.
 */
export function pendingId(): string {
	return `9${Date.now()}${Math.floor(Math.random() * 1e6)
		.toString()
		.padStart(6, "0")}`;
}

export const isPendingId = (id: string) => id.length > 18;

/**
 * The idempotency key for a send.
 *
 * The server dedupes on this, which is the whole reason a retry after a
 * timeout is safe: if the first attempt actually landed, the second gets a
 * 409 and we treat that as success rather than sending twice.
 */
export function newSourceGuid(): string {
	return crypto.randomUUID().replace(/-/g, "");
}
