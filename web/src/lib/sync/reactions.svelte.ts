import type { GroupMeAPI } from "../api/groupme";
import type { WireReaction } from "../api/wire";
import type { ConversationID } from "../model/conversation-id";
import { cmpId } from "../model/ids";
import { normalizeReactions } from "../model/normalize";
import { keepNewerReactions } from "../model/reactions";
import type { Message } from "../model/types";
import type { Timeline } from "../state/timeline.svelte";
import * as store from "../store/db";
import { fetchHead, fetchMessage, fetchOlder, PAGE } from "./history";

/** Pages one stale-reaction refresh may spend before it stops. */
const REFRESH_PAGES = 5;

export interface ReactionDeps {
	api: GroupMeAPI;
	/** Lookup only; never creates a timeline. */
	timeline(key: string): Timeline | undefined;
	resolve(key: string): ConversationID | null;
	activeKey(): string | null;
	selfId(): string | null;
}

/** One task per id at a time; asking again mid-run buys exactly one rerun. */
class Coalescer {
	#running = new Set<string>();
	#again = new Set<string>();

	run(id: string, task: () => Promise<void>): void {
		if (this.#running.has(id)) {
			this.#again.add(id);
			return;
		}
		this.#running.add(id);
		void task()
			.catch(() => {})
			.finally(() => {
				this.#running.delete(id);
				if (this.#again.delete(id)) this.run(id, task);
			});
	}

	/** Drop owed reruns, so a cancelled task does not start straight back up. */
	forget(match: (id: string) => boolean): void {
		for (const id of this.#again) if (match(id)) this.#again.delete(id);
	}
}

/**
 * Keeps reactions on held messages current: live frames, this user's toggles,
 * and a refresh of whatever may have changed while the socket was down.
 */
export class ReactionSync {
	#deps: ReactionDeps;
	/** When the socket last became live. A page requested before this may have missed reactions. */
	#liveSince = Date.now();
	#refreshes = new Coalescer();
	#refetches = new Coalescer();
	#controllers = new Map<string, AbortController>();
	/** Never reset, so a slow answer to an old tap can never pass for a newer one. */
	#tick = 0;
	#latestTap = new Map<string, number>();

	constructor(deps: ReactionDeps) {
		this.#deps = deps;
	}

	/** The socket (re)connected: everything held is now suspect, starting with what is on screen. */
	wentLive(): void {
		this.#liveSince = Date.now();
		const key = this.#deps.activeKey();
		if (key) this.refreshStale(key);
	}

	/**
	 * Fold a fetched page into the timeline's watermark. `beforeId` null means the head page.
	 * Returns false when the page was requested before the socket last came up, so it proves nothing.
	 */
	notePage(key: string, beforeId: string | null, page: Message[], at: number): boolean {
		const t = this.#deps.timeline(key);
		if (!t || at < this.#liveSince) return false;
		const floor = page.length < PAGE || !page[0] ? "beginning" : page[0].id;
		const mark = this.#freshMark(t);
		if (beforeId === null) {
			if (!mark) t.verified = { floor, at };
		} else if (mark && mark.floor === beforeId) {
			// Contiguous with the mark, so it extends it; the older `at` still bounds the whole span.
			t.verified = { floor, at: mark.at };
		}
		return true;
	}

	/** Re-read the loaded part of a conversation the watermark does not cover. Never blocks. */
	refreshStale(key: string): void {
		this.#refreshes.run(key, () => this.#refresh(key));
	}

	/** A live reaction frame. `reactions` null means the frame named the message and nothing else. */
	applyFrame(key: string, messageId: string, reactions: WireReaction[] | null): void {
		if (reactions) {
			this.#write(key, messageId, normalizeReactions(reactions), Date.now());
			return;
		}
		const conv = this.#deps.resolve(key);
		if (!conv) return;
		if (conv.kind === "dm") {
			console.info(
				`reaction frame for DM message ${messageId} had no reaction set; keeping stored copy`,
			);
			return;
		}
		this.#refetches.run(`${key}:${messageId}`, async () => {
			// Only for messages we hold; fetching every one a busy group reacts to would be a flood.
			const held =
				this.#deps.timeline(key)?.find(messageId) ?? (await store.getMessage(key, messageId));
			if (!held) return;
			const fresh = await fetchMessage(this.#deps.api, conv, key, messageId, this.#signal(key));
			const t = this.#deps.timeline(key);
			// Not inserted into a timeline that does not reach back that far.
			if (fresh && t?.find(messageId)) t.merge([fresh], { asOf: fresh.reactionsAt });
		});
	}

	/** Set or clear this user's reaction: drawn first, sent second. */
	async toggle(key: string, messageId: string, glyph: string | null): Promise<void> {
		const message = this.#deps.timeline(key)?.find(messageId);
		const me = this.#deps.selfId();
		const conv = this.#deps.resolve(key);
		if (!message || !me || !conv) return;

		const previous = message.reactions.find((r) => r.userIds.includes(me))?.code ?? null;
		const tapKey = `${key}:${messageId}`;
		const tap = ++this.#tick;
		this.#latestTap.set(tapKey, tap);
		this.#write(key, messageId, applyReaction(message.reactions, me, glyph), Date.now());

		let ok = true;
		try {
			await this.#deps.api.setReaction(conv, messageId, glyph, previous !== null);
		} catch {
			ok = false;
		}
		// A later tap owns the row now.
		if (this.#latestTap.get(tapKey) !== tap) return;
		this.#latestTap.delete(tapKey);

		// Re-applied to the current set either way, never to a snapshot: on success to beat a page
		// served before the server took the tap, on failure to restore only this user's reaction.
		const current = this.#deps.timeline(key)?.find(messageId);
		if (current) {
			this.#write(
				key,
				messageId,
				applyReaction(current.reactions, me, ok ? glyph : previous),
				Date.now(),
			);
		}
	}

	/** Abort in-flight refreshes and refetches for one conversation, or all of them. */
	cancel(key?: string): void {
		const hit = (k: string) => key === undefined || k === key;
		for (const [k, c] of this.#controllers) {
			if (!hit(k)) continue;
			c.abort();
			this.#controllers.delete(k);
		}
		this.#refreshes.forget(hit);
		this.#refetches.forget((id) => key === undefined || id.startsWith(`${key}:`));
		if (key === undefined) this.#latestTap.clear();
	}

	async #refresh(key: string): Promise<void> {
		const conv = this.#deps.resolve(key);
		const t = this.#deps.timeline(key);
		if (!conv || !t) return;
		const signal = this.#signal(key);

		for (let pages = 0; pages < REFRESH_PAGES; pages++) {
			if (key !== this.#deps.activeKey() || signal.aborted) return;
			const mark = this.#freshMark(t);
			if (
				mark &&
				(mark.floor === "beginning" || !t.oldestId || cmpId(mark.floor, t.oldestId) <= 0)
			) {
				return;
			}
			// No fresh mark: start again from the head. Otherwise walk down from the floor.
			const before = mark ? mark.floor : null;
			const at = Date.now();
			const page = before
				? await fetchOlder(this.#deps.api, conv, key, before, signal)
				: await fetchHead(this.#deps.api, conv, key, signal);
			t.merge(page, { asOf: at });
			if (!this.notePage(key, before, page, at)) return;
		}
	}

	#freshMark(t: Timeline): Timeline["verified"] {
		const mark = t.verified;
		return mark && mark.at >= this.#liveSince ? mark : null;
	}

	#signal(key: string): AbortSignal {
		let c = this.#controllers.get(key);
		if (!c || c.signal.aborted) {
			c = new AbortController();
			this.#controllers.set(key, c);
		}
		return c.signal;
	}

	/** Replace a held message's reactions on screen and on disk, as a write made at `at`. */
	#write(key: string, messageId: string, reactions: Message["reactions"], at: number): void {
		const t = this.#deps.timeline(key);
		const current = t?.find(messageId);
		if (t && current) {
			t.replace(
				messageId,
				keepNewerReactions(current, { ...current, reactions, reactionsAt: at }, at),
			);
		}
		void store.putReactions(key, messageId, reactions, at).catch(() => {});
	}
}

/** Move this user's reaction to `glyph`, or remove it when null. */
export function applyReaction(
	reactions: Message["reactions"],
	userId: string,
	glyph: string | null,
): Message["reactions"] {
	const stripped = reactions
		.map((r) => ({ ...r, userIds: r.userIds.filter((u) => u !== userId) }))
		.filter((r) => r.userIds.length);
	if (!glyph) return stripped;

	const existing = stripped.find((r) => r.code === glyph);
	if (existing) {
		return stripped.map((r) => (r.code === glyph ? { ...r, userIds: [...r.userIds, userId] } : r));
	}

	// A powerup token carries its pack in the code, so an optimistic chip can
	// draw the right sprite before the server has confirmed anything.
	const pack = /^gm:(\d+):(\d+)$/.exec(glyph);
	return [
		...stripped,
		{
			code: glyph,
			kind: pack ? "powerup" : "unicode",
			userIds: [userId],
			packId: pack ? Number(pack[1]) : null,
			packIndex: pack ? Number(pack[2]) : null,
		},
	];
}
