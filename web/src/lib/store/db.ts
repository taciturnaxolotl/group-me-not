import { openDB, type DBSchema, type IDBPDatabase } from "idb";
import type { Conversation, Member, Message, Person } from "../model/types";
import type { IdRange } from "./ranges";

/**
 * Local persistence.
 *
 * The app reads from memory and writes through to here, so a reload is fast
 * and an offline start still shows the last state. Nothing in the UI awaits a
 * write.
 *
 * The one non-obvious decision is `sortKey`. IndexedDB sorts string keys
 * lexicographically, and message ids are decimal strings of *nearly* uniform
 * length — 18 digits today, fewer for messages old enough, more for the
 * synthetic ids we mint for unsent messages. Lexicographic and numeric order
 * agree only while the lengths match, so every id is left-padded to 20
 * characters before it becomes part of a key. It costs two bytes per row and
 * removes an entire category of ordering bug.
 */

export interface StoredMessage extends Message {
	/** `id` zero-padded to 20 chars. The actual sort key. Never displayed. */
	sortKey: string;
}

export interface ConversationState {
	key: string;
	/** Contiguous spans of history we hold. See `ranges.ts`. */
	ranges: IdRange[];
	/** Oldest message in the conversation, once we have paged back to it. */
	floorId: string | null;
	/** Set when a push arrived that did not continue our newest range. */
	gapAtHead: boolean;
	/** Composer contents, kept per conversation across reloads. */
	draft: string;
	/** Message being replied to, if the composer is in reply mode. */
	draftReplyTo: string | null;
}

export interface OutboxEntry {
	sourceGuid: string;
	conversationKey: string;
	text: string;
	attachments: unknown[];
	createdAt: number;
	attempts: number;
	/** When we may next try. Backoff lives here so it survives a reload. */
	nextAttemptAt: number;
	lastError: string | null;
	/** The synthetic id the optimistic copy is filed under. */
	placeholderId: string;
}

/** A reaction we have applied locally but not yet confirmed. */
export interface PendingReaction {
	key: string; // `${conversationKey}:${messageId}`
	conversationKey: string;
	messageId: string;
	/** Null means "we are removing our reaction". */
	glyph: string | null;
	/** What was there before, so a failure can put it back. */
	previous: string | null;
	createdAt: number;
}

interface GmnDB extends DBSchema {
	messages: {
		key: [string, string];
		value: StoredMessage;
		indexes: { byConversation: string };
	};
	conversations: { key: string; value: Conversation };
	conversationState: { key: string; value: ConversationState };
	members: { key: [string, string]; value: Member & { groupId: string }; indexes: { byGroup: string } };
	people: { key: string; value: Person };
	outbox: { key: string; value: OutboxEntry };
	pendingReactions: { key: string; value: PendingReaction };
	meta: { key: string; value: unknown };
}

export const padId = (id: string) => id.padStart(20, "0");

let dbPromise: Promise<IDBPDatabase<GmnDB>> | null = null;

export function db(): Promise<IDBPDatabase<GmnDB>> {
	// A rejected promise must not be cached. Caching one means a single
	// transient failure at startup — a private-mode block, a storage prompt
	// declined — permanently breaks every later read for the life of the tab,
	// with no way back short of a reload.
	dbPromise ??= openDB<GmnDB>("gmn", 1, {
		upgrade(d) {
			const messages = d.createObjectStore("messages", { keyPath: ["conversationKey", "sortKey"] });
			messages.createIndex("byConversation", "conversationKey");

			d.createObjectStore("conversations", { keyPath: "key" });
			d.createObjectStore("conversationState", { keyPath: "key" });

			const members = d.createObjectStore("members", { keyPath: ["groupId", "userId"] });
			members.createIndex("byGroup", "groupId");

			d.createObjectStore("people", { keyPath: "id" });
			d.createObjectStore("outbox", { keyPath: "sourceGuid" });
			d.createObjectStore("pendingReactions", { keyPath: "key" });
			d.createObjectStore("meta");
		},
	}).catch((err) => {
		dbPromise = null;
		throw err;
	});
	return dbPromise;
}

// MARK: - Messages

export async function putMessages(msgs: Message[]): Promise<void> {
	if (!msgs.length) return;
	const d = await db();
	const tx = d.transaction("messages", "readwrite");
	await Promise.all([
		...msgs.map((m) => tx.store.put({ ...m, sortKey: padId(m.id) })),
		tx.done,
	]);
}

export async function deleteMessage(conversationKey: string, id: string): Promise<void> {
	const d = await db();
	await d.delete("messages", [conversationKey, padId(id)]);
}

