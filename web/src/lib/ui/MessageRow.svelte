<script lang="ts">
	import { deletionSentence, type Message, type Reaction } from "$lib/model/types";
	import Avatar from "$lib/ui/Avatar.svelte";
	import MessageText from "$lib/ui/MessageText.svelte";
	import Attachments from "$lib/ui/Attachments.svelte";
	import ReactionGlyph from "$lib/ui/ReactionGlyph.svelte";
	import Reply from "@lucide/svelte/icons/reply";
	import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
	import Pencil from "@lucide/svelte/icons/pencil";
	import Trash from "@lucide/svelte/icons/trash-2";
	import { exactTime, messageTime } from "$lib/ui/time";

	/**
	 * One message.
	 *
	 * Flat and left-aligned, Slack-style, rather than in a bubble on alternate
	 * sides. That is not only a style preference: in a group of eighty people,
	 * two-sided bubbles spend half the width saying "not you" and leave the
	 * other forty-nine names competing for the rest. A single column with the
	 * author at the left lets the eye run straight down the senders.
	 *
	 * A grouped message — same author, within five minutes — drops the avatar
	 * and name and shows its timestamp only on hover, in the space the avatar
	 * would have occupied. That is the detail that makes a burst of four
	 * messages read as one person talking.
	 */
	interface Props {
		message: Message;
		grouped: boolean;
		isOwn: boolean;
		mentionsMe: boolean;
		/** Needed to tell our own reaction chips apart from everyone else's. */
		selfId: string;
		replyPreview?: { name: string; text: string } | null;
		nameOf?: (userId: string) => string | null;
		onReply?: (m: Message) => void;
		onReact?: (m: Message, glyph: string) => void;
		onRetry?: (m: Message) => void;
		onDiscard?: (m: Message) => void;
		/** Null when this message may not be edited — see the engine's window check. */
		onEdit?: ((m: Message, text: string) => void) | null;
		onDelete?: ((m: Message) => void) | null;
		canEdit?: boolean;
		onOpenImage?: (url: string, all: string[]) => void;
		onJumpTo?: (id: string) => void;
	}

	let {
		message,
		grouped,
		isOwn,
		mentionsMe,
		selfId,
		replyPreview = null,
		nameOf,
		onReply,
		onReact,
		onRetry,
		onDiscard,
		onEdit = null,
		onDelete = null,
		canEdit = false,
		onOpenImage,
		onJumpTo,
	}: Props = $props();

	let hovered = $state(false);
	let editing = $state(false);
	let editText = $state("");
	let editField = $state<HTMLTextAreaElement | null>(null);

	function beginEdit() {
		editText = message.text;
		editing = true;
		queueMicrotask(() => {
			editField?.focus();
			editField?.setSelectionRange(editText.length, editText.length);
		});
	}

	function commitEdit() {
		const next = editText.trim();
		editing = false;
		if (!next || next === message.text) return;
		onEdit?.(message, next);
	}
	let pending = $derived(message.delivery === "pending" || message.delivery === "sending");
	let failed = $derived(message.delivery === "failed");

	const QUICK = ["❤️", "👍", "😂", "🎉", "👀"];

	function reactionLabel(r: Reaction): string {
		const who = r.userIds.length;
		const what = r.kind === "powerup" ? "Sticker" : r.code;
		return `${what}, ${who} ${who === 1 ? "person" : "people"}`;
	}
</script>

