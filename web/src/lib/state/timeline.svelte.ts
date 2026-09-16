import type { Message } from "../model/types";
import { cmpId } from "../model/ids";

/**
 * One conversation's transcript, and the rows a renderer draws.
 *
 * The grouping decisions live here rather than in the component because they
 * are a pure function of the message list, and because getting them wrong is
 * the difference between a transcript that reads like a conversation and one
 * that reads like a log file.
 */

export type Row =
	| { kind: "message"; message: Message; grouped: boolean; key: string }
	| { kind: "dateSeparator"; label: string; key: string }
	| { kind: "unreadDivider"; count: number; key: string };

/**
 * How long a pause breaks a run of messages from one person.
 *
 * Five minutes, matching Slack. The number is arbitrary but the behaviour is
 * not: without it, someone who says four things in eight seconds gets four
 * avatars and four timestamps, and the eye reads four separate events.
 */
const GROUP_WINDOW_SECONDS = 5 * 60;

export class Timeline {
	readonly key: string;

	/** Oldest first. The order everything else assumes. */
	messages = $state<Message[]>([]);

	/** Paging state, so the scroller knows whether to show a spinner. */
	loadingOlder = $state(false);
	loadingNewer = $state(false);
	/** We have paged back to the first message in the conversation. */
	atFloor = $state(false);
	/** First load has completed at least once. */
	hydrated = $state(false);

	/**
	 * Where the unread divider goes, frozen on open.
	 *
	 * Deliberately *not* reactive to the read mark. If it tracked the live
	 * value it would vanish the instant the conversation is marked read, which
	 * is immediately, and the divider would never be visible at all. It is
	 * captured when the conversation opens and stays put until it is left.
	 */
	unreadFrom = $state<string | null>(null);

	/** Somebody is typing, by user id, with an expiry. */
	typing = $state<Map<string, number>>(new Map());

	constructor(key: string) {
		this.key = key;
	}

	oldestId = $derived(this.messages[0]?.id ?? null);
	newestId = $derived.by(() => {
		for (let i = this.messages.length - 1; i >= 0; i--) {
			const m = this.messages[i];
			if (m && m.delivery === "sent") return m.id;
		}
		return null;
	});

	/**
	 * The render list: messages, date separators, and the unread divider.
	 *
	 * Built in one pass so the component stays a dumb `{#each}` — the less
	 * logic in the loop, the less there is to re-run when one message changes.
	 */
	/**
	 * What actually gets drawn, once a deletion has been reduced to one thing.
	 *
	 * GroupMe reports a deletion twice: the message comes back as a tombstone
	 * with `deleted_at` set and its text replaced, *and* a separate system
	 * notice is posted saying a message was deleted. Render both and every
	 * delete leaves two grey rows; delete seven things and the transcript is
	 * fourteen rows of nothing.
	 *
	 * So one half is drawn and the other dropped, and which is which matters.
	 * The tombstone keeps its author, its place in the conversation and its
	 * time, so it can say "Kieran deleted a message" exactly where the message
	 * was. The notice knows none of that and would be a grey line from nobody.
	 * Dropping *both*, which this used to do, leaves a silent hole that reads
	 * like a client which lost a message rather than a person who took one
	 * back.
	 */
	visible = $derived(
		this.messages.filter((m) => {
			if (m.kind === "system" && m.event?.kind === "messageDeleted") return false;
			if (m.kind === "system" && m.event?.kind === "other" && m.event.type.startsWith("message."))
				return false;
			return true;
		}),
	);

	rows = $derived.by((): Row[] => {
		const out: Row[] = [];
		let lastDay = "";
		let prev: Message | null = null;
		let dividerPlaced = false;

		const source = this.visible;
		const unreadIndex = this.unreadFrom
			? source.findIndex((m) => cmpId(m.id, this.unreadFrom!) > 0)
			: -1;

		for (let i = 0; i < source.length; i++) {
			const m = source[i]!;

			const day = dayKey(m.createdAt);
			if (day !== lastDay) {
				out.push({ kind: "dateSeparator", label: dayLabel(m.createdAt), key: `d:${day}` });
				lastDay = day;
				prev = null; // a new day always starts a fresh run
			}

			if (!dividerPlaced && unreadIndex >= 0 && i === unreadIndex) {
				out.push({ kind: "unreadDivider", count: source.length - i, key: `u:${m.id}` });
				dividerPlaced = true;
				prev = null; // never group across the divider
			}

			out.push({ kind: "message", message: m, grouped: canGroup(prev, m), key: m.id });
			prev = m;
		}
		return out;
	});

	typingNames = $derived.by(() => {
		// `now` is read from reactive state rather than from `Date.now()`
		// directly, because a derived only recomputes when something it read
		// changes — and a clock is not something it can read. Without the
		// ticker below, the indicator appears on the first event and then
		// stays forever, since nothing ever invalidates it again.
		const now = this.#tick;
		return [...this.typing.entries()].filter(([, until]) => until > now).map(([id]) => id);
	});

