import { ApiClient } from "../api/client";
import { GroupMeAPI } from "../api/groupme";
import { BayeuxClient, dmChannel, groupChannel, type BayeuxState } from "../realtime/bayeux";
import { decodePush, messageChannels } from "../realtime/events";
import { keyOf, parseKey, type ConversationID } from "../model/conversation-id";
import { cmpId } from "../model/ids";
import { normalizeCurrentUser, normalizeMember, normalizeMessage } from "../model/normalize";
import type { DeletionActor, Member, Message } from "../model/types";
import * as store from "../store/db";
import { ConversationsState } from "../state/conversations.svelte";
import { Timeline } from "../state/timeline.svelte";
import { clearSession, readIdentity, readToken, saveSession } from "../auth/session";
import { fetchConversationList, linkTopics, loadCachedList } from "./conversations";
import { acceptPushed, catchUp, fetchHead, fetchOlder, loadCachedTail } from "./history";
import { Outbox } from "./outbox";

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
		const optimistic = applyReaction(before, me.id, glyph);
		t.replace(messageId, { ...message, reactions: optimistic });

		try {
			await this.#api.setReaction(conv, messageId, glyph, Boolean(mine));
		} catch {
			const current = t.find(messageId);
			if (current) t.replace(messageId, { ...current, reactions: before });
		}
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
				const message = normalizeMessage(event.message, key);
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
				if (!event.subject) return;
				const key = this.#keyForHint(event.groupId ?? "", event.subject);
				if (!key) return;
				// The payload carries the message with its reactions already
				// recalculated, so this is a replace rather than a delta.
				this.timeline(key).merge([normalizeMessage(event.subject, key)]);
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