{#if message.deletedAt}
	<!-- A tombstone, not a hole. The row keeps its place, its author and its
	     time, which is the whole reason to draw anything at all: a silent gap
	     in a transcript reads as a client that lost a message rather than a
	     person who took one back.

	     Phrased with the server's own wording, which varies by who did it: an
	     admin removing somebody else's message is a different event from an
	     author taking back their own, and GroupMe says so. -->
	<div
		class="px-5"
		class:py-0.5={grouped}
		class:pt-2={!grouped}
		class:pb-0.5={!grouped}
		role="listitem"
	>
		<div class="flex gap-2.5">
			<div class="w-9 shrink-0"></div>
			<div
				class="flex min-w-0 flex-1 items-center gap-1.5 text-[13px] italic"
				style:color="var(--c-text-faint)"
			>
				<Trash size={12} class="shrink-0 opacity-70" />
				<span class="truncate">{deletionSentence(message.deletionActor)}</span>
			</div>
		</div>
	</div>
{:else if message.kind === "system"}
	<!-- System notices are the server's own sentence, verbatim. Re-deriving
	     them client-side means guessing at a phrasing that varies by event
	     type and by locale, and getting it subtly wrong forever. -->
	<div class="px-5 py-1">
		<div
			class="mx-auto max-w-[46rem] text-center text-[13px] leading-relaxed"
			style:color="var(--c-text-faint)"
		>
			{message.text}
		</div>
	</div>
{:else}
	<div
		class="group relative px-5 transition-colors"
		class:py-0.5={grouped}
		class:pt-2={!grouped}
		class:pb-0.5={!grouped}
		style:background={mentionsMe ? "var(--c-mention)" : hovered ? "var(--c-hover)" : "transparent"}
		style:box-shadow={mentionsMe ? "inset 2px 0 0 var(--c-mention-line)" : "none"}
		onmouseenter={() => (hovered = true)}
		onmouseleave={() => (hovered = false)}
		role="listitem"
	>
		<!-- Hover toolbar. Sits on the top edge, overlapping the row above, the
		     way Slack's does, so it never changes the row's height and never
		     pushes the transcript around under a moving cursor. -->
		{#if hovered && !failed}
			<div
				class="absolute -top-3.5 right-5 z-10 flex items-center gap-0.5 rounded-lg border p-0.5"
				style:border-color="var(--c-line)"
				style:background="var(--c-base)"
				style:box-shadow="var(--shadow-pop)"
			>
				{#each QUICK as glyph (glyph)}
					<button
						type="button"
						class="grid h-7 w-7 place-items-center rounded-md text-[15px] transition-transform hover:scale-115"
						style:background="transparent"
						title="React {glyph}"
						onclick={() => onReact?.(message, glyph)}>{glyph}</button
					>
				{/each}
				<span class="mx-0.5 h-4 w-px" style:background="var(--c-line)"></span>
				<button
					type="button"
					class="grid h-7 w-7 place-items-center rounded-md transition-colors"
					style:color="var(--c-text-dim)"
					title="Reply"
					onclick={() => onReply?.(message)}
					aria-label="Reply to this message"><Reply size={15} /></button
				>
				{#if canEdit}
					<button
						type="button"
						class="grid h-7 w-7 place-items-center rounded-md transition-colors"
						style:color="var(--c-text-dim)"
						title="Edit"
						onclick={beginEdit}
						aria-label="Edit this message"><Pencil size={14} /></button
					>
				{/if}
				{#if isOwn && onDelete}
					<button
						type="button"
						class="grid h-7 w-7 place-items-center rounded-md transition-colors"
						style:color="var(--c-text-dim)"
						title="Delete"
						onclick={() => onDelete?.(message)}
						aria-label="Delete this message"><Trash size={14} /></button
					>
				{/if}
			</div>
		{/if}

		<div class="flex gap-2.5" style:opacity={pending ? 0.55 : 1}>
			<!-- The gutter. Holds the avatar on a run head and the hover
			     timestamp otherwise, so both live in the same column and the
			     text never shifts sideways between them. -->
			<div class="w-9 shrink-0 pt-0.5">
				{#if !grouped}
					<Avatar name={message.name} url={message.avatarUrl} id={message.senderId} size={36} />
				{:else if hovered}
					<span
						class="tnum block pt-[3px] text-right text-[10px] leading-none"
						style:color="var(--c-text-faint)"
						style:padding-right="6px">{messageTime(message.createdAt)}</span
					>
				{/if}
			</div>

			<div class="min-w-0 flex-1">
				{#if replyPreview}
					<!-- The quote sits above the answer and is deliberately
					     quiet: it is context, not content. -->
					<button
						type="button"
						class="mb-0.5 flex max-w-full items-center gap-1.5 text-left text-[12px] leading-snug"
						style:color="var(--c-text-faint)"
						onclick={() => message.replyTo && onJumpTo?.(message.replyTo.messageId)}
					>
						<Reply size={12} class="shrink-0 opacity-70" />
						<span class="font-semibold" style:color="var(--c-text-dim)">{replyPreview.name}</span>
						<span class="truncate">{replyPreview.text}</span>
					</button>
				{/if}

				{#if !grouped}
				<div class="flex items-baseline gap-2">
						<span
							class="text-[15px] leading-tight"
							style:color="var(--c-text)"
							style:font-weight="900"
						>
							{message.name}
						</span>
						<time
							class="tnum text-[12px] leading-tight"
							style:color="var(--c-text-dim)"
							title={exactTime(message.createdAt)}
							datetime={new Date(message.createdAt * 1000).toISOString()}
						>
							{messageTime(message.createdAt)}
						</time>
						{#if isOwn && pending}
							<span class="text-[11px]" style:color="var(--c-text-faint)">sending…</span>
						{/if}
					</div>
				{/if}

				{#if editing}
					<!-- Edits happen in place. A modal would take the message
					     off screen, which is the one thing you need to see
					     while rewording it. -->
					<div class="mt-0.5">
						<textarea
							bind:this={editField}
							bind:value={editText}
							rows="1"
							class="scroller w-full resize-none rounded-md border px-2 py-1.5 leading-[22px] outline-none"
							style:border-color="var(--c-link)"
							style:background="var(--c-raise)"
							style:color="var(--c-body)"
							onkeydown={(e) => {
								if (e.key === "Enter" && !e.shiftKey) {
									e.preventDefault();
									commitEdit();
								} else if (e.key === "Escape") {
									e.preventDefault();
									editing = false;
								}
							}}
						></textarea>
						<div class="mt-1 flex items-center gap-2 text-[12px]">
							<button
								type="button"
								class="rounded px-2 py-0.5 font-semibold"
								style:background="var(--c-link)"
								style:color="oklch(0.99 0 0)"
								onclick={commitEdit}>Save</button
							>
							<button
								type="button"
								style:color="var(--c-text-faint)"
								onclick={() => (editing = false)}>Cancel</button
							>
							<span style:color="var(--c-text-faint)">Escape to cancel</span>
						</div>
					</div>
				{:else if message.text}
					<div class="text-msg" style:color="var(--c-body)">
						<MessageText text={message.text} mentions={message.mentions} {nameOf} />
						{#if message.editedAt}
							<span class="ml-1 text-[11px]" style:color="var(--c-text-faint)">(edited)</span>
						{/if}
					</div>
				{/if}

				<Attachments attachments={message.attachments} {onOpenImage} />

				{#if message.reactions.length}
					<div class="mt-1 flex flex-wrap gap-1">
						{#each message.reactions as r (r.code)}
							{@const mine = r.userIds.includes(selfId)}
							<button
								type="button"
								class="flex h-6 items-center gap-1 rounded-full px-2 text-[12px] transition-colors"
								style:border="1px solid {mine ? 'var(--c-link)' : 'transparent'}"
								style:background={mine ? "var(--c-link-quiet)" : "var(--c-chip)"}
								title={reactionLabel(r)}
								aria-pressed={mine}
								onclick={() => onReact?.(message, r.code)}
							>
								<ReactionGlyph reaction={r} size={15} />
								<span
									class="tnum font-semibold"
									style:color={mine ? "var(--c-link)" : "var(--c-text-dim)"}
									>{r.userIds.length}</span
								>
							</button>
						{/each}
					</div>
				{/if}

				{#if failed}
					<!-- A failed send is reported on the message itself with the
					     way out attached, rather than as a toast that scrolls
					     away from the thing it is about. -->
					<div class="mt-1 flex items-center gap-2 text-[12px]" style:color="var(--c-unread)">
						<TriangleAlert size={13} />
						<span>{message.failure ?? "Not delivered"}</span>
						<button type="button" class="underline" onclick={() => onRetry?.(message)}
							>Try again</button
						>
						<button
							type="button"
							class="underline"
							style:color="var(--c-text-faint)"
							onclick={() => onDiscard?.(message)}>Discard</button
						>
					</div>
				{/if}
			</div>
		</div>
	</div>
{/if}
