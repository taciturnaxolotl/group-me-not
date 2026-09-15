/**
 * The shapes the server actually sends, named as the server names them.
 *
 * Nothing in here is renamed, tidied, or made optional-where-it-should-be.
 * That work happens once, in `normalize.ts`. Keeping the wire layer honest
 * means that when the API changes, the diff shows up here rather than as a
 * mystery `undefined` four layers up.
 */

// MARK: - Attachments

/**
 * The attachment union.
 *
 * The tag is `type`, and the server will happily send types this client has
 * never heard of. Every consumer must tolerate that: the normalizer keeps
 * unknown attachments rather than dropping them, so a future attachment kind
 * degrades to "there is something here we cannot draw" instead of vanishing.
 */
export type WireAttachment =
	| WireImageAttachment
	| WireLinkedImageAttachment
	| WireVideoAttachment
	| WireFileAttachment
	| WireLocationAttachment
	| WireReplyAttachment
	| WireMentionsAttachment
	| WireEmojiAttachment
	| WirePollAttachment
	| WireEventAttachment
	| WireUnknownAttachment;

export interface WireImageAttachment {
	type: "image";
	url: string;
	/** Present on some newer uploads; four numbers, base83. */
	blurhash?: string;
	width?: number;
	height?: number;
}

/** An image the sender linked rather than uploaded. Same rendering, no CDN. */
export interface WireLinkedImageAttachment {
	type: "linked_image";
	url: string;
}

export interface WireVideoAttachment {
	type: "video";
	/** The `.mp4` on v.groupme.com. */
	url: string;
	/** Poster frame. Always present in practice, but check anyway. */
	preview_url?: string;
	width?: number;
	height?: number;
}

export interface WireFileAttachment {
	type: "file";
	/** Not a URL. Exchange it for one via `POST /v2/files/{conv}/{id}`. */
	file_id: string;
	/** Sometimes present, sometimes only discoverable from the file service. */
	file_name?: string;
	file_size?: number;
	file_type?: string;
}

export interface WireLocationAttachment {
	type: "location";
	lat: string;
	lng: string;
	name?: string;
}

export interface WireReplyAttachment {
	type: "reply";
	/** The message being replied to. */
	reply_id: string;
	/**
	 * The root of the reply chain. Usually equal to `reply_id`; differs when
	 * someone replies to a reply. Worth keeping for jump-to-source.
	 */
	base_reply_id?: string;
	/** Author of the quoted message. */
	user_id?: string;
}

/**
 * Mentions, as parallel arrays.
 *
 * `user_ids[i]` is mentioned at `loci[i]`, which is `[start, length]` measured
 * in UTF-16 code units over `message.text`. The two arrays are supposed to be
 * the same length and occasionally are not, which the normalizer handles.
 */
export interface WireMentionsAttachment {
	type: "mentions";
	user_ids: string[];
	loci: [number, number][];
}

/** GroupMe's custom emoji, aka powerups. `charmap` indexes into a pack. */
export interface WireEmojiAttachment {
	type: "emoji";
	placeholder: string;
	charmap: [number, number][];
}

export interface WirePollAttachment {
	type: "poll";
	poll_id: string;
}

export interface WireEventAttachment {
	type: "event";
	event_id: string;
	view?: string;
}

export interface WireUnknownAttachment {
	type: string;
	[key: string]: unknown;
}

// MARK: - Reactions

/**
 * A reaction bucket: one emoji and everyone who picked it.
 *
 * `favorited_by` on the message is the flattened union of every bucket's
 * `user_ids`, kept for compatibility with the old like-only model. The two
 * must agree, and when they disagree the server considers `reactions`
 * authoritative.
 */
export interface WireReaction {
	/** `unicode` for a plain emoji, `emoji` for a GroupMe powerup. */
	type: "unicode" | "emoji" | string;
	/** The emoji itself when `type` is `unicode`. */
	code: string;
	user_ids: string[];
	/** Powerup pack, present when `type` is `emoji`. */
	pack_id?: number;
	pack_index?: number;
}

// MARK: - Messages

export interface WireMessage {
	id: string;
	source_guid: string;
	created_at: number;
	user_id: string;
	/** `"system"` for system messages, otherwise the sender's id again. */
	sender_id: string;
	sender_type: "user" | "system" | "bot" | string;
	name: string;
	avatar_url: string | null;
	text: string | null;
	system?: boolean;
	attachments: WireAttachment[];
	favorited_by: string[];
	reactions?: WireReaction[];

	/** Present on group and topic messages. */
	group_id?: string;
	/** Present on DMs; the `a+b` pair id. */
	conversation_id?: string;
	/** Present on DMs. */
	recipient_id?: string;

