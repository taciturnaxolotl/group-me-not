import type { WireMessage } from "../api/wire";

/**
 * Decoding what arrives on a Bayeux channel.
 *
 * The envelope is three layers deep and each layer reuses the word "type" for
 * something different, which is the single most confusing thing about this
 * API. From outside in:
 *
 *   1. the Bayeux frame     `{ channel, data }`
 *   2. the push envelope    `{ type, subject, user_id }`  <- `data`
 *   3. the subject          a REST object, e.g. a whole message
 *
 * and separately, a *system message* carries its own `event.type`, which is a
 * third vocabulary that has nothing to do with (2). A `line.create` whose
 * subject is a system message is both at once.
 */

export type PushEvent =
	| { kind: "message"; message: WireMessage; conversationHint: string }
	| { kind: "messageUpdated"; message: WireMessage }
	| { kind: "messageDeleted"; messageId: string; groupId: string | null }
	| { kind: "reaction"; messageId: string; groupId: string | null; subject: WireMessage | null }
	| { kind: "typing"; conversationId: string; userId: string }
	| { kind: "membership"; groupId: string | null }
	| { kind: "ping" }
	| { kind: "unknown"; type: string; raw: unknown };

interface Envelope {
	type?: string;
	subject?: Record<string, unknown>;
	user_id?: string;
	alert?: string;
}

/**
 * Turn one Bayeux payload into something the sync engine can act on.
 *
 * Unknown types are surfaced rather than swallowed. GroupMe adds event types
 * without announcing them, and a client that silently drops the unrecognised
 * ones has no way of noticing that it has started missing something.
 */
export function decodePush(channel: string, data: unknown): PushEvent {
	if (!data || typeof data !== "object") return { kind: "unknown", type: "", raw: data };
	const env = data as Envelope;
	const type = env.type ?? "";
	const subject = env.subject;

	switch (type) {
		case "line.create":
		case "direct_message.create": {
			if (!subject || typeof subject.id !== "string") break;
			const msg = subject as unknown as WireMessage;
			// Which conversation this belongs to is carried by the subject,
			// not the channel. For a topic, `group_id` is the *topic's* own
			// id, not its parent's — which is exactly what we want, since
			// topics are addressed as conversations in their own right.
			const hint = String(msg.group_id ?? msg.conversation_id ?? "");
			return { kind: "message", message: msg, conversationHint: hint };
		}

		case "message.update":
		case "line.update": {
			if (!subject || typeof subject.id !== "string") break;
			return { kind: "messageUpdated", message: subject as unknown as WireMessage };
		}

		case "message.deleted":
		case "line.delete": {
			const id = subject?.id ?? subject?.message_id;
			if (typeof id !== "string") break;
			return { kind: "messageDeleted", messageId: id, groupId: strOrNull(subject?.group_id) };
		}

		case "favorite":
		case "like.create":
		case "like.delete":
		case "reaction": {
			// The subject is the whole message with its reactions already
			// recalculated, which is convenient: there is no need to apply a
			// delta, just replace what we hold.
			const msg = subject && typeof subject.id === "string" ? (subject as unknown as WireMessage) : null;
			const id = msg?.id ?? strOrNull(subject?.message_id) ?? "";
			if (!id) break;
			return { kind: "reaction", messageId: id, groupId: strOrNull(subject?.group_id), subject: msg };
		}

		case "typing": {
			// Typing is the one thing clients publish as well as receive. It
			// rides the group or DM channel, never `/user`, so the channel is
			// the only place the conversation id appears.
			const conv = channel.replace(/^\/(group|direct_message)\//, "");
			return { kind: "typing", conversationId: conv, userId: String(env.user_id ?? "") };
		}

		case "ping":
			return { kind: "ping" };

		case "membership.create":
		case "membership.destroy":
		case "group.update":
			return { kind: "membership", groupId: strOrNull(subject?.group_id ?? subject?.id) };
	}

	return { kind: "unknown", type, raw: data };
}

function strOrNull(v: unknown): string | null {
	return typeof v === "string" || typeof v === "number" ? String(v) : null;
}

/**
 * Which channels this account needs.
 *
 * Just the one, for messages.
 *
 * `docs/push.md` says topics are the exception — that a message posted to a
 * topic produces nothing on `/user/{me}` and each topic must be subscribed
 * separately. That was true once and is not true now. Measured directly:
 * subscribe to `/user/{me}`, `/group/{topicId}` and `/group/{parentId}`, all
 * three succeed, then post to the topic and to the parent. Both messages
 * arrive on `/user/{me}` and nothing at all arrives on either group channel,
 * each tagged with its own `group_id`:
 *
 *     { channel: "/user/131883422", type: "line.create", gid: "117096707" }  // topic
 *     { channel: "/user/131883422", type: "line.create", gid: "117088005" }  // parent
 *
 * So one subscription covers every conversation including topics. Group
 * channels are still worth subscribing to for the conversation on screen,
 * because typing indicators only ever go there.
 */
export function messageChannels(selfId: string): string[] {
	return [`/user/${selfId}`];
}
