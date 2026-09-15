import type { GroupMeAPI } from "../api/groupme";
import type { ConversationID } from "../model/conversation-id";
import { cmpId } from "../model/ids";
import { normalizeMessage } from "../model/normalize";
import type { Message } from "../model/types";
import * as store from "../store/db";
import { addRange, newestHeld } from "../store/ranges";

/**
 * Fetching history, and keeping track of which parts we hold.
 *
 * Every fetch here records the span it covered, so the app always knows the
 * difference between "there is nothing older" and "we have not looked". Those
 * two look identical at the top of a scroll view and mean opposite things.
 */

const PAGE = 100;

/** The newest page. Used on open and after a reconnect. */
export async function fetchHead(
	api: GroupMeAPI,
	conversation: ConversationID,
	key: string,
	signal?: AbortSignal,
): Promise<Message[]> {
	const page = await api.messages(conversation, { limit: PAGE, signal });
	const msgs = page.messages.map((w) => normalizeMessage(w, key));
	if (!msgs.length) return [];

	msgs.sort((a, b) => cmpId(a.id, b.id));
	await recordSpan(key, msgs[0]!.id, msgs[msgs.length - 1]!.id, {
		// A full page means there is probably more below it; a short one means
		// we reached the beginning of the conversation.
		floorReached: msgs.length < PAGE,
		floorId: msgs.length < PAGE ? msgs[0]!.id : null,
	});
	await store.putMessages(msgs);
	return msgs;
}

/** A page older than what we hold. Returns empty at the beginning of time. */
export async function fetchOlder(
	api: GroupMeAPI,
	conversation: ConversationID,
	key: string,
	beforeId: string,
	signal?: AbortSignal,
): Promise<Message[]> {
	const page = await api.messages(conversation, { beforeId, limit: PAGE, signal });
	const msgs = page.messages.map((w) => normalizeMessage(w, key));
	if (!msgs.length) {
		// An empty answer to `before_id` is the server saying there is nothing
		// older. Record it so the scroller stops asking.
		const state = await store.getState(key);
		await store.putState({ ...state, floorId: beforeId });
		return [];
	}

	msgs.sort((a, b) => cmpId(a.id, b.id));
	// The span runs up to the anchor, not to the newest message returned:
	// everything between the newest returned message and `beforeId` is
	// contiguous by construction.
	await recordSpan(key, msgs[0]!.id, beforeId, {
		floorReached: msgs.length < PAGE,
		floorId: msgs.length < PAGE ? msgs[0]!.id : null,
	});
	await store.putMessages(msgs);
	return msgs;
}

/**
 * Walk forward from what we hold until we catch up with the present.
 *
 * This is the reconnect path, and the reason it uses `after_id` rather than
 * the obvious-looking `since_id` is worth stating plainly, because the API
 * gives no hint and the failure is silent.
 *
 * Measured against a real group with 550 messages, anchoring 90 back from the
 * newest and asking for 20:
 *
 *     after_id  -> first: 178925899368629784  (the message right after the anchor)
 *     since_id  -> first: 178935525972245019  (the newest message in the group)
 *
 * `since_id` returns the *newest* messages, not the ones following the anchor.
 * Catching up with it after a spell offline appends the last twenty and
 * silently skips everything in between — and because the ids it did return
 * are newer, nothing ever goes back for the gap. `after_id` walks forward one
 * page at a time and leaves no hole.
 */
export async function catchUp(
	api: GroupMeAPI,
	conversation: ConversationID,
	key: string,
	signal?: AbortSignal,
): Promise<Message[]> {
	const state = await store.getState(key);
	const head = newestHeld(state.ranges);
	if (!head) return fetchHead(api, conversation, key, signal);

	const collected: Message[] = [];
	let anchor = head;

	// Bounded so a conversation that has moved on by thousands of messages
	// does not hold the whole sync open. Whatever is left is picked up as the
	// user scrolls, and the head fetch below still gets them the newest.
	for (let page = 0; page < 10; page++) {
		const res = await api.messages(conversation, { afterId: anchor, limit: PAGE, signal });
		const msgs = res.messages.map((w) => normalizeMessage(w, key)).sort((a, b) => cmpId(a.id, b.id));
		if (!msgs.length) break;

		await store.putMessages(msgs);
		await recordSpan(key, anchor, msgs[msgs.length - 1]!.id, {});
		collected.push(...msgs);
		anchor = msgs[msgs.length - 1]!.id;
		if (msgs.length < PAGE) break;
	}

	return collected;
}

/**
 * File a message that arrived over the socket.
 *
 * If it does not continue the newest span we hold, we were away for something
 * and the range is left broken on purpose. The next catch-up closes it. The
 * alternative — widening the range to swallow the gap — makes the hole
 * permanent and undetectable.
 */
export async function acceptPushed(key: string, message: Message): Promise<boolean> {
	const state = await store.getState(key);
	const head = newestHeld(state.ranges);
	await store.putMessages([message]);

	if (!head) {
		await store.putState({ ...state, ranges: addRange(state.ranges, message.id, message.id) });
		return true;
	}

	const contiguous = cmpId(message.id, head) > 0;
	if (contiguous) {
		await store.putState({ ...state, ranges: addRange(state.ranges, head, message.id) });
		return true;
	}

	await store.putState({
		...state,
		ranges: addRange(state.ranges, message.id, message.id),
		gapAtHead: true,
	});
	return false;
}

async function recordSpan(
	key: string,
	lo: string,
	hi: string,
	opts: { floorReached?: boolean; floorId?: string | null },
): Promise<void> {
	const state = await store.getState(key);
	await store.putState({
		...state,
		ranges: addRange(state.ranges, lo, hi),
		floorId: opts.floorReached && opts.floorId ? opts.floorId : state.floorId,
		gapAtHead: false,
	});
}

/** What we already have on disk, for drawing before the network answers. */
export async function loadCachedTail(key: string, limit = 60): Promise<Message[]> {
	return store.loadTail(key, limit);
}

export async function loadCachedBefore(key: string, beforeId: string, limit = 60): Promise<Message[]> {
	return store.loadBefore(key, beforeId, limit);
}
