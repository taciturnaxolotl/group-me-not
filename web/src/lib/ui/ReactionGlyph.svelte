<script lang="ts">
	import type { Reaction } from "$lib/model/types";

	/**
	 * One reaction glyph, which is not always a character.
	 *
	 * GroupMe has two kinds. Most are ordinary Unicode and draw as text. The
	 * rest are "powerups": sprite cells from a pack, sent as
	 * `{type: "emoji", pack_id, pack_index}` with **no character at all**. A
	 * client that only handles the first kind draws a reaction chip containing
	 * a number and nothing else, which is how this looked before.
	 *
	 * The packs are single-column PNG strips, one square cell per glyph.
	 * Measured for pack 20: 80x3600, which is 45 cells of 80px. So the cell is
	 * the sheet's width and the offset is `index * width`.
	 *
	 * Note also that `pack_id` and `pack_index` arrive as JSON numbers on some
	 * messages and as quoted strings on others, in the same array. The
	 * normalizer coerces both.
	 */
	interface Props {
		reaction: Reaction;
		size?: number;
	}

	let { reaction, size = 16 }: Props = $props();

	const CELL = 80;
	let sheet = $derived(
		reaction.packId !== null
			? `https://powerups.s3.amazonaws.com/emoji/${reaction.packId}/keyboard.xhdpi.80x80.png`
			: null,
	);

	/**
	 * Powerups get drawn larger than emoji, which looks inconsistent and is
	 * not.
	 *
	 * A Unicode emoji is a glyph designed to read at text size. A powerup is a
	 * detailed illustration — a sheep, a tabby cat, a raccoon — and at the
	 * 15px an emoji is comfortable at, it collapses into a dark smudge that
	 * reads as a rendering failure. It took a magnified screenshot to confirm
	 * the sprite was there at all. Matching their *apparent* size rather than
	 * their box is the point.
	 */
	let box = $derived(reaction.kind === "powerup" ? Math.round(size * 1.3) : size);
	let scale = $derived(box / CELL);
</script>

{#if reaction.kind === "powerup" && sheet && reaction.packIndex !== null}
	<span
		class="inline-block shrink-0 bg-no-repeat"
		style:width="{box}px"
		style:height="{box}px"
		style:margin="{(size - box) / 2}px"
		style:background-image="url({sheet})"
		style:background-size="{box}px auto"
		style:background-position="0 -{reaction.packIndex * CELL * scale}px"
		role="img"
		aria-label="reaction"
	></span>
{:else if reaction.code}
	<span style:font-size="{size - 2}px" style:line-height="1">{reaction.code}</span>
{:else}
	<!-- A pack we cannot resolve. A neutral mark beats an empty chip that
	     looks like a rendering bug. -->
	<span style:font-size="{size - 2}px" style:line-height="1" style:opacity="0.6">☆</span>
{/if}
