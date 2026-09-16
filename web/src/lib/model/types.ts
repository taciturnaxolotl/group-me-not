import type { ConversationID } from "./conversation-id";
import type { WireAttachment, WireSystemEvent } from "../api/wire";

/**
 * The model the app thinks in.
 *
 * Two rules separate this from `wire.ts`:
 *
 *   1. Nothing here is optional unless its absence is meaningful. The wire
 *      layer is full of fields that are missing for uninteresting reasons; the
 *      normalizer decides what each absence means so that views never have to.
 *   2. Nothing here is a string that should have been a union. `sender_type`
 *      becomes `kind`, `system` plus `event.type` become a discriminated
 *      `SystemEvent`, and so on.
 */

// MARK: - Messages

/** Where a message is in its journey from the composer to the server. */
export type DeliveryState =
	| "sent" // the server has it and gave it an id
	| "pending" // in the outbox, not yet acknowledged
	| "sending" // a request is in flight right now
	| "failed"; // gave up; the user can retry or discard

export interface Message {
	/** Real server id, or a synthetic one for a message still in the outbox. */
	id: string;
	/** Our idempotency key. Stable across retries, which is the point. */
	sourceGuid: string;
	conversationKey: string;
	senderId: string;
	/** Nickname in this conversation, which is not the sender's real name. */
	name: string;
	avatarUrl: string | null;
	text: string;
	createdAt: number;
	/** Set only if the message has been edited since. */
	editedAt: number | null;
	kind: "user" | "system" | "bot";
	delivery: DeliveryState;
	/** Why the send failed, for the retry affordance. Null unless failed. */
	failure: string | null;

	attachments: Attachment[];
	reactions: Reaction[];
	/** Resolved from `attachments`, because a reply is not really an attachment. */
	replyTo: ReplyRef | null;
	/** Resolved from `attachments`, sorted, with bad loci dropped. */
	mentions: Mention[];

	pinnedAt: number | null;
	pinnedBy: string | null;
	/** Set once the message has been deleted. The row is a tombstone. */
	deletedAt: number | null;
	/** Who took it down, as a role. Only meaningful alongside `deletedAt`. */
	deletionActor: DeletionActor;

	/** Structured system payload, when we recognise it. */
	event: SystemEvent | null;
}

export interface ReplyRef {
	messageId: string;
	rootId: string;
	authorId: string | null;
}

export interface Mention {
	userId: string;
	/** Offset into `text`, in UTF-16 code units. */
	start: number;
	length: number;
}

export interface Reaction {
	/** The emoji to draw, or a powerup reference. */
	code: string;
	kind: "unicode" | "powerup";
	userIds: string[];
	packId: number | null;
	packIndex: number | null;
}

// MARK: - Attachments

export type Attachment =
	| { kind: "image"; url: string; width: number | null; height: number | null; blurhash: string | null }
	| { kind: "video"; url: string; posterUrl: string | null; width: number | null; height: number | null }
	| { kind: "file"; fileId: string; name: string | null; size: number | null; mime: string | null }
	| { kind: "location"; lat: number; lng: number; name: string | null }
	| { kind: "poll"; pollId: string }
	| { kind: "event"; eventId: string }
	| { kind: "powerup"; placeholder: string; charmap: [number, number][] }
	/** Anything the server invents after this was written. */
	| { kind: "unknown"; type: string; raw: WireAttachment };

// MARK: - System events

/**
 * System messages, with the common cases pulled out.
 *
 * The long tail is enormous and the server keeps adding to it, so `other`
 * carries the raw payload alongside the server's own English sentence. The UI
 * renders recognised types itself and falls back to `text` otherwise, which
 * means a brand new event type looks slightly plain rather than broken.
 */
