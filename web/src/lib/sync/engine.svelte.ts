import { ApiClient } from "../api/client";
import { GroupMeAPI } from "../api/groupme";
import { BayeuxClient, dmChannel, groupChannel, type BayeuxState } from "../realtime/bayeux";
import { decodePush, messageChannels } from "../realtime/events";
import { keyOf, parseKey, type ConversationID } from "../model/conversation-id";
import { cmpId, isPendingId } from "../model/ids";
import {
	normalizeCurrentUser,
	normalizeMember,
	normalizeMessage,
	normalizeReactionList,
} from "../model/normalize";
import type { DeletionActor, Member, Message } from "../model/types";
import * as store from "../store/db";
import { ConversationsState } from "../state/conversations.svelte";
import { Timeline } from "../state/timeline.svelte";
import { clearSession, readIdentity, readToken, saveSession } from "../auth/session";
import { fetchConversationList, linkTopics, loadCachedList } from "./conversations";
import {
	acceptPushed,
	catchUp,
	fetchHead,
	fetchMessage,
	fetchOlder,
	loadCachedTail,
	PAGE,
} from "./history";
import { Outbox } from "./outbox";

/** Pages one stale-reaction refresh may spend before it stops. */
const REFRESH_PAGES = 5;

/**
 * Whether a held copy may be missing reactions made while nobody listened.
 *
 * Tombstones are left out. Their reactions were cleared with their text, and
 * re-reading one to confirm it is still deleted would be a request spent on
 * nothing.
 */
function isStale(m: Message, liveSince: number): boolean {
	return !m.deletedAt && (m.verifiedAt ?? 0) < liveSince;
}

/**
 * The engine.
 *
 * One object that owns the API client, the socket, the local store and the
 * reactive state, and is responsible for keeping all four in agreement. The UI
 * talks to this and to nothing below it.
 *
 * The governing rule, inherited from the iOS client and worth repeating:
 * **local storage is the truth, the network updates local storage, the UI
 * observes local storage.** Nothing on screen ever waits for a request.
 */

export type SyncPhase = "idle" | "syncing" | "failed";

export class Engine {
	readonly conversations = new ConversationsState();

	token = $state<string | null>(null);
	signedIn = $derived(this.token !== null);
	/** Null while we are still working out whether there is a session. */
	booting = $state(true);

	phase = $state<SyncPhase>("idle");
	connection = $state<BayeuxState>("closed");
	online = $state(navigator.onLine);
	lastError = $state<string | null>(null);

	activeKey = $state<string | null>(null);
	timelines = $state<Map<string, Timeline>>(new Map());

	#client: ApiClient;
	#api: GroupMeAPI;
	#push: BayeuxClient;
	#outbox: Outbox;
	#focusChannels = new Set<string>();
	/** One pending read-receipt timer per conversation, not one globally. */
	#readTimers = new Map<string, ReturnType<typeof setTimeout>>();
	#typingSentAt = 0;
	/** In-flight sync, so a burst of triggers does not fan out N times. */
	#syncing: Promise<void> | null = null;
	/**
	 * Bumped every time a different conversation is opened. An in-flight fetch
	 * checks it before writing, so a slow response for the chat you just left
	 * cannot land on the one you just opened.
	 */
	#openGeneration = 0;

	/**
	 * Since when the socket has been listening without a break, in epoch ms.
	 *
	 * A cached message can only be trusted as far as the last moment
	 * something could have told us it changed. While the socket is up, a
	 * reaction arrives as a frame and is written straight through; while it
	 * is down, nothing arrives, and `after_id` catch-up never looks back at a
	 * message it already holds. So any copy verified before the socket last
	 * came up may be missing reactions made in the dark, and any copy
	 * verified after it has been kept current since.
	 *
	 * Starts at page load, because nothing was listening before then, and is
	 * moved forward every time the socket becomes live, which covers a dropped
	 * network, a laptop lid, and a background tab whose socket the browser or
	 * the watchdog killed. Memory only: a reload starts the clock again,
	 * which is exactly right.
	 */
	#liveSince = Date.now();
	/** Conversations with a stale-reaction refresh running, and those owed another. */
	#refreshing = new Set<string>();
	#refreshAgain = new Set<string>();
	/** Single-message refetches in flight, by `${key}:${id}`, and those owed another. */
	#refetching = new Set<string>();
	#refetchAgain = new Set<string>();
	/**
	 * The latest local reaction toggle per message, by `${key}:${id}`, so a
	 * slow answer to an earlier toggle cannot act on a later one.
	 */
	#reactionSeq = new Map<string, number>();

