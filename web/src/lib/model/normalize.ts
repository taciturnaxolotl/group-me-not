import type {
	WireAttachment,
	WireChat,
	WireGroup,
	WireMember,
	WireMessage,
	WireReaction,
	WireSystemEvent,
	WireUser,
} from "../api/wire";
import { dm, group, keyOf, topic, type ConversationID } from "./conversation-id";
import type {
	Attachment,
	Conversation,
	CurrentUser,
	Member,
	Mention,
	Message,
	PollOption,
	Preview,
	Reaction,
	ReplyRef,
	SystemEvent,
} from "./types";

/**
 * Wire shapes in, domain shapes out.
 *
 * This is the only file allowed to know that the server calls a topic's name
 * `topic` and a group's name `name`, that `favorited_by` and `reactions`
 * describe the same thing twice, or that `loci` is occasionally malformed.
 * Everything it cannot make sense of is preserved rather than dropped.
 */

export function normalizeMessage(w: WireMessage, conversationKey: string): Message {
	const attachments = (w.attachments ?? []).map(normalizeAttachment);

	return {
		id: w.id,
		sourceGuid: w.source_guid,
		conversationKey,
		senderId: w.user_id,
		name: w.name,
		avatarUrl: w.avatar_url,
		text: w.text ?? "",
		createdAt: w.created_at,
		// `updated_at` is present and equal to `created_at` on plenty of
		// untouched messages, so its mere presence proves nothing. Only a
		// later timestamp means somebody edited this.
		editedAt: w.updated_at && w.updated_at > w.created_at ? w.updated_at : null,
		kind: w.system || w.sender_type === "system" ? "system" : w.sender_type === "bot" ? "bot" : "user",
		delivery: "sent",
		failure: null,
		attachments,
		reactions: normalizeReactions(w.reactions, w.favorited_by ?? []),
		replyTo: findReply(w.attachments ?? []),
		mentions: findMentions(w.attachments ?? [], (w.text ?? "").length),
		pinnedAt: w.pinned_at ?? null,
		pinnedBy: w.pinned_by || null,
		deletedAt: w.deleted_at || null,
		event: w.event ? normalizeSystemEvent(w.event) : null,
	};
}

// MARK: - Attachments

export function normalizeAttachment(a: WireAttachment): Attachment {
	switch (a.type) {
		case "image":
			return {
				kind: "image",
				url: String(a.url ?? ""),
				width: numOrNull(a.width),
				height: numOrNull(a.height),
				blurhash: typeof a.blurhash === "string" ? a.blurhash : null,
			};
		case "linked_image":
			// Renders identically to an image; the only difference is that we
			// cannot ask the CDN to resize it. Collapsing the two here means
			// the renderer has one image case instead of two.
			return { kind: "image", url: String(a.url ?? ""), width: null, height: null, blurhash: null };
		case "video":
			return {
				kind: "video",
				url: String(a.url ?? ""),
				posterUrl: typeof a.preview_url === "string" ? a.preview_url : null,
				width: numOrNull(a.width),
				height: numOrNull(a.height),
			};
		case "file":
			return {
				kind: "file",
				fileId: String(a.file_id ?? ""),
				name: typeof a.file_name === "string" ? a.file_name : null,
				size: numOrNull(a.file_size),
				mime: typeof a.file_type === "string" ? a.file_type : null,
			};
		case "location":
			return {
				kind: "location",
				lat: Number(a.lat),
				lng: Number(a.lng),
				name: typeof a.name === "string" ? a.name : null,
			};
		case "poll":
			return { kind: "poll", pollId: String(a.poll_id ?? "") };
		case "event":
			return { kind: "event", eventId: String(a.event_id ?? "") };
		case "emoji":
			return {
				kind: "powerup",
				placeholder: String(a.placeholder ?? ""),
				charmap: Array.isArray(a.charmap) ? (a.charmap as [number, number][]) : [],
			};
		default:
			// `reply` and `mentions` land here and that is fine: they are
			// lifted onto the message itself and never drawn as attachments.
			return { kind: "unknown", type: a.type, raw: a };
	}
}

function findReply(attachments: WireAttachment[]): ReplyRef | null {
	const a = attachments.find((x) => x.type === "reply");
	if (!a) return null;
	const replyId = String((a as { reply_id?: string }).reply_id ?? "");
	if (!replyId) return null;
	const base = String((a as { base_reply_id?: string }).base_reply_id ?? "") || replyId;
	const author = (a as { user_id?: string }).user_id;
	return { messageId: replyId, rootId: base, authorId: author ? String(author) : null };
}