export type SystemEvent =
	| { kind: "membersAdded"; userIds: string[]; actorId: string | null }
	| { kind: "memberRemoved"; userId: string; actorId: string | null }
	| { kind: "memberLeft"; userId: string }
	| { kind: "nameChanged"; name: string; actorId: string | null }
	| { kind: "avatarChanged"; actorId: string | null }
	| { kind: "topicChanged"; topic: string; actorId: string | null }
	| { kind: "messagePinned"; messageId: string; actorId: string | null }
	/**
	 * A deletion, reported beside the message it killed rather than on it.
	 *
	 * `messageId` is the *target*, not this notice. The notice is a message in
	 * its own right with its own fresh id, so this is the only place the dead
	 * message's id appears — which is why a delete cannot be applied by the
	 * ordinary "merge this message" path the way an edit can.
	 */
	| { kind: "messageDeleted"; messageId: string; deletedAt: number | null; actor: DeletionActor }
	| { kind: "pollCreated"; pollId: string; subject: string }
	| { kind: "pollFinished"; pollId: string; subject: string; options: PollOption[] }
	| { kind: "callStarted"; actorId: string | null }
	| { kind: "other"; type: string; raw: WireSystemEvent };

/**
 * Who took a message down, as a role rather than a person.
 *
 * `deletion_actor` reads like a user id and is not one. Measured against the
 * live API across 25 groups — 128 deletion notices, 38 surviving tombstones —
 * it was only ever one of these three.
 *
 * The distinction earns its place because the roles behave differently. A
 * `sender` delete leaves the row in place as a tombstone, 34 times out of 34.
 * An `admin` delete usually takes the row away outright: 93 notices against 3
 * tombstones. So for an admin deletion a client that watched it happen is the
 * only thing that will ever mark the gap, because a later fetch will not
 * return the message at all.
 */
export type DeletionActor = "sender" | "admin" | "system";

/**
 * What the transcript says about a deletion.
 *
 * GroupMe writes its own sentence into the tombstone's `text` and varies it by
 * role. Matching that vocabulary keeps a deleted message reading the same here
 * as it does in every other client.
 */
export function deletionSentence(actor: DeletionActor): string {
	switch (actor) {
		case "admin":
			return "An admin deleted this message";
		case "system":
			return "This message was removed";
		default:
			return "This message was deleted";
	}
}

export interface PollOption {
	id: string;
	title: string;
	votes: number;
}

// MARK: - Conversations

export interface Conversation {
	key: string;
	id: ConversationID;
	name: string;
	avatarUrl: string | null;
	/** Last activity, for sorting the sidebar. */
	updatedAt: number;

	/** Null when we have never seen a message here. */
	lastMessageId: string | null;
	preview: Preview | null;

	unreadCount: number;
	lastReadMessageId: string | null;
	mutedUntil: number | null;

	/** Topics hanging off this group. Empty for topics and DMs. */
	topicIds: string[];
	/** For a topic, the group it belongs to. */
	parentId: string | null;

	/** How long after posting the author may still edit, in seconds. */
	editWindow: number;
	/** A group's custom like glyph, when it has one. */
	likeIcon: { packId: number; packIndex: number } | null;
	/** `private`, `public`, `closed`. Affects what actions are offered. */
	access: string;
	description: string;
	shareUrl: string | null;
	creatorId: string | null;
}

export interface Preview {
	/** Nickname of whoever sent the last message. */
	name: string;
	text: string;
	/** A thumbnail for the last message, when it had one. */
	imageUrl: string | null;
	/** Whether the preview describes a system message. */
	system: boolean;
}

export interface Member {
	/** Membership id, needed to remove someone. Not the user id. */
	membershipId: string;
	userId: string;
	nickname: string;
	avatarUrl: string | null;
	muted: boolean;
	roles: string[];
}

export interface Person {
	id: string;
	name: string;
	avatarUrl: string | null;
	blocked: boolean;
}

export interface CurrentUser {
	id: string;
	name: string;
	avatarUrl: string | null;
	email: string | null;
	phone: string | null;
}

// MARK: - Presence

export type PresenceState = "online" | "away" | "offline";

export interface Presence {
	userId: string;
	state: PresenceState;
	/** Epoch seconds, when the server told us. */
	seenAt: number | null;
}

/** Somebody is typing. Expires on its own; see `typing.ts`. */
export interface TypingSignal {
	conversationKey: string;
	userId: string;
	startedAt: number;
}
