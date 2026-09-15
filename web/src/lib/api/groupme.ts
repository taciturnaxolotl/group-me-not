import { ApiClient, HOSTS, type QueryValue } from "./client";
import { ApiError } from "./errors";
import type {
	WireChat,
	WireGroup,
	WireMember,
	WireMessage,
	WireReadReceipt,
	WireRelationship,
	WireUser,
} from "./wire";
import { restId, type ConversationID } from "../model/conversation-id";

/**
 * The GroupMe REST surface, typed, with the quirks absorbed.
 *
 * One method per thing the app does. Every place the API is inconsistent is
 * handled here so it does not leak upward: the `omit=memberships` default, the
 * repeating `include` params, the 100-message cap, the `since_id` trap, the
 * 409-means-success rule on sends, and the fact that groups and DMs are two
 * endpoints wearing one costume.
 *
 * Callers pass a `ConversationID` and never branch on its kind.
 */

export interface MessagePage {
	messages: WireMessage[];
	/** Total in the conversation, when the server says. Only groups do. */
	count: number | null;
}

export interface SendOptions {
	text: string;
	attachments?: unknown[];
	/** Supply it so retries are idempotent. See `newSourceGuid`. */
	sourceGuid: string;
}

export class GroupMeAPI {
	#c: ApiClient;
	#selfId: string | null;

	constructor(client: ApiClient, selfId: string | null = null) {
		this.#c = client;
		this.#selfId = selfId;
	}

	adoptSelfId(id: string): void {
		this.#selfId = id;
	}

	get selfId(): string | null {
		return this.#selfId;
	}

	// MARK: - Identity

	async me(): Promise<WireUser> {
		const user = await this.#c.get<WireUser>("/users/me");
		this.#selfId = String(user.id);
		return user;
	}

	// MARK: - Conversation lists

	/**
	 * What the index routes must be told to include.
	 *
	 * Not optional, and not a single comma-joined value. Both list endpoints
	 * leave `unread_count` out unless asked, so without this every badge in
	 * the sidebar reads zero and the app looks like it is lying. The param
	 * repeats rather than joining: `include=unread_count&include=last_read_at`.
	 */
	static readonly LIST_INCLUDE: readonly string[] = [
		"unread_count",
		"last_read_at",
		"last_read_message_id",
	];