/**
 * Mentions, defensively.
 *
 * `user_ids` and `loci` are parallel arrays and are trusted by every client I
 * have looked at. They should not be. A locus can run past the end of the
 * text — an edit that shortened the message leaves the old offsets behind —
 * and a renderer that slices on it produces either an exception or silently
 * mangled text. Drop the ones that do not fit and sort what is left, because
 * the renderer walks them in order.
 */
function findMentions(attachments: WireAttachment[], textLength: number): Mention[] {
	const a = attachments.find((x) => x.type === "mentions");
	if (!a) return [];
	const ids = (a as { user_ids?: string[] }).user_ids ?? [];
	const loci = (a as { loci?: [number, number][] }).loci ?? [];

	const out: Mention[] = [];
	const n = Math.min(ids.length, loci.length);
	for (let i = 0; i < n; i++) {
		const id = ids[i];
		const pair = loci[i];
		if (!id || !pair) continue;
		const [start, length] = pair;
		if (!Number.isInteger(start) || !Number.isInteger(length)) continue;
		if (start < 0 || length <= 0 || start + length > textLength) continue;
		out.push({ userId: String(id), start, length });
	}
	out.sort((x, y) => x.start - y.start);

	// Overlapping spans would make the renderer emit the same characters
	// twice. Keep the first of any overlapping pair.
	const clean: Mention[] = [];
	let cursor = 0;
	for (const m of out) {
		if (m.start < cursor) continue;
		clean.push(m);
		cursor = m.start + m.length;
	}
	return clean;
}

// MARK: - Reactions

/**
 * Reactions, reconciling the two ways the server describes them.
 *
 * `reactions` is the modern form and `favorited_by` is the old like-only one.
 * Messages liked by an older client can arrive with a populated
 * `favorited_by` and no `reactions` at all, which is why the fallback below
 * is not dead code: without it, likes from those clients are invisible.
 */
function normalizeReactions(wire: WireReaction[] | undefined, favoritedBy: string[]): Reaction[] {
	if (wire?.length) {
		return wire
			.filter((r) => r.user_ids?.length)
			.map((r) => {
				const packId = numOrNull(r.pack_id);
				const packIndex = numOrNull(r.pack_index);
				const powerup = r.type === "emoji";
				return {
					// A powerup has no character, so it needs a synthetic one to
					// key a list by and to compare against. `gm:` cannot collide
					// with a real emoji, which is always a grapheme cluster.
					code: powerup ? `gm:${packId}:${packIndex}` : r.code,
					kind: powerup ? ("powerup" as const) : ("unicode" as const),
					userIds: r.user_ids,
					packId,
					packIndex,
				};
			});
	}
	if (favoritedBy.length) {
		return [{ code: "\u2665\uFE0F", kind: "unicode", userIds: favoritedBy, packId: null, packIndex: null }];
	}
	return [];
}

// MARK: - System events

function normalizeSystemEvent(e: WireSystemEvent): SystemEvent {
	const d = (e.data ?? {}) as Record<string, unknown>;
	const actor = pickId(d.user) ?? pickId(d.actor) ?? null;

	switch (e.type) {
		case "membership.announce.added":
		case "membership.notifications.added": {
			const added = Array.isArray(d.added_users) ? d.added_users : [];
			return { kind: "membersAdded", userIds: added.map(pickId).filter(isString), actorId: actor };
		}
		case "membership.notifications.removed":
		case "membership.announce.removed": {
			const removed = pickId(d.removed_user);
			return { kind: "memberRemoved", userId: removed ?? "", actorId: actor };
		}
		case "membership.notifications.exited":
			return { kind: "memberLeft", userId: actor ?? "" };
		case "group.name_change":
			return { kind: "nameChanged", name: String(d.name ?? ""), actorId: actor };
		case "group.avatar_change":
			return { kind: "avatarChanged", actorId: actor };
		case "group.topic_change":
			return { kind: "topicChanged", topic: String(d.topic ?? ""), actorId: actor };
		case "message.pinned":
			return { kind: "messagePinned", messageId: String(d.message_id ?? ""), actorId: actor };
		case "poll.created": {
			const poll = (d.poll ?? {}) as Record<string, unknown>;
			return { kind: "pollCreated", pollId: String(poll.id ?? ""), subject: String(poll.subject ?? "") };
		}
		case "poll.finished": {
			const poll = (d.poll ?? {}) as Record<string, unknown>;
			const options = Array.isArray(d.options) ? (d.options as PollOption[]) : [];
			return {
				kind: "pollFinished",
				pollId: String(poll.id ?? ""),
				subject: String(poll.subject ?? ""),
				options,
			};
		}
		case "call.started":
			return { kind: "callStarted", actorId: actor };
		default:
			return { kind: "other", type: e.type, raw: e };
	}
}

