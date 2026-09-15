import type { GroupMeAPI } from "../api/groupme";
import { ApiError } from "../api/errors";
import { parseKey, type ConversationID } from "../model/conversation-id";
import { newSourceGuid, pendingId } from "../model/ids";
import { normalizeAttachment } from "../model/normalize";
import type { WireAttachment } from "../api/wire";
import type { Message } from "../model/types";
import * as store from "../store/db";

/**
 * The send queue.
 *
 * A send is a local write first and a network call second. The message appears
 * in the transcript on the next frame, marked provisional, and the queue takes
 * responsibility for getting it to the server eventually. That is the whole
 * reason the app stays usable on a bad connection.
 *
 * Two things make it safe to retry blindly:
 *
 *   1. `source_guid` is generated and persisted *before* the first request
 *      goes out, so every retry carries the same key.
 *   2. The server dedupes on that key and answers 409 for a repeat, which the
 *      API layer already translates into "this landed, I just cannot tell you
 *      its id".
 *
 * Backoff lives in IndexedDB rather than in a timer, because a timer dies with
 * the tab and a message queued at midnight should not retry in a tight loop
 * the moment the laptop opens.
 */

export interface OutboxHandlers {
	/** Draw the optimistic copy immediately. */
	onLocal: (message: Message) => void;
	/** The server acknowledged; swap the placeholder for the real thing. */
	onSettled: (placeholderId: string, message: Message | null) => void;
	/** Out of attempts for now. The row shows a retry affordance. */
	onFailed: (placeholderId: string, reason: string) => void;
}

export class Outbox {
	#api: GroupMeAPI;
	#handlers: OutboxHandlers;
	#draining = false;
	#timer: ReturnType<typeof setTimeout> | null = null;

	constructor(api: GroupMeAPI, handlers: OutboxHandlers) {
		this.#api = api;
		this.#handlers = handlers;
	}

	/**
	 * Queue a message and return at once.
	 *
	 * Order matters here: the row is durable before the request exists, so a
	 * tab closed mid-send resumes rather than losing what someone wrote.
	 */
	async send(
		conversation: ConversationID,
		conversationKey: string,
		text: string,
		opts: { attachments?: unknown[]; replyTo?: Message | null; self: { id: string; name: string; avatarUrl: string | null } },
	): Promise<void> {
		const sourceGuid = newSourceGuid();
		const placeholderId = pendingId();
		const attachments = [...(opts.attachments ?? [])];

		if (opts.replyTo) {
			attachments.push({
				type: "reply",
				reply_id: opts.replyTo.id,
				base_reply_id: opts.replyTo.replyTo?.rootId ?? opts.replyTo.id,
				user_id: opts.replyTo.senderId,
			});
		}

		const local: Message = {
			id: placeholderId,
			sourceGuid,
			conversationKey,
			senderId: opts.self.id,
			name: opts.self.name,
			avatarUrl: opts.self.avatarUrl,
			text,
			createdAt: Math.floor(Date.now() / 1000),
			editedAt: null,
			kind: "user",
			delivery: "pending",
			failure: null,
			// The optimistic copy carries the real attachments, so a photo you
			// just sent is on screen at once rather than appearing when the
			// server's copy comes back.
			attachments: (opts.attachments ?? []).map((a) => normalizeAttachment(a as WireAttachment)),
			reactions: [],
			replyTo: opts.replyTo
				? {
						messageId: opts.replyTo.id,
						rootId: opts.replyTo.replyTo?.rootId ?? opts.replyTo.id,
						authorId: opts.replyTo.senderId,
					}
				: null,
			mentions: [],
			pinnedAt: null,
			pinnedBy: null,
			deletedAt: null,
			event: null,
		};

		await store.putOutbox({
			sourceGuid,
			conversationKey,
			text,
			attachments,
			createdAt: Date.now(),
			attempts: 0,
			nextAttemptAt: 0,
			lastError: null,
			placeholderId,
		});

		this.#handlers.onLocal(local);
		void this.drain();
	}

	/** Work through everything that is due. Safe to call at any time. */
	async drain(): Promise<void> {
		if (this.#draining) return;
		this.#draining = true;
		try {
			const entries = await store.allOutbox();
			const now = Date.now();
			for (const entry of entries.sort((a, b) => a.createdAt - b.createdAt)) {
				if (entry.nextAttemptAt > now) continue;
				await this.#attempt(entry);
			}
		} finally {
			this.#draining = false;
			await this.#scheduleWake();
		}
	}

	async retry(sourceGuid: string): Promise<void> {
		const entries = await store.allOutbox();
		const entry = entries.find((e) => e.sourceGuid === sourceGuid);
		if (!entry) return;
		await store.putOutbox({ ...entry, nextAttemptAt: 0, attempts: 0, lastError: null });
		await this.drain();
	}

	async discard(sourceGuid: string): Promise<void> {
		await store.dropOutbox(sourceGuid);
	}

	async #attempt(entry: store.OutboxEntry): Promise<void> {
		const selfId = this.#api.selfId;
		const conversation = selfId ? parseKey(entry.conversationKey, selfId) : null;
		if (!conversation) {
			await store.dropOutbox(entry.sourceGuid);
			return;
		}

		try {
			const sent = await this.#api.send(conversation, {
				text: entry.text,
				attachments: entry.attachments,
				sourceGuid: entry.sourceGuid,
			});
			await store.dropOutbox(entry.sourceGuid);
			// `sent` is null when the server answered 409: it has the message
			// but did not hand it back. The caller reconciles from the next
			// fetch, which is why this is not an error.
			this.#handlers.onSettled(entry.placeholderId, sent ? { ...toMessage(sent, entry) } : null);
		} catch (err) {
			const e = err instanceof ApiError ? err : new ApiError("network", String(err));
			const attempts = entry.attempts + 1;

			if (!e.retryable || attempts >= 8) {
				await store.putOutbox({ ...entry, attempts, lastError: e.message, nextAttemptAt: Infinity });
				this.#handlers.onFailed(entry.placeholderId, humanReason(e));
				return;
			}

			// Clamped at the eighth step so an overnight queue retries every
			// few minutes rather than drifting out to hours.
			const backoff = Math.min(2000 * 2 ** Math.min(attempts, 8), 5 * 60_000);
			await store.putOutbox({
				...entry,
				attempts,
				lastError: e.message,
				nextAttemptAt: Date.now() + backoff * (0.5 + Math.random() / 2),
			});
		}
	}

	async #scheduleWake(): Promise<void> {
		if (this.#timer) clearTimeout(this.#timer);
		const entries = await store.allOutbox();
		const due = entries
			.map((e) => e.nextAttemptAt)
			.filter((t) => Number.isFinite(t))
			.sort((a, b) => a - b)[0];
		if (due === undefined) return;
		this.#timer = setTimeout(() => void this.drain(), Math.max(due - Date.now(), 500));
	}
}

function humanReason(e: ApiError): string {
	if (e.kind === "forbidden") return "You cannot post here";
	if (e.kind === "notFound") return "This conversation is gone";
	if (e.kind === "unauthorized") return "Signed out";
	if (e.kind === "network" || e.kind === "timeout") return "Not delivered";
	return "Not delivered";
}

function toMessage(wire: { id: string }, entry: store.OutboxEntry): Message {
	// The real normalizer runs in the engine, which has the conversation key
	// and the member list. This only needs to carry the id across.
	return { ...(wire as unknown as Message), conversationKey: entry.conversationKey };
}
