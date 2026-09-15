/**
 * One identifier for the three things GroupMe calls conversations.
 *
 * The API is three APIs wearing one coat. A group has `/groups/{id}/messages`;
 * a DM has `/direct_messages?other_user_id={id}`; a topic inside a group has
 * `/groups/{id}/messages` again but with a different id and a parent. On top of
 * that, likes, read receipts and uploads all want a fourth thing: a "REST id"
 * that for a DM is the two user ids joined with `+` in numeric order.
 *
 * Every one of those differences is an opportunity to write `if (isDM)` at a
 * call site. This type exists so that never happens above the API layer: views
 * and the store hold a `ConversationID`, and only `api/groupme.ts` unpacks it.
 */

export type ConversationKind = "group" | "dm" | "topic";

export interface GroupConversation {
	kind: "group";
	/** The group id. */
	id: string;
}

export interface TopicConversation {
	kind: "topic";
	/** The subgroup's own id. Messages live under this, not the parent. */
	id: string;
	/** The group this topic belongs to. Needed for members and settings. */
	parentId: string;
}

export interface DmConversation {
	kind: "dm";
	/** The *other* person's user id. */
	id: string;
	/** Our own id. Needed to build the `a+b` REST id. */
	selfId: string;
}

export type ConversationID = GroupConversation | TopicConversation | DmConversation;

export const group = (id: string): ConversationID => ({ kind: "group", id });
export const topic = (id: string, parentId: string): ConversationID => ({
	kind: "topic",
	id,
	parentId,
});
export const dm = (otherId: string, selfId: string): ConversationID => ({
	kind: "dm",
	id: otherId,
	selfId,
});

/**
 * A stable string key for maps, IndexedDB, and the URL.
 *
 * Deliberately not just the raw id: a group id and a user id can collide, and
 * a topic needs its parent to be addressable after a reload.
 */
export function keyOf(c: ConversationID): string {
	switch (c.kind) {
		case "group":
			return `g:${c.id}`;
		case "topic":
			return `t:${c.parentId}:${c.id}`;
		case "dm":
			return `d:${c.id}`;
	}
}

export function parseKey(key: string, selfId: string): ConversationID | null {
	const parts = key.split(":");
	if (parts[0] === "g" && parts[1]) return group(parts[1]);
	if (parts[0] === "d" && parts[1]) return dm(parts[1], selfId);
	if (parts[0] === "t" && parts[1] && parts[2]) return topic(parts[2], parts[1]);
	return null;
}

/**
 * The id the likes, read-receipt, upload and push routes use.
 *
 * For groups and topics it is just the id. For DMs it is both user ids joined
 * with `+`, sorted numerically — `103948919+131883422`, never
 * `131883422+103948919`. The server does not sort it for you and returns a 404
 * for the wrong order, which reads like "this conversation does not exist"
 * rather than "you sorted your ids wrong".
 */
export function restId(c: ConversationID): string {
	if (c.kind !== "dm") return c.id;
	return joinUserIds(c.selfId, c.id, "+");
}

/** The same pair, joined the way the push channel wants it. See `dmChannel`. */
export function pushPairId(c: DmConversation): string {
	return joinUserIds(c.selfId, c.id, "_");
}

function joinUserIds(a: string, b: string, sep: string): string {
	// Numeric order, not lexicographic: "99" sorts after "100" as a string and
	// before it as a number, and user ids cross that boundary all the time.
	const [lo, hi] = BigInt(a) < BigInt(b) ? [a, b] : [b, a];
	return `${lo}${sep}${hi}`;
}

/** The group whose members and settings apply here. Null for DMs. */
export function owningGroupId(c: ConversationID): string | null {
	if (c.kind === "group") return c.id;
	if (c.kind === "topic") return c.parentId;
	return null;
}

export function sameConversation(a: ConversationID, b: ConversationID): boolean {
	return keyOf(a) === keyOf(b);
}