	/**
	 * `GET /v3/groups`. One page.
	 *
	 * `omit=memberships` is the default on purpose. A member list per group,
	 * across fifty groups, is megabytes of JSON that the sidebar never reads.
	 * Fetch members for the one group being looked at instead.
	 */
	groups(page = 1, perPage = 100): Promise<WireGroup[]> {
		return this.#c.get<WireGroup[]>("/groups", {
			query: {
				page,
				per_page: perPage,
				omit: "memberships",
				include: GroupMeAPI.LIST_INCLUDE as QueryValue,
			},
		});
	}

	/** Every group, following pagination to the end. */
	async allGroups(signal?: AbortSignal): Promise<WireGroup[]> {
		const out: WireGroup[] = [];
		for (let page = 1; page <= 20; page++) {
			const batch = await this.#c.get<WireGroup[]>("/groups", {
				query: {
					page,
					per_page: 100,
					omit: "memberships",
					include: GroupMeAPI.LIST_INCLUDE as QueryValue,
				},
				signal,
			});
			if (!batch?.length) break;
			out.push(...batch);
			if (batch.length < 100) break;
		}
		return out;
	}

	/** `GET /v3/chats` — the DM list. */
	async allChats(signal?: AbortSignal): Promise<WireChat[]> {
		const out: WireChat[] = [];
		for (let page = 1; page <= 20; page++) {
			const batch = await this.#c.get<WireChat[]>("/chats", {
				query: { page, per_page: 100, include: GroupMeAPI.LIST_INCLUDE as QueryValue },
				signal,
			});
			if (!batch?.length) break;
			out.push(...batch);
			if (batch.length < 100) break;
		}
		return out;
	}

	/**
	 * `GET /v3/groups/{id}/subgroups` — the topics inside a group.
	 *
	 * Topics are full conversations with their own message history; they are
	 * not threads. Note that `id` and `parent_id` come back as numbers here
	 * while every other route sends them as strings, so the normalizer casts.
	 */
	subgroups(groupId: string, signal?: AbortSignal): Promise<WireGroup[]> {
		return this.#c.get<WireGroup[]>(`/groups/${groupId}/subgroups`, { signal });
	}

	group(groupId: string): Promise<WireGroup> {
		return this.#c.get<WireGroup>(`/groups/${groupId}`);
	}

	// MARK: - Messages

	/**
	 * A page of history, newest first, walking backwards.
	 *
	 * `beforeId` is the only cursor exposed for paging. That is deliberate:
	 *
	 * `since_id` looks like the obvious way to catch up, and it is a trap. It
	 * returns the *newest* messages after that id, not the oldest — so asking
	 * for everything since the last message you have, in a conversation where
	 * two hundred messages arrived overnight, silently skips the middle and
	 * leaves a hole you will not notice until someone references it. Use
	 * `afterId` to walk forward; it pages from the oldest side like a sane
	 * person.
	 *
	 * `acceptFiles=1` makes the server include file attachments rather than
	 * quietly stripping them, which is not the default and has no business
	 * being opt-in.
	 */
	async messages(
		conversation: ConversationID,
		opts: { beforeId?: string; afterId?: string; limit?: number; signal?: AbortSignal } = {},
	): Promise<MessagePage> {
		// The server caps this at 100 and answers a 400 for anything larger,
		// rather than clamping. Clamp here so a caller asking for 500 gets 100
		// messages instead of an error.
		const limit = Math.min(opts.limit ?? 100, 100);

		if (conversation.kind === "dm") {
			const res = await this.#c.get<{ direct_messages: WireMessage[] }>("/direct_messages", {
				query: {
					other_user_id: conversation.id,
					limit,
					acceptFiles: 1,
					before_id: opts.beforeId,
					after_id: opts.afterId,
				},
				signal: opts.signal,
			});
			return { messages: res?.direct_messages ?? [], count: null };
		}

		const res = await this.#c.get<{ count: number; messages: WireMessage[] }>(
			`/groups/${conversation.id}/messages`,
			{
				query: {
					limit,
					acceptFiles: 1,
					before_id: opts.beforeId,
					after_id: opts.afterId,
				},
				signal: opts.signal,
			},
		);
		// A 304 means "nothing new" and the client turns that into undefined.
		return { messages: res?.messages ?? [], count: res?.count ?? null };
	}

	/**
	 * Send, treating a conflict as success.
	 *
	 * The server dedupes on `source_guid`. If a send times out after the
	 * server committed it, the retry comes back 409 — which means "I already
	 * have this", not "something went wrong". Surfacing that as an error makes
	 * the app show a failed message that was in fact delivered, and the user
	 * sends it again. Returning null lets the caller fall back to reconciling
	 * against the next fetch.
	 */
	async send(conversation: ConversationID, opts: SendOptions): Promise<WireMessage | null> {
		const attachments = opts.attachments ?? [];
		try {
			if (conversation.kind === "dm") {
				const res = await this.#c.post<{ direct_message: WireMessage }>("/direct_messages", {
					body: {
						direct_message: {
							source_guid: opts.sourceGuid,
							recipient_id: conversation.id,
							text: opts.text,
							attachments,
						},
					},
				});
				return res?.direct_message ?? null;
			}
			const res = await this.#c.post<{ message: WireMessage }>(
				`/groups/${conversation.id}/messages`,
				{ body: { message: { source_guid: opts.sourceGuid, text: opts.text, attachments } } },
			);
			return res?.message ?? null;
		} catch (err) {
			if (err instanceof ApiError && err.kind === "conflict") return null;
			throw err;
		}
	}

	/**
	 * Edit a message, inside the group's edit window.
	 *
	 * Two things here disagree with the reverse-engineered notes, both
	 * measured against the live API:
	 *
	 *   - The route is `PUT /v4/...`, not a POST to the v3 `conversations`
	 *     path. That one answers 500.
	 *   - The body is a bare `{ text }`. The documented
	 *     `{ message: { text, attachments } }` is refused with
	 *     `40001 Invalid text`, which reads like a validation bug and is
	 *     really the wrong envelope.
	 *
	 * DMs take the other user's id in the path, where sending takes it in the
	 * body. There is no rule to lean on; it is just how it is.
	 */
	async edit(conversation: ConversationID, messageId: string, text: string): Promise<void> {
		const path =
			conversation.kind === "dm"
				? `/direct_messages/${conversation.id}/messages/${messageId}`
				: `/groups/${conversation.id}/messages/${messageId}`;
		await this.#c.put(path, { version: "v4", body: { text } });
	}

	async remove(conversation: ConversationID, messageId: string): Promise<void> {
		await this.#c.delete(`/conversations/${restId(conversation)}/messages/${messageId}`);
	}

	// MARK: - Reactions

	/**
	 * Put this user's reaction on a message into an exact state.
	 *
	 * A person holds at most one reaction per message, so changing glyph means
	 * removing the old one first. The order is not cosmetic: a `like` that
	 * lands on a message the user has already reacted to is *silently ignored*
	 * by the server. It answers 200, changes nothing, and the optimistic UI
	 * then disagrees with reality until the next refetch.
	 *
	 * `glyph` is either an emoji or a powerup token of the form `gm:pack:index`
	 * minted by the normalizer, since a sprite reaction has no character of its
	 * own to pass around. Pass null to clear.
	 */
	async setReaction(
		conversation: ConversationID,
		messageId: string,
		glyph: string | null,
		had: boolean,
	): Promise<void> {
		const conv = restId(conversation);
		if (had) {
			await this.#c.post(`/messages/${conv}/${messageId}/unlike`);
		}
		if (glyph === null) return;

		const pack = /^gm:(\d+):(\d+)$/.exec(glyph);
		const like_icon = pack
			? { type: "emoji", pack_id: Number(pack[1]), pack_index: Number(pack[2]) }
			: { type: "unicode", code: glyph };

		await this.#c.post(`/messages/${conv}/${messageId}/like`, { body: { like_icon } });
	}

	/** A plain like, which sends no body at all. */
	async like(conversation: ConversationID, messageId: string): Promise<void> {
		await this.#c.post(`/messages/${restId(conversation)}/${messageId}/like`);
	}

	async unlike(conversation: ConversationID, messageId: string): Promise<void> {
		await this.#c.post(`/messages/${restId(conversation)}/${messageId}/unlike`);
	}

	// MARK: - Read state

	/**
	 * `GET /v4/read_receipts` — every conversation's read mark in one request.
	 *
	 * The v3 way was one request per conversation. With sixty conversations
	 * that is sixty requests on every cold start, which is how a client ends
	 * up rate limited before it has drawn anything.
	 */
	readReceipts(signal?: AbortSignal): Promise<{ receipts: WireReadReceipt[] }> {
		return this.#c.get<{ receipts: WireReadReceipt[] }>("/read_receipts", {
			version: "v4",
			signal,
		});
	}

	/** Mark one conversation read up to a message. */
	async markRead(conversation: ConversationID, messageId: string): Promise<void> {
		await this.#c.post(`/read_receipts/${restId(conversation)}`, {
			version: "v4",
			body: { message_id: messageId },
			// Fire and forget. A read receipt that fails is worth exactly one
			// attempt: the next one supersedes it anyway.
			retries: 0,
		});
	}

	async markAllRead(): Promise<void> {
		await this.#c.post("/conversations/mark_all_read", { version: "v4", retries: 0 });
	}

	pinnedConversations(signal?: AbortSignal): Promise<{ pinned_conversation_ids: string[] }> {
		return this.#c.get("/pinned_conversations", { version: "v4", signal });
	}

	// MARK: - People

	async members(groupId: string, signal?: AbortSignal): Promise<WireMember[]> {
		const g = await this.#c.get<WireGroup>(`/groups/${groupId}`, { signal });
		return g?.members ?? [];
	}

	/**
	 * `GET /v4/relationships` — the address book.
	 *
	 * Cursor paginated, and the cursor is an opaque base64 blob rather than a
	 * page number. Follow it until a page comes back short.
	 */
	async allRelationships(signal?: AbortSignal): Promise<WireRelationship[]> {
		const out: WireRelationship[] = [];
		let cursor: string | undefined;
		for (let i = 0; i < 40; i++) {
			const res = await this.#c.get<WireRelationship[] | { relationships: WireRelationship[] }>(
				"/relationships",
				{
					version: "v4",
					query: { include_blocked: true, limit: 200, page: cursor },
					signal,
				},
			);
			const batch = Array.isArray(res) ? res : (res?.relationships ?? []);
			if (!batch.length) break;
			out.push(...batch);
			if (batch.length < 200) break;
			// The next cursor is the last user id, base64'd. The server does
			// not hand back a `next` link, so we build it.
			const last = batch[batch.length - 1];
			if (!last) break;
			cursor = btoa(last.user_id);
		}
		return out;
	}

	/** `GET /v1/presence/users/{id}`. Not enveloped, unlike everything else. */
	presence(userId: string, signal?: AbortSignal): Promise<unknown> {
		return this.#c.get("/presence/users/" + userId, { version: "v1", signal });
	}

	// MARK: - Typing

	/**
	 * Announce typing.
	 *
	 * There is no matching "stopped" event — the indicator on the receiving
	 * end expires on a timer. So this is sent repeatedly while someone types,
	 * throttled by the caller, and simply stops.
	 */
	async typing(conversation: ConversationID): Promise<void> {
		await this.#c.post("/conversations/typing", {
			body: { conversation_id: restId(conversation) },
			retries: 0,
			timeoutMs: 5_000,
		});
	}

	// MARK: - Uploads

	/**
	 * Push an image through the ingest service.
	 *
	 * Raw bytes with a real `Content-Type`, not multipart. The response is not
	 * enveloped like the rest of the API, and the URL it hands back has no
	 * extension: append `.jpeg` or the CDN serves it as an octet-stream and
	 * the browser downloads it instead of drawing it.
	 */
	async uploadImage(blob: Blob, signal?: AbortSignal): Promise<string> {
		const res = await this.#c.post<{ payload: { url: string; picture_url?: string } }>(
			"/pictures",
			{
				host: HOSTS.image,
				body: blob,
				headers: { "content-type": blob.type || "image/jpeg" },
				signal,
				timeoutMs: 120_000,
			},
		);
		const url = res?.payload?.picture_url ?? res?.payload?.url;
		if (!url) throw new ApiError("decode", "image upload returned no url");
		return url;
	}

	/**
	 * Video ingest, which is asynchronous.
	 *
	 * The upload answers with a status URL, not a video URL. Poll it until the
	 * transcode finishes. It wants the conversation in a header, which is the
	 * only route in the API that does that.
	 */
	async uploadVideo(
		conversation: ConversationID,
		blob: Blob,
		signal?: AbortSignal,
	): Promise<{ url: string; posterUrl: string | null }> {
		const res = await this.#c.post<{ status_url: string }>("/transcode", {
			host: HOSTS.video,
			body: blob,
			headers: {
				"content-type": blob.type || "video/mp4",
				"X-Conversation-Id": restId(conversation),
			},
			signal,
			timeoutMs: 300_000,
		});
		if (!res?.status_url) throw new ApiError("decode", "video upload returned no status url");

		for (let i = 0; i < 60; i++) {
			await new Promise((r) => setTimeout(r, 2000));
			const status = await this.#c.get<{ status: string; url?: string; thumbnail_url?: string }>(
				res.status_url,
				{ host: res.status_url, signal },
			);
			if (status?.status === "complete" && status.url) {
				return { url: status.url, posterUrl: status.thumbnail_url ?? null };
			}
			if (status?.status === "failed") throw new ApiError("server", "video transcode failed");
		}
		throw new ApiError("timeout", "video transcode did not finish");
	}
}