	constructor() {
		this.#client = new ApiClient(
			() => this.token,
			() => this.signOut(),
		);
		this.#api = new GroupMeAPI(this.#client);
		this.#push = new BayeuxClient(
			() => this.token,
			{
				onEvent: (channel, data) => this.#onPush(channel, data),
				onState: (s) => {
					// Every arrival at live, the first included. The socket opens
					// a beat after page load, and a reaction made in that beat
					// reached nobody.
					if (s === "live" && this.connection !== "live") this.#liveSince = Date.now();
					this.connection = s;
				},
				// The socket has no replay. Anything published while we were
				// dark simply did not arrive, so the only honest response to
				// reconnecting is to go and look.
				onResync: () => void this.sync("reconnect"),
			},
		);
		this.#outbox = new Outbox(this.#api, {
			onLocal: (m) => this.timeline(m.conversationKey).merge([m]),
			onSettled: (placeholderId, message) => this.#settleSend(placeholderId, message),
			onFailed: (placeholderId, reason) => this.#failSend(placeholderId, reason),
		});

		addEventListener("online", () => {
			this.online = true;
			void this.sync("online");
		});
		addEventListener("offline", () => {
			this.online = false;
		});
	}

	get api(): GroupMeAPI {
		return this.#api;
	}

	// MARK: - Session

	async boot(): Promise<void> {
		const token = readToken();
		const identity = readIdentity();
		if (!token || !identity) {
			this.booting = false;
			return;
		}

		this.token = token;
		this.#api.adoptSelfId(identity.userId);
		this.conversations.me = {
			id: identity.userId,
			name: identity.name,
			avatarUrl: identity.avatarUrl,
			email: null,
			phone: null,
		};
		this.conversations.restoreCollapsed();

		// Draw from cache first. On a warm start the sidebar is populated
		// before the first request has left the machine.
		const cached = await loadCachedList();
		if (cached.length) this.conversations.upsert(linkTopics(cached));
		this.booting = false;

		this.#push.start();
		for (const ch of messageChannels(identity.userId)) this.#push.subscribe(ch);
		await this.sync("boot");
		void this.#outbox.drain();
	}

	async adoptSession(token: string, identity: { userId: string; name: string; avatarUrl: string | null }) {
		saveSession(token, identity);
		this.token = token;
		this.#api.adoptSelfId(identity.userId);
		this.conversations.me = { ...identity, id: identity.userId, email: null, phone: null };
		this.booting = false;
		this.#push.start();
		for (const ch of messageChannels(identity.userId)) this.#push.subscribe(ch);
		await this.sync("signin");
	}

	signOut(): void {
		this.#push.stop();
		clearSession();
		void store.wipe();
		this.token = null;
		this.conversations.byKey = new Map();
		this.timelines = new Map();
		this.activeKey = null;
	}

	// MARK: - Sync

	async sync(reason: string): Promise<void> {
		// Reconnects, wake-ups and manual refreshes all arrive at once after a
		// laptop opens. Joining the in-flight run instead of starting another
		// keeps that from becoming four times the requests, which is how a
		// client meets the rate limiter.
		if (this.#syncing) return this.#syncing;
		this.#syncing = this.#runSync(reason).finally(() => {
			this.#syncing = null;
		});
		return this.#syncing;
	}

	async #runSync(_reason: string): Promise<void> {
		if (!this.token) return;
		const selfId = this.#api.selfId;
		if (!selfId) return;

		this.phase = "syncing";
		try {
			const { conversations, receipts } = await fetchConversationList(this.#api, selfId);
			const linked = linkTopics(conversations);
			this.conversations.upsert(linked);
			this.conversations.applyReadReceipts(receipts);

			// Persist what is on screen, not what came off the wire.
			//
			// The fetched objects carry the server's `unread_count` and the
			// stale cursor embedded in the group list. Reconciling those
			// against `/v4/read_receipts` happens in memory, so writing
			// `linked` here stores the numbers we just decided were wrong —
			// and the next cold start reads them back and shows a badge on
			// every conversation for the second it takes the receipts to
			// arrive and clear them again.
			void store.putConversations([...this.conversations.byKey.values()]);

			// Refresh whatever is on screen, and close any gap the socket left.
			if (this.activeKey) await this.#refreshActive();

			this.lastError = null;
			this.phase = "idle";
		} catch (err) {
			this.lastError = err instanceof Error ? err.message : String(err);
			this.phase = "failed";
		}
	}

	async #refreshActive(): Promise<void> {
		const key = this.activeKey;
		if (!key) return;
		const conv = this.#resolve(key);
		if (!conv) return;
		const fresh = await catchUp(this.#api, conv, key);
		if (fresh.length) this.timeline(key).merge(fresh);
		// Catch-up only walks forward, so it brings the new messages and
		// says nothing about the ones already on screen. Those are what a
		// reconnect actually leaves wrong, and this is the first moment the
		// gap is closed and the timeline settled enough to judge them.
		this.#refreshStale(key);
	}

	// MARK: - Stale reactions

	/**
	 * Re-read the loaded messages whose reactions may have changed unseen.
	 *
	 * Fire and forget, always. The timeline is already drawn from what we
	 * hold, and a reaction count that corrects itself a second later is far
	 * better than a transcript that waits for one.
	 *
	 * One run per conversation at a time. A second request while one is
	 * going is folded into a single rerun afterwards rather than dropped,
	 * because it usually means the socket came back mid-run and moved
	 * `#liveSince`, which the running pass captured too early to see.
	 */
	#refreshStale(key: string): void {
		if (this.#refreshing.has(key)) {
			this.#refreshAgain.add(key);
			return;
		}
		this.#refreshing.add(key);
		void this.#runRefresh(key)
			.catch(() => {
				// Nothing to tell the user. The stale copies stay stale and
				// the next open or reconnect tries again.
			})
			.finally(() => {
				this.#refreshing.delete(key);
				if (this.#refreshAgain.delete(key) && key === this.activeKey) this.#refreshStale(key);
			});
	}

	/**
	 * Walk the stale messages newest to oldest, a page at a time.
	 *
	 * Each page is anchored just above the newest stale message still
	 * uncovered, using the loaded message immediately newer as `before_id`,
	 * so the page starts exactly where the staleness does. When the newest
	 * stale message is the newest message, there is nothing to anchor on and
	 * the head page is the same thing.
	 *
	 * A page vouches for every id from its oldest message up to the anchor,
	 * whether or not each one came back: a message missing from that span
	 * was deleted on the server, and if it were left stale every later run
	 * would ask for it again, forever. A short page vouches for everything
	 * older too, because it reached the beginning of the conversation.
	 *
	 * Capped at a few pages. A conversation scrolled back a long way can hold
	 * thousands of messages, and the ones that matter are the ones near where
	 * the user is reading, which is near the bottom.
	 */
	async #runRefresh(key: string): Promise<void> {
		const conv = this.#resolve(key);
		if (!conv) return;
		const t = this.timeline(key);
		const since = this.#liveSince;
		/** Everything at or above this id has been covered by this run. */
		let ceiling: string | null = null;

		for (let page = 0; page < REFRESH_PAGES; page++) {
			// Checked between pages, not only at the start. Leaving the chat
			// abandons the rest; it will be stale again when it is reopened,
			// and refreshed then.
			if (key !== this.activeKey || !this.token) return;

			const loaded = t.messages.filter((m) => m.delivery === "sent" && !isPendingId(m.id));
			let newest = -1;
			for (let i = loaded.length - 1; i >= 0; i--) {
				const m = loaded[i]!;
				if (ceiling && cmpId(m.id, ceiling) >= 0) continue;
				if (isStale(m, since)) {
					newest = i;
					break;
				}
			}
			if (newest < 0) return;

			const anchor = loaded[newest + 1]?.id ?? null;
			const startedAt = Date.now();
			const fresh = anchor
				? await fetchOlder(this.#api, conv, key, anchor)
				: await fetchHead(this.#api, conv, key);
			// Merged even if the user has left. The timeline belongs to this
			// conversation, not to the screen, and the rows are already on disk.
			t.merge(fresh);

			const floor = fresh.length < PAGE ? null : (fresh[0]?.id ?? null);
			const covered = new Set<string>();
			for (const m of loaded) {
				if (anchor && cmpId(m.id, anchor) >= 0) continue;
				if (floor && cmpId(m.id, floor) < 0) continue;
				if (isStale(m, since)) covered.add(m.id);
			}
			t.markVerified(covered, startedAt);
			await store.markVerified(key, [...covered], startedAt);

			if (!floor) return;
			ceiling = floor;
		}
	}

	// MARK: - Conversations

	timeline(key: string): Timeline {
		let t = this.timelines.get(key);
		if (!t) {
			t = new Timeline(key);
			const next = new Map(this.timelines);
			next.set(key, t);
			this.timelines = next;
		}
		return t;
	}

	async open(key: string): Promise<void> {
		const generation = ++this.#openGeneration;
		this.activeKey = key;
		const conv = this.#resolve(key);
		if (!conv) return;
		const t = this.timeline(key);

		// Freeze the unread divider before anything marks the chat read, or it
		// disappears in the same tick it was created.
		const c = this.conversations.get(key);
		t.unreadFrom = c?.unreadCount ? c.lastReadMessageId : null;

		this.#focus(conv);

		// Everything below can suspend, so every write back into the timeline
		// is guarded on still being the conversation the user is looking at.
		// Without that, opening A then B before A's history lands splices A's
		// messages into B.
		try {
			if (!t.hydrated) {
				const cached = await loadCachedTail(key);
				if (generation !== this.#openGeneration) return;
				if (cached.length) t.merge(cached);
				t.hydrated = true;
			}

			void this.#loadMembers(conv);

			t.loadingNewer = true;
			const fresh = await fetchHead(this.#api, conv, key);
			if (generation !== this.#openGeneration) return;
			t.merge(fresh);

			const state = await store.getState(key);
			if (generation !== this.#openGeneration) return;
			// Compared numerically. These are 18-digit decimal strings, and
			// `>=` on them is a lexicographic compare that disagrees with the
			// numeric one the moment two ids differ in length.
			t.atFloor = Boolean(state.floorId && t.oldestId && cmpId(state.floorId, t.oldestId) >= 0);

			// After the head fetch, not alongside it. The head page is itself
			// a refresh of the newest hundred messages, so starting before it
			// lands would ask for the same page twice; starting after means
			// the refresh only goes looking for what the head did not cover,
			// which on most opens is nothing at all.
			this.#refreshStale(key);
		} catch (err) {
			if (generation === this.#openGeneration) {
				this.lastError = err instanceof Error ? err.message : String(err);
			}
		} finally {
			// Cleared unconditionally. A throw anywhere above used to leave the
			// spinner running for the life of the tab.
			t.loadingNewer = false;
		}

		this.#scheduleMarkRead(key);
	}

	async loadOlder(key: string): Promise<void> {
		const t = this.timeline(key);
		if (t.loadingOlder || t.atFloor || !t.oldestId) return;
		const conv = this.#resolve(key);
		if (!conv) return;

		t.loadingOlder = true;
		try {
			const older = await fetchOlder(this.#api, conv, key, t.oldestId);
			if (!older.length) t.atFloor = true;
			else t.merge(older);
		} catch {
			// Leave it failed rather than retrying on every scroll tick; the
			// user can nudge it by scrolling again.
		} finally {
			t.loadingOlder = false;
		}
	}

	async #loadMembers(conv: ConversationID): Promise<void> {
		const groupId = conv.kind === "topic" ? conv.parentId : conv.kind === "group" ? conv.id : null;
		if (!groupId || this.conversations.members.has(groupId)) return;
		try {
			const wire = await this.#api.members(groupId);
			const members: Member[] = wire.map(normalizeMember);
			const next = new Map(this.conversations.members);
			next.set(groupId, members);
			this.conversations.members = next;
			void store.putMembers(groupId, members);
		} catch {}
	}

	#resolve(key: string): ConversationID | null {
		const selfId = this.#api.selfId;
		return selfId ? parseKey(key, selfId) : null;
	}

	// MARK: - Sending

	async send(
		key: string,
		text: string,
		replyTo: Message | null = null,
		attachments: unknown[] = [],
	): Promise<void> {
		const conv = this.#resolve(key);
		const me = this.conversations.me;
		if (!conv || !me) return;
		await this.#outbox.send(conv, key, text, {
			replyTo,
			attachments,
			self: { id: me.id, name: me.name, avatarUrl: me.avatarUrl },
		});
	}

	/** The conversation id for an open chat, so uploads can be addressed. */
	conversationFor(key: string): ConversationID | null {
		return this.#resolve(key);
	}

	/** Delete a message for everyone, locally first. */
	async remove(key: string, messageId: string): Promise<void> {
		const conv = this.#resolve(key);
		if (!conv) return;
		const t = this.timeline(key);
		const backup = t.find(messageId);
		this.#applyDeletion(key, messageId, Math.floor(Date.now() / 1000), "sender");
		try {
			await this.#api.remove(conv, messageId);
		} catch (err) {
			// Straight back to what it was. A refusal means the message is
			// still there for everybody else, and a tombstone over it would be
			// this client inventing a deletion that never happened.
			if (backup) {
				t.replace(messageId, backup);
				void store.putMessages([backup]);
			}
			this.lastError = err instanceof Error ? err.message : String(err);
		}
	}

	/** Edit a message, optimistically. */
	async editMessage(key: string, messageId: string, text: string): Promise<void> {
		const conv = this.#resolve(key);
		const t = this.timeline(key);
		const before = t.find(messageId);
		if (!conv || !before) return;

		const now = Math.floor(Date.now() / 1000);
		t.replace(messageId, { ...before, text, editedAt: Math.max(now, before.createdAt + 1) });
		try {
			await this.#api.edit(conv, messageId, text);
		} catch (err) {
			t.replace(messageId, before);
			this.lastError = err instanceof Error ? err.message : String(err);
		}
	}

	/**
	 * Whether this message is still inside its group's edit window.
	 *
	 * The window is server-owned and per group, so it has to be checked
	 * rather than assumed. An action that fails on click is a worse bug than
	 * an action that is not offered.
	 */
	canEdit(key: string, message: Message): boolean {
		if (message.senderId !== this.#api.selfId) return false;
		if (message.kind !== "user" || message.delivery !== "sent") return false;
		const window = this.conversations.get(key)?.editWindow ?? 0;
		if (window <= 0) return false;
		return Date.now() / 1000 - message.createdAt < window;
	}

	retrySend(sourceGuid: string): void {
		void this.#outbox.retry(sourceGuid);
	}

	discardSend(key: string, sourceGuid: string, placeholderId: string): void {
		void this.#outbox.discard(sourceGuid);
		this.timeline(key).remove(placeholderId);
	}

	#settleSend(placeholderId: string, message: Message | null): void {
		for (const t of this.timelines.values()) {
			const existing = t.find(placeholderId);
			if (!existing) continue;
			if (message) {
				t.replace(placeholderId, { ...existing, ...message, delivery: "sent", failure: null });
			} else {
				// 409: the server has it but did not say which id. Mark it
				// delivered and let the next fetch swap in the real copy,
				// which it will match on `source_guid`.
				t.replace(placeholderId, { ...existing, delivery: "sent", failure: null });
				void this.#refreshActive();
			}
			return;
		}
	}

	#failSend(placeholderId: string, reason: string): void {
		for (const t of this.timelines.values()) {
			const existing = t.find(placeholderId);
			if (!existing) continue;
			t.replace(placeholderId, { ...existing, delivery: "failed", failure: reason });
			return;
		}
	}

	// MARK: - Reactions

	/**
	 * Set or clear this user's reaction, optimistically.
	 *
	 * Drawn first, sent second, rolled back only if the server refuses. A
	 * reaction is the one interaction where the round trip is plainly longer
	 * than the gesture, so waiting for it feels broken.
	 */
	async react(key: string, messageId: string, glyph: string | null): Promise<void> {
		const t = this.timeline(key);
		const message = t.find(messageId);
		const me = this.conversations.me;
		const conv = this.#resolve(key);
		if (!message || !me || !conv) return;

		const before = message.reactions;
		const mine = before.find((r) => r.userIds.includes(me.id));
		const seqKey = `${key}:${messageId}`;
		const seq = (this.#reactionSeq.get(seqKey) ?? 0) + 1;
		this.#reactionSeq.set(seqKey, seq);
		// Stamped and written through to disk, so a page of history that was
		// asked for before this tap cannot land afterwards and take it back.
		this.#setReactions(key, messageId, applyReaction(before, me.id, glyph), Date.now());

		try {
			await this.#api.setReaction(conv, messageId, glyph, Boolean(mine));
		} catch {
			// A later tap on the same message owns the row now, and putting
			// this one's `before` back would undo it.
			if (this.#reactionSeq.get(seqKey) === seq) {
				this.#setReactions(key, messageId, before, Date.now());
			}
			return;
		}

		// Applied once more, against whatever is there now, and stamped
		// again. The stamp above only guards against pages requested after
		// the tap, and a page requested after the tap but served before the
		// server took the like would come back without it and win. From this
		// moment the server has it, so every later page agrees, and putting it
		// back here closes the window in between. `applyReaction` strips this
		// user first, so doing it twice is harmless.
		if (this.#reactionSeq.get(seqKey) !== seq) return;
		this.#reactionSeq.delete(seqKey);
		const current = t.find(messageId);
		if (current) {
			this.#setReactions(
				key,
				messageId,
				applyReaction(current.reactions, me.id, glyph),
				Date.now(),
			);
		}
	}

	/**
	 * Replace a held message's reactions, on screen and on disk, as a write
	 * newer than any page of history requested before `at`.
	 */
	#setReactions(key: string, messageId: string, reactions: Message["reactions"], at: number): void {
		const t = this.timelines.get(key);
		const current = t?.find(messageId);
		if (t && current && (current.reactionsAt ?? 0) <= at) {
			t.replace(messageId, { ...current, reactions, reactionsAt: at });
		}
		void store.putReactions(key, messageId, reactions, at).catch(() => {});
	}

	// MARK: - Read state

	/**
	 * Mark read shortly after opening or after a message lands.
	 *
	 * Keyed per conversation. A single shared timer meant that opening B while
	 * A's timer was pending cancelled A's receipt outright, so a chat you
	 * glanced at and left kept its badge.
	 */
	#scheduleMarkRead(key: string): void {
		const existing = this.#readTimers.get(key);
		if (existing) clearTimeout(existing);
		this.#readTimers.set(
			key,
			setTimeout(() => {
				this.#readTimers.delete(key);
				const t = this.timelines.get(key);
				const newest = t?.newestId;
				if (!newest) return;
				this.conversations.markRead(key, newest);
				const conv = this.#resolve(key);
				if (conv) void this.#api.markRead(conv, newest).catch(() => {});
			}, 600),
		);
	}

	markReadNow(key: string): void {
		this.#scheduleMarkRead(key);
	}

	// MARK: - Typing

	/** Announce typing, at most once a second. */
	noteTyping(key: string): void {
		const now = Date.now();
		if (now - this.#typingSentAt < 1000) return;
		this.#typingSentAt = now;
		const conv = this.#resolve(key);
		if (conv) void this.#api.typing(conv).catch(() => {});
	}

	/** Subscribe to the channels that carry typing for what is on screen. */
	#focus(conv: ConversationID): void {
		const want = new Set<string>();
		if (conv.kind === "dm") want.add(dmChannel(conv.selfId, conv.id));
		else {
			want.add(groupChannel(conv.id));
			if (conv.kind === "topic") want.add(groupChannel(conv.parentId));
		}
		for (const ch of this.#focusChannels) if (!want.has(ch)) this.#push.unsubscribe(ch);
		for (const ch of want) if (!this.#focusChannels.has(ch)) this.#push.subscribe(ch);
		this.#focusChannels = want;
	}

	// MARK: - Push

	#onPush(channel: string, data: unknown): void {
		const event = decodePush(channel, data);
		const selfId = this.#api.selfId;
		if (!selfId) return;

		switch (event.kind) {
			case "message": {
				const key = this.#keyForHint(event.conversationHint, event.message);
				if (!key) return;
				// Stamped as verified now. It was published a moment ago and the
				// socket is up, so anything that happens to it from here arrives
				// as a frame of its own.
				const message: Message = {
					...normalizeMessage(event.message, key),
					verifiedAt: Date.now(),
				};
				const mine = message.senderId === selfId;
				void acceptPushed(key, message).then((contiguous) => {
					if (!contiguous && key === this.activeKey) void this.#refreshActive();
				});
				this.timeline(key).merge([message]);
				// A remote deletion travels as one of these: an ordinary system
				// message that names its victim. It is not an envelope type of
				// its own, so this is the only place it can be caught.
				if (message.event?.kind === "messageDeleted") {
					this.#applyDeletion(
						key,
						message.event.messageId,
						message.event.deletedAt ?? message.createdAt,
						message.event.actor,
					);
				}
				this.conversations.noteActivity(
					key,
					message.id,
					message.createdAt,
					!mine && key !== this.activeKey,
				);
				if (key === this.activeKey) this.#scheduleMarkRead(key);
				break;
			}

			case "messageUpdated": {
				const key = this.#keyForHint(String(event.message.group_id ?? ""), event.message);
				if (!key) return;
				this.timeline(key).merge([normalizeMessage(event.message, key)]);
				break;
			}

			case "messageDeleted": {
				const key = event.groupId ? this.#keyForHint(event.groupId, null) : null;
				if (!key) break;
				// Prefer the server's own tombstone when it sent one: it carries
				// the real `deleted_at` and the role that did it, rather than our
				// guess at both.
				if (event.tombstone) {
					const tomb = normalizeMessage(event.tombstone, key);
					this.timeline(key).merge([tomb]);
					void store.putMessages([tomb]);
				} else {
					this.#applyDeletion(key, event.messageId, Math.floor(Date.now() / 1000), "sender");
				}
				break;
			}

			case "reaction": {
				const key =
					this.#keyForHint(event.conversationHint ?? "", event.subject) ??
					this.#keyHolding(event.messageId);
				if (!key) return;
				const at = Date.now();
				if (event.subject) {
					this.#setReactions(
						key,
						event.messageId,
						normalizeMessage(event.subject, key).reactions,
						at,
					);
				} else if (event.reactions) {
					// The whole set afterwards, so a replace and not a delta.
					this.#setReactions(key, event.messageId, normalizeReactionList(event.reactions), at);
				} else {
					// Named a message and said nothing about it. Reading a missing
					// set as empty would wipe every reaction on it, and ignoring
					// the frame leaves us wrong until something happens to refetch
					// the message, which for an old one is never. Ask.
					this.#refetchReactions(key, event.messageId);
				}
				break;
			}

			case "typing": {
				const key = this.#keyForHint(event.conversationId, null);
				if (key && event.userId !== selfId) this.timeline(key).noteTyping(event.userId);
				break;
			}

			case "membership":
				void this.sync("membership");
				break;
		}
	}

	/**
	 * Turn a message into a tombstone, on screen and on disk.
	 *
	 * A tombstone rather than a removal, for two reasons. The server keeps the
	 * row and hands it back from REST with `deleted_at` set, so a client that
	 * dropped it would disagree with the next catch-up and have the message
	 * rise from the dead. And a reader who watched a conversation happen is
	 * owed the fact that something was said and taken back; a silent hole in
	 * the transcript reads as a client that lost a message.
	 *
	 * Deleting something we do not hold is not an error. It happens whenever
	 * the victim is older than the window we have paged in, and there is
	 * nothing to mark.
	 */
	#applyDeletion(
		key: string,
		messageId: string,
		deletedAt: number,
		actor: DeletionActor,
	): void {
		const existing = this.timeline(key).find(messageId);
		if (!existing || existing.deletedAt) return;
		// Cleared, not kept-and-hidden. The text is gone from the server and
		// holding a copy in IndexedDB would be a client keeping a record of
		// something its author withdrew.
		const tomb: Message = {
			...existing,
			deletedAt,
			deletionActor: actor,
			text: "",
			attachments: [],
			reactions: [],
			mentions: [],
		};
		this.timeline(key).merge([tomb]);
		void store.putMessages([tomb]);
	}

	/**
	 * Re-read one message after a reaction frame that carried no reaction set.
	 *
	 * Only for messages we hold. A frame about a message we have never paged
	 * in changes nothing on screen or on disk, and fetching it would be a
	 * request per reaction in every busy group this account is in.
	 *
	 * A burst of frames for one message, which is what a popular message
	 * produces, becomes one request and at most one follow-up rather than
	 * one each. The follow-up is not dropped, because a frame that arrived
	 * after the first request went out may describe a reaction it missed.
	 */
	#refetchReactions(key: string, messageId: string): void {
		const id = `${key}:${messageId}`;
		if (this.#refetching.has(id)) {
			this.#refetchAgain.add(id);
			return;
		}
		this.#refetching.add(id);
		void (async () => {
			const held =
				this.timelines.get(key)?.find(messageId) ?? (await store.getMessage(key, messageId));
			const conv = this.#resolve(key);
			if (!held || !conv) return;
			const fresh = await fetchMessage(this.#api, conv, key, messageId);
			// Merged only where it is already drawn. Dropping one old message
			// into a timeline that does not reach back that far would float
			// it above a gap with nothing to say one is there.
			const t = this.timelines.get(key);
			if (fresh && t?.find(messageId)) t.merge([fresh]);
		})()
			.catch(() => {})
			.finally(() => {
				this.#refetching.delete(id);
				if (this.#refetchAgain.delete(id)) this.#refetchReactions(key, messageId);
			});
	}

	/** The conversation whose loaded timeline holds a message, if any does. */
	#keyHolding(messageId: string): string | null {
		for (const [key, t] of this.timelines) if (t.find(messageId)) return key;
		return null;
	}

	/**
	 * Work out which conversation a push belongs to.
	 *
	 * The hint is a group id, a topic id, or a DM pair id, and we hold all
	 * three in the same map under different keys — so the lookup is by REST id
	 * rather than by raw id.
	 */
	#keyForHint(hint: string, message: { user_id?: string; recipient_id?: string } | null): string | null {
		const selfId = this.#api.selfId;
		if (!selfId) return null;

		if (hint) {
			for (const c of this.conversations.byKey.values()) {
				if (c.id.kind !== "dm" && c.id.id === hint) return c.key;
			}
			if (hint.includes("+")) {
				const [a, b] = hint.split("+");
				const other = a === selfId ? b : a;
				if (other) return keyOf({ kind: "dm", id: other, selfId });
			}
		}

		// A DM arriving for a conversation we have never listed. Build the key
		// anyway so the message lands somewhere and the next sync names it.
		if (message) {
			const sender = String(message.user_id ?? "");
			const recipient = String(message.recipient_id ?? "");
			const other = sender === selfId ? recipient : sender;
			if (other) return keyOf({ kind: "dm", id: other, selfId });
		}
		return null;
	}
}

/** Move this user's reaction to `glyph`, or remove it when null. */
function applyReaction(
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