	platform?: string;
	pinned_at?: number | null;
	pinned_by?: string;

	/** Structured payload behind a system message. See `event.type`. */
	event?: WireSystemEvent;

	/** Set once the message has been edited. */
	updated_at?: number;
	deleted_at?: number | null;
}

/**
 * The structured half of a system message.
 *
 * `message.text` is the server's own English rendering of the same thing
 * ("Kieran added Jacen to the group"). Prefer the structured form when a type
 * is recognised, because it can be localised and can link the names; fall back
 * to `text` for the long tail, which is large and still growing.
 */
export interface WireSystemEvent {
	type: string;
	data?: Record<string, unknown>;
}

// MARK: - Conversations

export interface WireGroup {
	id: string;
	name: string;
	type: "private" | "public" | "closed" | string;
	description?: string;
	image_url: string | null;
	creator_user_id: string;
	created_at: number;
	updated_at: number;
	muted_until?: number | null;
	office_mode?: boolean;
	share_url?: string | null;
	members?: WireMember[];
	messages: WireGroupMessagesSummary;
	/** Only on `include=unread_count`, which is why that param is not optional. */
	unread_count?: number | null;
	last_read_message_id?: string | null;
	last_read_at?: number | null;
	/** Seconds after posting during which the author may still edit. */
	message_edit_period?: number;
	like_icon?: WireLikeIcon | null;
	/** Set on a topic, absent on a top-level group. */
	parent_id?: string | number;
	/** A topic's name lives here rather than in `name`. */
	topic?: string;
	theme_name?: string | null;
	requires_approval?: boolean;
	show_join_question?: boolean;
	join_question?: { type: string; text: string } | null;
}

export interface WireLikeIcon {
	pack_id: number;
	pack_index: number;
	type: string;
}

export interface WireGroupMessagesSummary {
	count: number;
	last_message_id: string;
	last_message_created_at: number;
	last_message_updated_at?: number;
	preview: {
		nickname: string;
		text: string | null;
		image_url: string | null;
		attachments: WireAttachment[];
	};
}

export interface WireMember {
	/** The membership id. Not the user id; needed to remove someone. */
	id: string;
	user_id: string;
	nickname: string;
	name?: string;
	image_url: string | null;
	muted?: boolean;
	autokicked?: boolean;
	roles?: string[];
}

/** An entry from `GET /v3/chats` — the DM list. */
export interface WireChat {
	created_at: number;
	updated_at: number;
	last_message: WireMessage;
	messages_count: number;
	unread_count?: number | null;
	last_read_message_id?: string | null;
	last_read_at?: number | null;
	other_user: {
		id: string;
		name: string;
		avatar_url: string | null;
	};
}

// MARK: - People

export interface WireUser {
	id: string;
	name: string;
	image_url: string | null;
	email?: string;
	phone_number?: string | null;
	created_at?: number;
	updated_at?: number;
	sms?: boolean;
	locale?: string;
	tag?: string | null;
	/** Profile extras the newer clients render. */
	bio?: string | null;
	birth_date?: string | null;
	interests?: WireInterest[];
	profile_pictures?: { url: string; id?: string }[];
}

export interface WireInterest {
	id?: string;
	name: string;
	emoji?: string;
	category?: string;
}

/** `GET /v4/relationships` — the address book, cursor paginated. */
export interface WireRelationship {
	user_id: string;
	name: string;
	avatar_url: string | null;
	blocked?: boolean;
	app_installed?: boolean;
	mri?: string;
	relation_type?: string;
}

// MARK: - Read state

/** `GET /v4/read_receipts` — every conversation's read mark in one shot. */
export interface WireReadReceipt {
	/** A group id, a topic id, or an `a+b` DM pair id. */
	conversation_id: string;
	last_read_message_id: string;
}

// MARK: - Uploads

export interface WireImageUploadResponse {
	payload: { url: string; picture_url?: string };
}

export interface WireVideoUploadResponse {
	status_url: string;
}

export interface WireVideoStatusResponse {
	status: "pending" | "complete" | "failed" | string;
	url?: string;
	thumbnail_url?: string;
}

export interface WireFileUploadResponse {
	status: string;
	/** Poll this until it yields a `file_id`. */
	status_url?: string;
	file_id?: string;
}

// MARK: - Push

/**
 * The envelope on a Bayeux event.
 *
 * Note the shadowing: the Bayeux frame has a `data` field, and `data` here has
 * its own `subject`, which is the thing you actually want. Three levels of
 * wrapper before the message.
 */
export interface WirePushEnvelope {
	type: string;
	subject?: unknown;
	alert?: string | null;
	/** Present on `ping`, absent on most others. */
	id?: string;
}
