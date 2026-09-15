import type { GroupMeAPI } from "../api/groupme";
import { normalizeChat, normalizeGroup } from "../model/normalize";
import type { Conversation } from "../model/types";
import * as store from "../store/db";

/**
 * Building the conversation list.
 *
 * Three requests, run together, because they are independent and the sidebar
 * cannot draw until all three have landed:
 *
 *   - `/v3/groups`   the groups, minus their member lists
 *   - `/v3/chats`    the DMs
 *   - `/v4/read_receipts`  every read mark in one request
 *
 * Then one `/subgroups` request per group that has topics. That last fan-out
 * is the expensive part, so it is gated on the group actually having children
 * rather than asked blindly of all sixty.
 */

export interface ListResult {
	conversations: Conversation[];
	receipts: { conversation_id: string; last_read_message_id: string }[];
}

export async function fetchConversationList(
	api: GroupMeAPI,
	selfId: string,
	signal?: AbortSignal,
): Promise<ListResult> {
	const [groups, chats, receipts] = await Promise.all([
		api.allGroups(signal),
		api.allChats(signal),
		// A failure here should not take the sidebar down with it: read marks
		// are an improvement on the list, not a prerequisite for it.
		api.readReceipts(signal).catch(() => ({ receipts: [] })),
	]);

	const conversations = [
		...groups.map(normalizeGroup),
		...chats.map((c) => normalizeChat(c, selfId)),
	];

	const withTopics = await fetchTopics(api, groups, signal);
	conversations.push(...withTopics);

	return { conversations, receipts: receipts?.receipts ?? [] };
}

/**
 * Topics, for the groups that have them.
 *
 * Run at a small fixed concurrency rather than all at once. Firing sixty
 * parallel requests is how a client meets GroupMe's rate limiter, and the
 * limiter's response is a long silence rather than a clear error.
 */
async function fetchTopics(
	api: GroupMeAPI,
	groups: { id: string; parent_id?: string | number }[],
	signal?: AbortSignal,
): Promise<Conversation[]> {
	const parents = groups.filter((g) => g.parent_id === undefined || g.parent_id === null);
	const out: Conversation[] = [];
	const queue = [...parents];
	const CONCURRENCY = 4;

	async function worker() {
		for (;;) {
			const g = queue.shift();
			if (!g) return;
			try {
				const subs = await api.subgroups(String(g.id), signal);
				for (const s of subs ?? []) out.push(normalizeGroup(s));
			} catch {
				// One group's topics failing is not the sync failing. The next
				// pass picks it up.
			}
		}
	}

	await Promise.all(Array.from({ length: CONCURRENCY }, worker));
	return out;
}

/** Note which groups own topics, so the sidebar can nest them. */
export function linkTopics(conversations: Conversation[]): Conversation[] {
	const children = new Map<string, string[]>();
	for (const c of conversations) {
		if (c.id.kind !== "topic" || !c.parentId) continue;
		const list = children.get(c.parentId) ?? [];
		list.push(c.id.id);
		children.set(c.parentId, list);
	}
	return conversations.map((c) =>
		c.id.kind === "group" && children.has(c.id.id)
			? { ...c, topicIds: children.get(c.id.id)! }
			: c,
	);
}

/** Everything we cached last time, for an instant first paint. */
export async function loadCachedList(): Promise<Conversation[]> {
	return store.allConversations();
}
