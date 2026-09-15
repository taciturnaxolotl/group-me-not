<script lang="ts">
	import type { Timeline } from "$lib/state/timeline.svelte";
	import type { Message } from "$lib/model/types";
	import MessageRow from "$lib/ui/MessageRow.svelte";
	import ChevronDown from "@lucide/svelte/icons/chevron-down";

	/**
	 * The transcript, and its scroll discipline.
	 *
	 * Four rules, each of which exists because its absence is a bug people
	 * notice immediately:
	 *
	 *   1. **Observe whether we are at the foot; never compute it.** A
	 *      sentinel element at the bottom and an IntersectionObserver answer
	 *      the question directly. Reconstructing it from scrollHeight minus
	 *      scrollTop minus clientHeight means every change to the padding is
	 *      another chance to get it wrong.
	 *   2. **Follow the foot only while the reader is standing at it.** If
	 *      they have scrolled up to read something, a new message must not
	 *      move the view. Announce it with a pill instead.
	 *   3. **Hold the anchor when older messages are spliced in above.**
	 *      Without this, loading a page of history yanks the reader backwards
	 *      by the height of everything that just arrived.
	 *   4. **Scroll after layout, not after state.** The row has to exist and
	 *      be measured before anything can scroll to it.
	 */
	interface Props {
		timeline: Timeline;
		selfId: string;
		nameOf?: (userId: string) => string | null;
		onLoadOlder: () => void;
		onReply: (m: Message) => void;
		onReact: (m: Message, glyph: string) => void;
		onRetry: (m: Message) => void;
		onDiscard: (m: Message) => void;
		onEdit: (m: Message, text: string) => void;
		onDelete: (m: Message) => void;
		canEdit: (m: Message) => boolean;
		onOpenImage: (url: string, all: string[]) => void;
	}

	let {
		timeline,
		selfId,
		nameOf,
		onLoadOlder,
		onReply,
		onReact,
		onRetry,
		onDiscard,
		onEdit,
		onDelete,
		canEdit,
		onOpenImage,
	}: Props = $props();

	let scroller = $state<HTMLDivElement | null>(null);
	let foot = $state<HTMLDivElement | null>(null);
	let head = $state<HTMLDivElement | null>(null);

	let atFoot = $state(true);
	let unseen = $state(0);

	let rows = $derived(timeline.rows);

	/** Resolve a reply's quoted text from whatever is loaded. */
	function replyPreview(m: Message) {
		if (!m.replyTo) return null;
		const parent = timeline.find(m.replyTo.messageId);
		if (parent) {
			return { name: parent.name, text: parent.text || "(attachment)" };
		}
		// The original is outside the loaded window. Still draw the quote —
		// hiding it would silently change what the message means — but say
		// plainly that we cannot show what it said.
		const name = m.replyTo.authorId ? (nameOf?.(m.replyTo.authorId) ?? "Someone") : "Someone";
		return { name, text: "…" };
	}

	function jumpToFoot(smooth = true) {
		foot?.scrollIntoView({ behavior: smooth ? "smooth" : "auto", block: "end" });
		unseen = 0;
	}

	// Foot visibility.
	$effect(() => {
		const el = foot;
		const root = scroller;
		if (!el || !root) return;
		const io = new IntersectionObserver(
			([entry]) => {
				atFoot = Boolean(entry?.isIntersecting);
				if (atFoot) unseen = 0;
			},
			// A little slack, so being a few pixels short still counts as
			// standing at the bottom.
			{ root, rootMargin: "80px 0px 0px 0px", threshold: 0 },
		);
		io.observe(el);
		return () => io.disconnect();
	});

	// Older-history trigger.
	$effect(() => {
		const el = head;
		const root = scroller;
		if (!el || !root) return;
		const io = new IntersectionObserver(
			([entry]) => {
				// Not while the view is still settling on open. The sentinel is
				// briefly visible before the first scroll-to-foot lands, and
				// firing then loads a page of history nobody asked for and
				// leaves the reader sitting in the middle of last week.
				if (settling) return;
				if (entry?.isIntersecting && !timeline.atFloor && !timeline.loadingOlder) onLoadOlder();
			},
			{ root, rootMargin: "600px 0px 0px 0px", threshold: 0 },
		);
		io.observe(el);
		return () => io.disconnect();
	});

	// New content: follow it, or count it.
	//
	// Keyed on the timeline's identity, not just on its length. This component
	// is reused across conversations rather than remounted, so without the key
	// check the counters carry over from the last chat and opening a new one
	// never lands at the foot — it inherits whatever scroll position the
	// previous conversation happened to be at.
	let mountedKey = $state<string | null>(null);
	let lastCount = $state(0);
	let lastNewest = $state<string | null>(null);
	let settling = $state(false);

	$effect(() => {
		const key = timeline.key;
		const count = timeline.messages.length;
		// The true last row, pending sends included. `newestId` deliberately
		// ignores anything not yet acknowledged, which is right for read
		// receipts and wrong here: a message you just wrote is on screen the
		// instant you press Enter, and that is the thing to follow.
		const tail = timeline.messages[timeline.messages.length - 1];
		const newest = tail?.id ?? null;
		const tailIsMine = tail?.senderId === selfId;

		if (key !== mountedKey) {
			mountedKey = key;
			lastCount = count;
			lastNewest = newest;
			atFoot = true;
			unseen = 0;
			// Opening is a position, not a movement, so it is not animated.
			// `settling` keeps us pinned while images decode and the content
			// below the fold changes height under us.
			settling = true;
			requestAnimationFrame(() => jumpToFoot(false));
			setTimeout(() => (settling = false), 1200);
			return;
		}

		if (count === lastCount && newest === lastNewest) return;
		const arrived = newest !== lastNewest;
		const wasEmpty = lastCount === 0;
		lastCount = count;
		lastNewest = newest;

		if (wasEmpty || settling) {
			requestAnimationFrame(() => jumpToFoot(false));
			return;
		}
		if (!arrived) return;

		// Your own message always goes to the foot, wherever you were reading.
		// It is the one movement you explicitly asked for, and treating it as
		// something unread — which is what happened before — puts a "1 new"
		// pill on a message you just wrote yourself.
		if (tailIsMine) {
			requestAnimationFrame(() => jumpToFoot(true));
			return;
		}

		if (atFoot) requestAnimationFrame(() => jumpToFoot(true));
		else unseen += 1;
	});

	/**
	 * Keep the foot in view while the content settles.
	 *
	 * An image decoding, a font swapping or a video reporting its size all
	 * change the height of the transcript after it has been laid out. Every
	 * one of those pushes the newest message up out of view unless something
	 * re-pins. A ResizeObserver catches all of them without having to know
	 * which one happened.
	 *
	 * Guarded on `atFoot`, so a reader who has scrolled up to read something
	 * is never yanked back down by a picture finishing three screens below.
	 */
	$effect(() => {
		const el = scroller;
		if (!el) return;
		const ro = new ResizeObserver(() => {
			if (atFoot || settling) foot?.scrollIntoView({ behavior: "auto", block: "end" });
		});
		for (const child of el.children) ro.observe(child);
		return () => ro.disconnect();
	});

	/**
	 * Splicing older messages in without moving the reader.
	 *
	 * Record the distance from the bottom before the DOM changes, and restore
	 * it after. Anchoring on the top would drift, because the content above
	 * the viewport is exactly what just changed size.
	 */
	let heldFromBottom = $state<number | null>(null);
	$effect(() => {
		if (timeline.loadingOlder && scroller) {
			heldFromBottom = scroller.scrollHeight - scroller.scrollTop;
		}
	});
	$effect(() => {
		void rows;
		if (heldFromBottom === null || !scroller || timeline.loadingOlder) return;
		const el = scroller;
		const held = heldFromBottom;
		heldFromBottom = null;
		requestAnimationFrame(() => {
			el.scrollTop = el.scrollHeight - held;
		});
	});