	/** Wall clock, advanced only while somebody is typing. */
	#tick = $state(Date.now());
	#expiry: ReturnType<typeof setTimeout> | null = null;

	// MARK: - Mutation

	/**
	 * Merge a page of messages in.
	 *
	 * Dedupes on id, and — importantly — on `source_guid`, because a message
	 * we sent optimistically is already in the list under a synthetic id when
	 * the server's copy of it arrives. Matching only on id would show it twice.
	 */
	merge(incoming: Message[]): void {
		if (!incoming.length) return;

		const byId = new Map(this.messages.map((m) => [m.id, m]));
		const byGuid = new Map(
			this.messages.filter((m) => m.sourceGuid).map((m) => [m.sourceGuid, m]),
		);

		for (const m of incoming) {
			const shadow = byGuid.get(m.sourceGuid);
			if (shadow && shadow.id !== m.id) {
				// The real thing has arrived. Drop the placeholder rather than
				// letting both live.
				byId.delete(shadow.id);
				byGuid.delete(shadow.sourceGuid);
			}
			const existing = byId.get(m.id);
			byId.set(m.id, existing ? { ...existing, ...m } : m);
			if (m.sourceGuid) byGuid.set(m.sourceGuid, m);
		}

		this.messages = [...byId.values()].sort((a, b) => cmpId(a.id, b.id));
	}

	replace(id: string, next: Message): void {
		const i = this.messages.findIndex((m) => m.id === id);
		if (i < 0) return;
		const copy = [...this.messages];
		copy[i] = next;
		// An id change reorders, which happens exactly once per message: when
		// a pending send is acknowledged and swaps its synthetic id for a real
		// one that sorts earlier than the next optimistic message.
		this.messages = id === next.id ? copy : copy.sort((a, b) => cmpId(a.id, b.id));
	}

	remove(id: string): void {
		this.messages = this.messages.filter((m) => m.id !== id);
	}

	find(id: string): Message | undefined {
		return this.messages.find((m) => m.id === id);
	}

	noteTyping(userId: string): void {
		// 1.5 seconds after the last event, matching what other clients use.
		// There is no "stopped typing" message; the indicator only ever
		// expires, so agreeing on the timeout is the whole protocol.
		const until = Date.now() + 1500;
		const next = new Map(this.typing);
		next.set(userId, until);
		this.typing = next;

		// Something has to wake the derived up when the timeout passes, or the
		// row sits there claiming somebody is still typing until the next
		// unrelated re-render. Scheduled from the soonest expiry rather than
		// on an interval, so an idle conversation costs no timers at all.
		this.#scheduleExpiry();
	}

	#scheduleExpiry(): void {
		if (this.#expiry) clearTimeout(this.#expiry);
		const soonest = Math.min(...this.typing.values());
		if (!Number.isFinite(soonest)) return;
		this.#expiry = setTimeout(
			() => {
				this.#tick = Date.now();
				// Drop expired entries so the map cannot grow without bound in
				// a busy group.
				const now = this.#tick;
				const live = new Map([...this.typing].filter(([, until]) => until > now));
				if (live.size !== this.typing.size) this.typing = live;
				this.#expiry = null;
				if (live.size) this.#scheduleExpiry();
			},
			Math.max(soonest - Date.now(), 50),
		);
	}

	/** Called when a conversation is closed, so nothing is left ticking. */
	dispose(): void {
		if (this.#expiry) clearTimeout(this.#expiry);
		this.#expiry = null;
	}
}

function canGroup(prev: Message | null, m: Message): boolean {
	if (!prev) return false;
	if (prev.senderId !== m.senderId) return false;
	if (prev.kind !== m.kind) return false;
	// System messages never collapse into a run: each one is its own event and
	// they usually come from different actors anyway.
	if (m.kind === "system") return false;
	// A reply opens a new visual block because it carries a quote above it.
	if (m.replyTo) return false;
	return m.createdAt - prev.createdAt < GROUP_WINDOW_SECONDS;
}

function dayKey(epochSeconds: number): string {
	const d = new Date(epochSeconds * 1000);
	return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
}

export function dayLabel(epochSeconds: number): string {
	const d = new Date(epochSeconds * 1000);
	const now = new Date();
	const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
	const startOfThat = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
	const daysAgo = Math.round((startOfToday - startOfThat) / 86_400_000);

	if (daysAgo === 0) return "Today";
	if (daysAgo === 1) return "Yesterday";
	if (daysAgo < 7) return d.toLocaleDateString(undefined, { weekday: "long" });
	if (d.getFullYear() === now.getFullYear())
		return d.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
	return d.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
}
