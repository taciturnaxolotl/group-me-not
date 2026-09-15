import { cmpId } from "../model/ids";

/**
 * Which parts of a conversation's history we actually hold.
 *
 * The naive version of this is a single `oldestLoaded` pointer, and it is
 * wrong in a way that is invisible until it matters. Consider: you load the
 * newest 100 messages, then follow a reply link to something from March and
 * load 100 around that. A single pointer now claims you have everything back
 * to March, and the four months in between are a hole the app will never
 * notice, never fill, and will happily scroll straight past.
 *
 * So track real intervals. Each range is a closed `[lo, hi]` span of message
 * ids that we know we hold *contiguously*, because it came from one paged walk
 * with no jumps. Ranges merge when they touch and never silently widen.
 *
 * Ids are compared numerically throughout — see `cmpId` for why that is not
 * the same as comparing them as strings.
 */
export interface IdRange {
	lo: string;
	hi: string;
}

/** Insert a span, merging it into anything it touches or overlaps. */
export function addRange(ranges: IdRange[], lo: string, hi: string): IdRange[] {
	if (cmpId(lo, hi) > 0) [lo, hi] = [hi, lo];

	const out: IdRange[] = [];
	let curLo = lo;
	let curHi = hi;
	let placed = false;

	for (const r of [...ranges].sort((a, b) => cmpId(a.lo, b.lo))) {
		if (cmpId(r.hi, curLo) < 0) {
			// Entirely below the new span, and not adjacent.
			out.push(r);
			continue;
		}
		if (cmpId(r.lo, curHi) > 0) {
			// Entirely above. Everything below has been absorbed.
			if (!placed) {
				out.push({ lo: curLo, hi: curHi });
				placed = true;
			}
			out.push(r);
			continue;
		}
		// Overlapping or touching: widen.
		curLo = cmpId(r.lo, curLo) < 0 ? r.lo : curLo;
		curHi = cmpId(r.hi, curHi) > 0 ? r.hi : curHi;
	}
	if (!placed) out.push({ lo: curLo, hi: curHi });
	return out;
}

/** The range containing this id, if we hold it. */
export function rangeContaining(ranges: IdRange[], id: string): IdRange | null {
	for (const r of ranges) {
		if (cmpId(r.lo, id) <= 0 && cmpId(r.hi, id) >= 0) return r;
	}
	return null;
}

/**
 * Whether history below `id` is known to be continuous with what we hold.
 *
 * Drives the "load older" trigger: if the range containing the newest message
 * starts at the very first message of the conversation, there is nothing above
 * to fetch.
 */
export function hasContiguousBelow(ranges: IdRange[], id: string, floor: string | null): boolean {
	const r = rangeContaining(ranges, id);
	if (!r) return false;
	if (!floor) return false;
	return cmpId(r.lo, floor) <= 0;
}

/** The newest id we hold anywhere. */
export function newestHeld(ranges: IdRange[]): string | null {
	let best: string | null = null;
	for (const r of ranges) if (!best || cmpId(r.hi, best) > 0) best = r.hi;
	return best;
}

/**
 * Whether a newly arrived message continues the newest range, or opens a gap.
 *
 * A push event that is not adjacent to what we hold means we were away and
 * missed something. The honest response is to record the discontinuity and
 * page forward to close it, rather than appending and pretending the history
 * is whole.
 */
export function continuesHead(ranges: IdRange[], incomingId: string): boolean {
	const head = newestHeld(ranges);
	if (!head) return false;
	return cmpId(incomingId, head) > 0;
}
