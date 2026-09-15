<script lang="ts">
	import type { Member, Message } from "$lib/model/types";
	import { mentionQuery } from "$lib/ui/text";
	import Avatar from "$lib/ui/Avatar.svelte";
	import EmojiPicker from "$lib/ui/EmojiPicker.svelte";
	import type { Staged } from "$lib/ui/attachments";
	import X from "@lucide/svelte/icons/x";
	import Plus from "@lucide/svelte/icons/plus";
	import Smile from "@lucide/svelte/icons/smile";
	import AtSign from "@lucide/svelte/icons/at-sign";
	import SendHorizontal from "@lucide/svelte/icons/send-horizontal";
	import Reply from "@lucide/svelte/icons/reply";
	import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
	import Play from "@lucide/svelte/icons/play";

	/**
	 * The composer.
	 *
	 * Shaped after Slack's, and the action row along the bottom is the part
	 * that matters. Without it there is nowhere for attachments, emoji or
	 * mentions to live, and the control reads as a text input somebody forgot
	 * to finish — which is exactly how the first version of this looked next
	 * to the real thing.
	 *
	 * The box is a raised surface with a deliberately light border. Slack
	 * spends real contrast saying where the composer is (measured:
	 * rgb(129,131,133) on a rgb(34,37,41) fill over a darker pane) because it
	 * is the one control that has to be findable without hunting.
	 */
	interface Props {
		placeholder: string;
		draft: string;
		replyTo: Message | null;
		members: Member[];
		staged: Staged[];
		disabled?: boolean;
		onSend: (text: string) => void;
		onTyping: () => void;
		onCancelReply: () => void;
		onDraft: (text: string) => void;
		onFiles: (files: File[]) => void;
		onRemoveStaged: (id: string) => void;
	}

	let {
		placeholder,
		draft = $bindable(),
		replyTo,
		members,
		staged,
		disabled = false,
		onSend,
		onTyping,
		onCancelReply,
		onDraft,
		onFiles,
		onRemoveStaged,
	}: Props = $props();

	let field = $state<HTMLTextAreaElement | null>(null);
	let filePicker = $state<HTMLInputElement | null>(null);
	let caret = $state(0);
	let highlighted = $state(0);
	let emojiOpen = $state(false);
	let dragging = $state(false);

	let query = $derived(mentionQuery(draft, caret));
	let suggestions = $derived.by(() => {
		if (!query) return [];
		const q = query.query.toLowerCase();
		return members.filter((m) => m.nickname.toLowerCase().includes(q)).slice(0, 6);
	});

	// The list re-filters on every keystroke, and a highlight left pointing at
	// index 4 of a list that now has two entries selects nothing on Enter.
	$effect(() => {
		void suggestions;
		highlighted = 0;
	});

	let uploading = $derived(staged.some((s) => s.state === "uploading"));
	let canSend = $derived(
		(Boolean(draft.trim()) || staged.some((s) => s.state === "ready")) && !uploading && !disabled,
	);

	function grow() {
		if (!field) return;
		field.style.height = "auto";
		// Roughly fourteen lines, then it scrolls. Must stay in step with the
		// `max-h` below, or the box stops growing before it starts scrolling.
		field.style.height = `${Math.min(field.scrollHeight, 320)}px`;
	}

	$effect(() => {
		void draft;
		grow();
	});

	function insert(text: string) {
		const at = caret || draft.length;
		draft = draft.slice(0, at) + text + draft.slice(at);
		onDraft(draft);
		queueMicrotask(() => {
			const pos = at + text.length;
			field?.focus();
			field?.setSelectionRange(pos, pos);
			caret = pos;
		});
	}

	function accept(m: Member) {
		if (!query) return;
		const before = draft.slice(0, query.start);
		const after = draft.slice(caret);
		draft = `${before}@${m.nickname} ${after}`;
		onDraft(draft);
		queueMicrotask(() => {
			const pos = before.length + m.nickname.length + 2;
			field?.focus();
			field?.setSelectionRange(pos, pos);
			caret = pos;
		});
	}

	function submit() {
		if (!canSend) return;
		const text = draft.trim();
		// Clear before handing off, so the field is empty on the next frame
		// rather than after a round trip.
		draft = "";
		onDraft("");
		queueMicrotask(grow);
		onSend(text);
	}

	function onKeydown(e: KeyboardEvent) {
		if (suggestions.length) {
			if (e.key === "ArrowDown") {
				e.preventDefault();
				highlighted = (highlighted + 1) % suggestions.length;
				return;
			}
			if (e.key === "ArrowUp") {
				e.preventDefault();
				highlighted = (highlighted - 1 + suggestions.length) % suggestions.length;
				return;
			}
			if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey)) {
				const pick = suggestions[highlighted];
				if (pick) {
					e.preventDefault();
					accept(pick);
					return;
				}
			}
			if (e.key === "Escape") {
				e.preventDefault();
				caret = -1;
				return;
			}
		}

		if (e.key === "Enter" && !e.shiftKey) {
			e.preventDefault();
			submit();
			return;
		}
		if (e.key === "Escape") {
			if (emojiOpen) {
				e.preventDefault();
				emojiOpen = false;
			} else if (replyTo) {
				e.preventDefault();
				onCancelReply();
			}
		}
	}

	function track(e: Event) {
		const t = e.currentTarget as HTMLTextAreaElement;
		caret = t.selectionStart ?? 0;
	}

	/** Pasting a screenshot should just work; it is how most images arrive. */
	function onPaste(e: ClipboardEvent) {
		const files = [...(e.clipboardData?.items ?? [])]
			.filter((i) => i.kind === "file")
			.map((i) => i.getAsFile())
			.filter((f): f is File => Boolean(f));
		if (!files.length) return;
		e.preventDefault();
		onFiles(files);
	}

	function onDrop(e: DragEvent) {
		e.preventDefault();
		dragging = false;
		const files = [...(e.dataTransfer?.files ?? [])];
		if (files.length) onFiles(files);
	}