</script>

<div class="relative min-h-0 flex-1">
	<!--
		`justify-end` is what keeps a short conversation sitting on the
		composer instead of floating at the top of a mostly empty pane. A
		flex column that only justifies when the content is shorter than the
		box gives the "grows upward from the bottom" behaviour every chat
		client has, with no measuring and no JavaScript.
	-->
	<div
		bind:this={scroller}
		class="scroller flex h-full flex-col justify-end"
		role="log"
		aria-live="polite"
	>
		<div bind:this={head} class="shrink-0 px-5 pt-5 pb-1">
			{#if timeline.loadingOlder}
				<div class="py-3 text-center text-[13px]" style:color="var(--c-text-faint)">
					Loading earlier messages…
				</div>
			{:else if timeline.atFloor}
				<div class="py-3 text-center text-[13px]" style:color="var(--c-text-faint)">
					This is the beginning of the conversation.
				</div>
			{/if}
		</div>

		{#each rows as row (row.key)}
			{#if row.kind === "dateSeparator"}
				<div class="relative my-3 px-5">
					<div class="absolute inset-x-5 top-1/2 h-px" style:background="var(--c-line-soft)"></div>
					<div class="relative flex justify-center">
						<span
							class="rounded-full border px-3 py-0.5 text-[12px] font-semibold"
							style:border-color="var(--c-line)"
							style:background="var(--c-base)"
							style:color="var(--c-text-dim)">{row.label}</span
						>
					</div>
				</div>
			{:else if row.kind === "unreadDivider"}
				<div class="relative my-2 px-5">
					<div
						class="absolute inset-x-5 top-1/2 h-px"
						style:background="var(--c-unread)"
						style:opacity="0.6"
					></div>
					<div class="relative flex justify-end">
						<span
							class="rounded-full px-2 py-0.5 text-[11px] font-bold tracking-wide text-white uppercase"
							style:background="var(--c-unread)">New</span
						>
					</div>
				</div>
			{:else}
				<MessageRow
					message={row.message}
					grouped={row.grouped}
					isOwn={row.message.senderId === selfId}
					mentionsMe={row.message.mentions.some((m) => m.userId === selfId)}
					{selfId}
					replyPreview={replyPreview(row.message)}
					{nameOf}
					{onReply}
					{onReact}
					{onRetry}
					{onDiscard}
					{onEdit}
					{onDelete}
					canEdit={canEdit(row.message)}
					{onOpenImage}
				/>
			{/if}
		{/each}

		<div bind:this={foot} class="h-3"></div>
	</div>

	{#if !atFoot}
		<!-- Slack's jump-to-latest. On a phone a flick gets you back; with a
		     mouse wheel and four thousand messages it does not. -->
		<button
			type="button"
			class="absolute right-6 bottom-3 flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-[12px] font-medium transition-transform hover:-translate-y-0.5"
			style:border-color={unseen ? "var(--c-link)" : "var(--c-line)"}
			style:background={unseen ? "var(--c-link)" : "var(--c-raise)"}
			style:color={unseen ? "oklch(0.99 0 0)" : "var(--c-text-dim)"}
			style:box-shadow="var(--shadow-pop)"
			onclick={() => jumpToFoot(true)}
		>
			{#if unseen}
				{unseen} new
			{:else}
				Jump to latest
			{/if}
			<ChevronDown size={13} />
		</button>
	{/if}
</div>