// MARK: - Conversations

export function normalizeGroup(w: WireGroup): Conversation {
	const isTopic = w.parent_id !== undefined && w.parent_id !== null;
	const parentId = isTopic ? String(w.parent_id) : null;
	const id: ConversationID = isTopic ? topic(String(w.id), parentId!) : group(String(w.id));

	return {
		key: keyOf(id),
		id,
		// A topic's name is in `topic`; a group's is in `name`. One field
		// would have been nicer, but here we are.
		name: (isTopic ? w.topic : w.name) || w.name || "",
		avatarUrl: w.image_url ?? null,
		updatedAt: w.messages?.last_message_created_at ?? w.updated_at ?? 0,
		lastMessageId: w.messages?.last_message_id ?? null,
		preview: previewOf(w),
		unreadCount: w.unread_count ?? 0,
		lastReadMessageId: w.last_read_message_id ?? null,
		mutedUntil: w.muted_until ?? null,
		topicIds: [],
		parentId,
		editWindow: w.message_edit_period ?? 0,
		likeIcon: w.like_icon ? { packId: w.like_icon.pack_id, packIndex: w.like_icon.pack_index } : null,
		access: w.type ?? "private",
		description: w.description ?? "",
		shareUrl: w.share_url ?? null,
		creatorId: w.creator_user_id ? String(w.creator_user_id) : null,
	};
}

export function normalizeChat(w: WireChat, selfId: string): Conversation {
	const id = dm(String(w.other_user.id), selfId);
	const last = w.last_message;
	return {
		key: keyOf(id),
		id,
		name: w.other_user.name,
		avatarUrl: w.other_user.avatar_url,
		updatedAt: w.updated_at ?? last?.created_at ?? 0,
		lastMessageId: last?.id ?? null,
		preview: last
			? {
					name: last.name,
					text: last.text ?? previewFromAttachments(last.attachments ?? []),
					imageUrl: firstImage(last.attachments ?? []),
					system: Boolean(last.system),
				}
			: null,
		unreadCount: w.unread_count ?? 0,
		lastReadMessageId: w.last_read_message_id ?? null,
		mutedUntil: null,
		topicIds: [],
		parentId: null,
		editWindow: 0,
		likeIcon: null,
		access: "dm",
		description: "",
		shareUrl: null,
		creatorId: null,
	};
}

function previewOf(w: WireGroup): Preview | null {
	const p = w.messages?.preview;
	if (!p) return null;
	return {
		name: p.nickname ?? "",
		text: p.text ?? previewFromAttachments(p.attachments ?? []),
		imageUrl: firstImage(p.attachments ?? []),
		system: false,
	};
}

/** What to show in the sidebar when the last message was only an attachment. */
function previewFromAttachments(attachments: WireAttachment[]): string {
	const first = attachments.find((a) => a.type !== "reply" && a.type !== "mentions");
	switch (first?.type) {
		case "image":
		case "linked_image":
			return "Photo";
		case "video":
			return "Video";
		case "file":
			return "File";
		case "location":
			return "Location";
		case "poll":
			return "Poll";
		case "event":
			return "Event";
		default:
			return "";
	}
}

function firstImage(attachments: WireAttachment[]): string | null {
	const img = attachments.find((a) => a.type === "image" || a.type === "linked_image");
	const url = (img as { url?: string } | undefined)?.url;
	return url ?? null;
}

// MARK: - People

export function normalizeMember(w: WireMember): Member {
	return {
		membershipId: String(w.id),
		userId: String(w.user_id),
		nickname: w.nickname || w.name || "",
		avatarUrl: w.image_url ?? null,
		muted: Boolean(w.muted),
		roles: w.roles ?? [],
	};
}

export function normalizeCurrentUser(w: WireUser): CurrentUser {
	return {
		id: String(w.id),
		name: w.name,
		avatarUrl: w.image_url ?? null,
		email: w.email ?? null,
		phone: w.phone_number ?? null,
	};
}

// MARK: - Small helpers

function numOrNull(v: unknown): number | null {
	const n = Number(v);
	return Number.isFinite(n) ? n : null;
}

function isString(v: unknown): v is string {
	return typeof v === "string" && v.length > 0;
}

/** System event payloads name people inconsistently. Try the usual spots. */
function pickId(v: unknown): string | undefined {
	if (typeof v === "string" || typeof v === "number") return String(v);
	if (v && typeof v === "object") {
		const o = v as Record<string, unknown>;
		const id = o.id ?? o.user_id ?? o.nickname;
		if (typeof id === "string" || typeof id === "number") return String(id);
	}
	return undefined;
}
