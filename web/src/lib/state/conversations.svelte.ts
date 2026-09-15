import type { Conversation, Member, Person, CurrentUser } from "../model/types";
import { keyOf, type ConversationID } from "../model/conversation-id";
import { cmpId, maxId } from "../model/ids";

/**
 * The conversation list, and the shape the sidebar wants it in.
 *
 * GroupMe's own hierarchy is groups, topics inside groups, and DMs. Slack's is
 * sections, channels inside sections, and DMs. Those are the same tree, so the
 * mapping is a rename rather than a translation: a group becomes a section
 * header, its topics become the channels under it, and a group without topics
 * is a section that is just one channel.
 *
 * The one wrinkle is that a group with topics is *also* a conversation in its
 * own right — the "Main Chat". It is listed as the first channel in its own
 * section rather than made clickable as the header, because a header that is
 * sometimes a link and sometimes not is a small cruelty.
 */

export interface SidebarChannel {
	key: string;
	id: ConversationID;
	name: string;
	avatarUrl: string | null;
	unread: number;
	muted: boolean;
	updatedAt: number;
	/** True for the parent group's own chat inside a topic section. */
	isMain: boolean;
}

export interface SidebarSection {
	/** Group id, or one of the synthetic ids below. */
	id: string;
	title: string;
	avatarUrl: string | null;
	channels: SidebarChannel[];
	/** Sum over channels, for the collapsed badge. */
	unread: number;
	/** A plain group with no topics renders without a header. */
	flat: boolean;
	collapsible: boolean;
}

export const DM_SECTION = "__dms";
export const UNREAD_SECTION = "__unread";

export class ConversationsState {
	/** Everything we know about, keyed by `ConversationID.keyOf`. */
	byKey = $state<Map<string, Conversation>>(new Map());
	members = $state<Map<string, Member[]>>(new Map());
	people = $state<Map<string, Person>>(new Map());
	me = $state<CurrentUser | null>(null);

	/** Section ids the user has collapsed. Persisted. */
	collapsed = $state<Set<string>>(new Set());
	/** Sidebar filter: everything, or only chats with something new. */
	filter = $state<"all" | "unread" | "groups" | "dms">("all");
	query = $state("");

	list = $derived([...this.byKey.values()]);

	totalUnread = $derived(
		this.list.reduce((n, c) => n + (c.mutedUntil ? 0 : c.unreadCount), 0),
	);

	/**
	 * The sidebar tree.
	 *
	 * Sorting is by most recent activity at both levels, which is the only
	 * ordering that survives contact with a busy account. Alphabetical looks
	 * tidier in a screenshot and is useless when you have sixty chats.
	 */
	sections = $derived.by((): SidebarSection[] => {
		const q = this.query.trim().toLowerCase();
		const match = (c: Conversation) => !q || c.name.toLowerCase().includes(q);

		const groups = new Map<string, Conversation>();
		const topicsByParent = new Map<string, Conversation[]>();
		const dms: Conversation[] = [];

		for (const c of this.byKey.values()) {
			if (c.id.kind === "dm") dms.push(c);
			else if (c.id.kind === "topic") {
				const list = topicsByParent.get(c.parentId ?? "") ?? [];
				list.push(c);
				topicsByParent.set(c.parentId ?? "", list);
			} else groups.set(c.id.id, c);
		}

		const wantGroups = this.filter === "all" || this.filter === "groups" || this.filter === "unread";
		const wantDms = this.filter === "all" || this.filter === "dms" || this.filter === "unread";
		const unreadOnly = this.filter === "unread";

		const keep = (c: Conversation) => match(c) && (!unreadOnly || c.unreadCount > 0);

		const sections: SidebarSection[] = [];

		if (wantGroups) {
			for (const [gid, g] of groups) {
				const topics = (topicsByParent.get(gid) ?? []).filter(keep);
				const selfKeeps = keep(g);
				if (!selfKeeps && !topics.length) continue;

				const channels: SidebarChannel[] = [];
				if (selfKeeps) channels.push(toChannel(g, topics.length > 0));
				for (const t of topics.sort((a, b) => b.updatedAt - a.updatedAt)) {
					channels.push(toChannel(t, false));
				}

				sections.push({
					id: gid,
					title: g.name,
					avatarUrl: g.avatarUrl,
					channels,
					unread: channels.reduce((n, c) => n + (c.muted ? 0 : c.unread), 0),
					flat: topics.length === 0,
					collapsible: topics.length > 0,
				});
			}
		}

		// Newest activity first, measured across the whole section so a busy
		// topic pulls its group up with it.
		sections.sort((a, b) => latest(b) - latest(a));

		if (wantDms) {
			const kept = dms.filter(keep).sort((a, b) => b.updatedAt - a.updatedAt);
			if (kept.length) {
				sections.push({
					id: DM_SECTION,
					title: "Direct messages",
					avatarUrl: null,
					channels: kept.map((c) => toChannel(c, false)),
					unread: kept.reduce((n, c) => n + (c.mutedUntil ? 0 : c.unreadCount), 0),
					flat: false,
					collapsible: true,
				});
			}
		}

		return sections;
	});

