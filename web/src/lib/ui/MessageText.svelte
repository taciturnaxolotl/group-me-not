<script lang="ts">
	import type { Mention } from "$lib/model/types";
	import { emojiOnlyCount, emojiScale, parseSegments } from "$lib/ui/text";

	/**
	 * Message body text.
	 *
	 * Three kinds of run and nothing else, because the wire format carries
	 * nothing else. See `ui/text.ts` for why that is a feature.
	 */
	interface Props {
		text: string;
		mentions?: Mention[];
		/** Resolves a mentioned user id to a name for the tooltip. */
		nameOf?: (userId: string) => string | null;
		onMention?: (userId: string) => void;
	}

	let { text, mentions = [], nameOf, onMention }: Props = $props();

	let segments = $derived(parseSegments(text, mentions));
	let emoji = $derived(mentions.length ? 0 : emojiOnlyCount(text));
</script>

{#if emoji > 0}
	<span
		class="block leading-tight"
		style:font-size={emojiScale(emoji)}
		style:line-height="1.15">{text}</span
	>
{:else}
	<span class="break-words whitespace-pre-wrap">
		{#each segments as seg, i (i)}
			{#if seg.kind === "text"}{seg.text}{:else if seg.kind === "link"}<a
					href={seg.href}
					target="_blank"
					rel="noopener noreferrer nofollow"
					class="underline decoration-[color:var(--c-link)]/40 underline-offset-2 hover:decoration-[color:var(--c-link)]"
					style:color="var(--c-link)">{seg.text}</a
				>{:else}<button
					type="button"
					class="cursor-pointer rounded-[3px] px-[1px] font-medium transition-colors"
					style:color="var(--c-link)"
					style:background="var(--c-accent-quiet)"
					title={nameOf?.(seg.userId) ?? undefined}
					onclick={() => onMention?.(seg.userId)}>{seg.text}</button
				>{/if}
		{/each}
	</span>
{/if}