</script>

<div class="px-5 pb-4">
	{#if replyTo}
		<div
			class="flex items-center gap-2 rounded-t-lg border border-b-0 px-3 py-1.5 text-[12px]"
			style:border-color="var(--c-edge)"
			style:background="var(--c-sunken)"
		>
			<Reply size={12} style="opacity:0.7" />
			<span style:color="var(--c-text-faint)">Replying to</span>
			<span class="font-semibold" style:color="var(--c-text-dim)">{replyTo.name}</span>
			<span class="min-w-0 flex-1 truncate" style:color="var(--c-text-faint)">{replyTo.text}</span>
			<button
				type="button"
				class="grid h-5 w-5 place-items-center rounded transition-colors"
				style:color="var(--c-text-faint)"
				onclick={onCancelReply}
				aria-label="Cancel reply"><X size={13} /></button
			>
		</div>
	{/if}

	<div class="relative">
		{#if emojiOpen}
			<EmojiPicker
				onPick={(g) => {
					insert(g);
					emojiOpen = false;
				}}
				onClose={() => (emojiOpen = false)}
			/>
		{/if}

		{#if suggestions.length}
			<div
				class="absolute bottom-full left-0 z-20 mb-2 w-72 overflow-hidden rounded-lg border py-1"
				style:border-color="var(--c-line)"
				style:background="var(--c-raise)"
				style:box-shadow="var(--shadow-pop)"
				role="listbox"
				aria-label="Mention"
			>
				{#each suggestions as m, i (m.userId)}
					<button
						type="button"
						class="flex w-full items-center gap-2 px-2 py-1.5 text-left text-[14px]"
						style:background={i === highlighted ? "var(--c-active)" : "transparent"}
						onmouseenter={() => (highlighted = i)}
						onclick={() => accept(m)}
						role="option"
						aria-selected={i === highlighted}
					>
						<Avatar name={m.nickname} url={m.avatarUrl} id={m.userId} size={22} />
						<span class="truncate">{m.nickname}</span>
					</button>
				{/each}
			</div>
		{/if}

		<!-- svelte-ignore a11y_no_static_element_interactions -->
		<div
			class="flex flex-col border transition-colors focus-within:border-[color:var(--c-link)]"
			class:rounded-lg={!replyTo}
			class:rounded-b-lg={Boolean(replyTo)}
			style:border-color={dragging ? "var(--c-link)" : "var(--c-edge)"}
			style:background="var(--c-raise)"
			style:box-shadow="0 1px 3px oklch(0 0 0 / 0.1)"
			ondragover={(e) => {
				e.preventDefault();
				dragging = true;
			}}
			ondragleave={() => (dragging = false)}
			ondrop={onDrop}
		>
			{#if staged.length}
				<!-- Thumbnails sit above the text, so the caption you are
				     typing stays in the same place whether there is one photo
				     attached or five. -->
				<div class="flex flex-wrap gap-2 px-3 pt-3">
					{#each staged as item (item.id)}
						<div
							class="group relative h-16 w-16 overflow-hidden rounded-md border"
							style:border-color="var(--c-line)"
							style:background="var(--c-sunken)"
						>
							{#if item.kind === "image"}
								<img src={item.previewUrl} alt="" class="h-full w-full object-cover" />
							{:else if item.kind === "video"}
								<!-- svelte-ignore a11y_media_has_caption -->
								<video src={item.previewUrl} class="h-full w-full object-cover" muted></video>
								<span class="absolute inset-0 grid place-items-center text-white/90">
									<Play size={18} />
								</span>
							{:else}
								<span
									class="grid h-full w-full place-items-center px-1 text-center text-[10px] leading-tight"
									style:color="var(--c-text-dim)">{item.file.name}</span
								>
							{/if}

							{#if item.state === "uploading"}
								<span
									class="absolute inset-0 grid place-items-center"
									style:background="oklch(0 0 0 / 0.55)"
								>
									<span class="spinner"></span>
								</span>
							{:else if item.state === "failed"}
								<span
									class="absolute inset-0 grid place-items-center text-white"
									style:background="oklch(0.4 0.14 25 / 0.85)"
									title={item.error ?? "Upload failed"}
								>
									<TriangleAlert size={14} />
								</span>
							{/if}

							<button
								type="button"
								class="absolute top-0.5 right-0.5 grid h-4 w-4 place-items-center rounded-full text-white opacity-0 transition-opacity group-hover:opacity-100"
								style:background="oklch(0 0 0 / 0.65)"
								onclick={() => onRemoveStaged(item.id)}
								aria-label="Remove attachment"><X size={10} /></button
							>
						</div>
					{/each}
				</div>
			{/if}

			<textarea
				bind:this={field}
				bind:value={draft}
				rows="1"
				{placeholder}
				{disabled}
				data-composer
				class="scroller max-h-[320px] min-h-[22px] resize-none bg-transparent px-3 pt-2.5 leading-[22px] outline-none placeholder:text-[color:var(--c-text-faint)]"
				style:color="var(--c-body)"
				onkeydown={onKeydown}
				onkeyup={track}
				onclick={track}
				onpaste={onPaste}
				oninput={(e) => {
					track(e);
					onDraft(draft);
					if (draft.trim()) onTyping();
				}}
			></textarea>

			<div class="flex items-center gap-0.5 px-2 pt-1 pb-2">
				<input
					bind:this={filePicker}
					type="file"
					multiple
					accept="image/*,video/*"
					class="hidden"
					onchange={(e) => {
						const input = e.currentTarget;
						const files = [...(input.files ?? [])];
						if (files.length) onFiles(files);
						input.value = "";
					}}
				/>

				{@render action(Plus, "Attach a photo or video", () => filePicker?.click())}
				{@render action(Smile, "Emoji", () => (emojiOpen = !emojiOpen), emojiOpen)}
				{@render action(AtSign, "Mention someone", () => insert("@"))}

				<div class="flex-1"></div>

				<button
					type="button"
					class="grid h-7 w-9 place-items-center rounded-md transition-opacity"
					style:background={canSend ? "var(--c-send)" : "transparent"}
					style:color={canSend ? "oklch(0.99 0 0)" : "var(--c-text-faint)"}
					style:opacity={canSend ? 1 : 0.4}
					disabled={!canSend}
					onclick={submit}
					title={uploading ? "Waiting for uploads to finish" : "Send"}
					aria-label="Send"><SendHorizontal size={15} /></button
				>
			</div>
		</div>
	</div>

	<div class="pt-1 pr-1 text-right text-[11px]" style:color="var(--c-text-faint)">
		<strong class="font-semibold">Shift + Return</strong> to add a new line
	</div>
</div>

{#snippet action(Glyph: typeof Plus, label: string, run: () => void, on: boolean = false)}
	<button
		type="button"
		class="grid h-7 w-7 place-items-center rounded-md transition-colors"
		style:background={on ? "var(--c-active)" : "transparent"}
		style:color={on ? "var(--c-text)" : "var(--c-text-dim)"}
		onmouseenter={(e) => {
			if (!on) e.currentTarget.style.background = "var(--c-hover)";
		}}
		onmouseleave={(e) => {
			if (!on) e.currentTarget.style.background = "transparent";
		}}
		onclick={run}
		title={label}
		aria-label={label}
	>
		<Glyph size={16} />
	</button>
{/snippet}

<style>
	.spinner {
		width: 16px;
		height: 16px;
		border: 2px solid oklch(1 0 0 / 0.3);
		border-top-color: oklch(1 0 0 / 0.9);
		border-radius: 50%;
		animation: spin 0.7s linear infinite;
	}
	@keyframes spin {
		to {
			transform: rotate(360deg);
		}
	}
</style>