	get(key: string): Conversation | undefined {
		return this.byKey.get(key);
	}

	upsert(convs: Conversation[]): void {
		if (!convs.length) return;
		const next = new Map(this.byKey);
		for (const c of convs) {
			const prev = next.get(c.key);
			// A conversation arrives from several places — the list endpoints,
			// a push event, a subgroup fetch — and they do not all carry the
			// same fields. Merging rather than replacing stops a partial
			// update from blanking a badge that a fuller one just set.
			next.set(c.key, reconcileUnread(prev ? mergeConversation(prev, c) : c));
		}
		this.byKey = next;
	}

	/** Fold in the read marks from `/v4/read_receipts`. */
	applyReadReceipts(receipts: { conversation_id: string; last_read_message_id: string }[]): void {
		const next = new Map(this.byKey);
		let changed = false;
		for (const r of receipts) {
			// The receipt is keyed by REST id, which for a DM is the `a+b`
			// pair rather than the other person's id, so a straight lookup
			// misses every DM.
			const key = this.#keyForRestId(r.conversation_id);
			const c = key ? next.get(key) : undefined;
			if (!c) continue;
			// Take the newer of the two cursors. The one embedded in the group
			// list lags the dedicated endpoint badly — measured months behind
			// on live data — so neither can simply overwrite the other.
			const merged = maxId(c.lastReadMessageId, r.last_read_message_id);
			if (merged === c.lastReadMessageId) continue;
			next.set(c.key, reconcileUnread({ ...c, lastReadMessageId: merged }));
			changed = true;
		}
		if (changed) this.byKey = next;
	}

	#restIdIndex = $derived.by(() => {
		const index = new Map<string, string>();
		for (const c of this.byKey.values()) {
			if (c.id.kind === "dm") {
				const [lo, hi] =
					BigInt(c.id.selfId) < BigInt(c.id.id) ? [c.id.selfId, c.id.id] : [c.id.id, c.id.selfId];
				index.set(`${lo}+${hi}`, c.key);
			} else index.set(c.id.id, c.key);
		}
		return index;
	});

	#keyForRestId(restId: string): string | undefined {
		return this.#restIdIndex.get(restId);
	}

	/** Local read state, applied optimistically when a chat is opened. */
	markRead(key: string, upTo: string): void {
		const c = this.byKey.get(key);
		if (!c) return;
		if (c.lastReadMessageId && cmpId(c.lastReadMessageId, upTo) >= 0 && c.unreadCount === 0) return;
		const next = new Map(this.byKey);
		next.set(key, { ...c, lastReadMessageId: upTo, unreadCount: 0 });
		this.byKey = next;
	}

	/** Bump activity when a message lands, so the sidebar reorders at once. */
	noteActivity(key: string, messageId: string, createdAt: number, unread: boolean): void {
		const c = this.byKey.get(key);
		if (!c) return;
		const next = new Map(this.byKey);
		next.set(key, {
			...c,
			lastMessageId: c.lastMessageId && cmpId(c.lastMessageId, messageId) > 0 ? c.lastMessageId : messageId,
			updatedAt: Math.max(c.updatedAt, createdAt),
			unreadCount: unread ? c.unreadCount + 1 : c.unreadCount,
		});
		this.byKey = next;
	}

	toggleSection(id: string): void {
		const next = new Set(this.collapsed);
		next.has(id) ? next.delete(id) : next.add(id);
		this.collapsed = next;
		localStorage.setItem("gmn.collapsed", JSON.stringify([...next]));
	}

	restoreCollapsed(): void {
		try {
			const raw = JSON.parse(localStorage.getItem("gmn.collapsed") ?? "[]");
			if (Array.isArray(raw)) this.collapsed = new Set(raw.map(String));
		} catch {}
	}

	memberName(groupId: string | null, userId: string): string | null {
		if (groupId) {
			const m = this.members.get(groupId)?.find((x) => x.userId === userId);
			if (m) return m.nickname;
		}
		return this.people.get(userId)?.name ?? null;
	}

	memberAvatar(groupId: string | null, userId: string): string | null {
		if (groupId) {
			const m = this.members.get(groupId)?.find((x) => x.userId === userId);
			if (m?.avatarUrl) return m.avatarUrl;
		}
		return this.people.get(userId)?.avatarUrl ?? null;
	}
}