/**
 * The newest `limit` messages in a conversation, oldest-first.
 *
 * Reads backwards from the end of the index and reverses, rather than reading
 * everything and slicing. A group with fifty thousand messages should cost the
 * same to open as one with fifty.
 */
export async function loadTail(conversationKey: string, limit: number): Promise<StoredMessage[]> {
	const d = await db();
	const range = IDBKeyRange.bound([conversationKey, ""], [conversationKey, "\uffff"]);
	const out: StoredMessage[] = [];
	let cursor = await d.transaction("messages").store.openCursor(range, "prev");
	while (cursor && out.length < limit) {
		out.push(cursor.value);
		cursor = await cursor.continue();
	}
	return out.reverse();
}

/** A window of messages older than `beforeId`, oldest-first. */
export async function loadBefore(
	conversationKey: string,
	beforeId: string,
	limit: number,
): Promise<StoredMessage[]> {
	const d = await db();
	const range = IDBKeyRange.bound(
		[conversationKey, ""],
		[conversationKey, padId(beforeId)],
		false,
		true,
	);
	const out: StoredMessage[] = [];
	let cursor = await d.transaction("messages").store.openCursor(range, "prev");
	while (cursor && out.length < limit) {
		out.push(cursor.value);
		cursor = await cursor.continue();
	}
	return out.reverse();
}

export async function getMessage(
	conversationKey: string,
	id: string,
): Promise<StoredMessage | undefined> {
	const d = await db();
	return d.get("messages", [conversationKey, padId(id)]);
}

// MARK: - Conversations

export async function putConversations(convs: Conversation[]): Promise<void> {
	if (!convs.length) return;
	const d = await db();
	const tx = d.transaction("conversations", "readwrite");
	await Promise.all([...convs.map((c) => tx.store.put(c)), tx.done]);
}

export async function allConversations(): Promise<Conversation[]> {
	const d = await db();
	return d.getAll("conversations");
}

export async function getState(key: string): Promise<ConversationState> {
	const d = await db();
	return (
		(await d.get("conversationState", key)) ?? {
			key,
			ranges: [],
			floorId: null,
			gapAtHead: false,
			draft: "",
			draftReplyTo: null,
		}
	);
}

export async function putState(state: ConversationState): Promise<void> {
	const d = await db();
	await d.put("conversationState", state);
}

export async function allStates(): Promise<ConversationState[]> {
	const d = await db();
	return d.getAll("conversationState");
}

// MARK: - Members and people

export async function putMembers(groupId: string, members: Member[]): Promise<void> {
	const d = await db();
	const tx = d.transaction("members", "readwrite");
	await Promise.all([...members.map((m) => tx.store.put({ ...m, groupId })), tx.done]);
}

export async function loadMembers(groupId: string): Promise<Member[]> {
	const d = await db();
	return d.getAllFromIndex("members", "byGroup", groupId);
}

export async function putPeople(people: Person[]): Promise<void> {
	if (!people.length) return;
	const d = await db();
	const tx = d.transaction("people", "readwrite");
	await Promise.all([...people.map((p) => tx.store.put(p)), tx.done]);
}

export async function allPeople(): Promise<Person[]> {
	const d = await db();
	return d.getAll("people");
}

// MARK: - Outbox

export async function putOutbox(entry: OutboxEntry): Promise<void> {
	const d = await db();
	await d.put("outbox", entry);
}

export async function dropOutbox(sourceGuid: string): Promise<void> {
	const d = await db();
	await d.delete("outbox", sourceGuid);
}

export async function allOutbox(): Promise<OutboxEntry[]> {
	const d = await db();
	return d.getAll("outbox");
}

// MARK: - Pending reactions

export async function putPendingReaction(r: PendingReaction): Promise<void> {
	const d = await db();
	await d.put("pendingReactions", r);
}

export async function dropPendingReaction(key: string): Promise<void> {
	const d = await db();
	await d.delete("pendingReactions", key);
}

export async function allPendingReactions(): Promise<PendingReaction[]> {
	const d = await db();
	return d.getAll("pendingReactions");
}

// MARK: - Meta

export async function getMeta<T>(key: string): Promise<T | undefined> {
	const d = await db();
	return (await d.get("meta", key)) as T | undefined;
}

export async function setMeta(key: string, value: unknown): Promise<void> {
	const d = await db();
	await d.put("meta", value, key);
}

/** Sign-out. Everything local goes, including the cached history. */
export async function wipe(): Promise<void> {
	const d = await db();
	await Promise.all(
		(
			[
				"messages",
				"conversations",
				"conversationState",
				"members",
				"people",
				"outbox",
				"pendingReactions",
				"meta",
			] as const
		).map((s) => d.clear(s)),
	);
}
