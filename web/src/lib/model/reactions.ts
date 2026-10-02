import type { Message } from "./types";

/**
 * Keep `prior`'s reactions when they were written after `asOf`, the time the
 * request that produced `next` was sent. No `asOf` means a local write, which always wins.
 */
export function keepNewerReactions<T extends Message>(
	prior: Message | undefined,
	next: T,
	asOf?: number,
): T {
	if (asOf === undefined || !prior?.reactionsAt || prior.reactionsAt <= asOf) return next;
	return { ...next, reactions: prior.reactions, reactionsAt: prior.reactionsAt };
}