/**
 * Zero a badge whose cursor has already passed the last message.
 *
 * The server's `unread_count` cannot be trusted on its own, and this is not a
 * rare edge. Measured across one real account: sixteen groups reported a
 * non-zero count and fifteen of them had a read cursor at or past their own
 * newest message. One claimed forty-six unread in a conversation that had been
 * read to the end. The official web client shows nothing for those, which is
 * the giveaway that it is not reading the field either.
 *
 * The tally and the cursor are two parties writing the same fact, and the
 * cursor is the one that gets updated when you actually read something. So the
 * cursor is the state worth keeping and the badge is a view of it: when the
 * cursor is caught up the count is zero whatever the tally claims, and only
 * when it is genuinely behind do we fall back to the server's number as an
 * estimate of how far.
 */
function reconcileUnread(c: Conversation): Conversation {
	if (!c.unreadCount) return c;
	if (!c.lastMessageId || !c.lastReadMessageId) return c;
	if (cmpId(c.lastReadMessageId, c.lastMessageId) < 0) return c;
	return { ...c, unreadCount: 0 };
}

function toChannel(c: Conversation, isMain: boolean): SidebarChannel {
	return {
		key: c.key,
		id: c.id,
		name: isMain ? "Main" : c.name,
		avatarUrl: c.avatarUrl,
		unread: c.unreadCount,
		muted: Boolean(c.mutedUntil && c.mutedUntil * 1000 > Date.now()),
		updatedAt: c.updatedAt,
		isMain,
	};
}

function latest(s: SidebarSection): number {
	let t = 0;
	for (const c of s.channels) if (c.updatedAt > t) t = c.updatedAt;
	return t;
}

/**
 * Merge two views of the same conversation.
 *
 * The rule is that a field only moves forward. `unread_count` is the field
 * that makes this necessary: the subgroups route omits it, so a topic refresh
 * that replaced wholesale would clear a badge that the groups route had just
 * set correctly.
 */
function mergeConversation(prev: Conversation, next: Conversation): Conversation {
	return {
		...prev,
		...next,
		name: next.name || prev.name,
		avatarUrl: next.avatarUrl ?? prev.avatarUrl,
		updatedAt: Math.max(prev.updatedAt, next.updatedAt),
		lastMessageId:
			prev.lastMessageId && next.lastMessageId
				? cmpId(prev.lastMessageId, next.lastMessageId) > 0
					? prev.lastMessageId
					: next.lastMessageId
				: (next.lastMessageId ?? prev.lastMessageId),
		preview: next.preview ?? prev.preview,
		unreadCount: next.unreadCount || prev.unreadCount,
		lastReadMessageId: maxId(prev.lastReadMessageId, next.lastReadMessageId),
		topicIds: next.topicIds.length ? next.topicIds : prev.topicIds,
		editWindow: next.editWindow || prev.editWindow,
		description: next.description || prev.description,
	};
}

export { keyOf };
