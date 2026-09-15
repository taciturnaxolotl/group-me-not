<script lang="ts">
	import { declaredSize, fitBox, variant } from "$lib/ui/media";

	/**
	 * One image in a transcript.
	 *
	 * Its box is sized from the dimensions GroupMe puts in the URL, *before*
	 * any bytes arrive, so the message never changes height when the picture
	 * decodes. In a transcript somebody is reading, an image that resizes
	 * itself on load shoves everything below it down mid-sentence.
	 */
	interface Props {
		url: string;
		width?: number | null;
		height?: number | null;
		maxWidth?: number;
		maxHeight?: number;
		onOpen?: () => void;
	}

	let { url, width = null, height = null, maxWidth = 400, maxHeight = 320, onOpen }: Props = $props();

	let loaded = $state(false);
	let broken = $state(false);
	let img = $state<HTMLImageElement | null>(null);

	let box = $derived(
		fitBox(width && height ? { width, height } : declaredSize(url), maxWidth, maxHeight),
	);
	let src = $derived(variant(url, "large"));

	$effect(() => {
		void src;
		loaded = false;
		broken = false;
	});

	/**
	 * Catch the image that was already decoded.
	 *
	 * `onload` does not fire for an image the browser already has cached — it
	 * is `complete` before the handler is ever attached. Relying on the event
	 * alone leaves those permanently at opacity 0, which is exactly what
	 * happened to a photo sent from this tab: uploaded fine, arrived fine,
	 * drawn as an empty box because the bytes were still in memory from the
	 * local preview.
	 */
	$effect(() => {
		if (img?.complete && img.naturalWidth > 0) loaded = true;
	});
</script>

<button
	type="button"
	class="relative block overflow-hidden rounded-lg border transition-[filter] hover:brightness-[1.06]"
	style:border-color="var(--c-line-soft)"
	style:width="{box.width}px"
	style:height="{box.height}px"
	style:background="var(--c-sunken)"
	onclick={onOpen}
	aria-label="Open image"
>
	{#if !loaded && !broken}
		<span class="shimmer absolute inset-0" aria-hidden="true"></span>
	{/if}
	{#if broken}
		<span
			class="absolute inset-0 grid place-items-center text-[12px]"
			style:color="var(--c-text-faint)">Image unavailable</span
		>
	{:else}
		<img
			bind:this={img}
			{src}
			alt=""
			loading="lazy"
			decoding="async"
			class="relative h-full w-full object-cover transition-opacity duration-200"
			style:opacity={loaded ? 1 : 0}
			onload={() => (loaded = true)}
			onerror={() => (broken = true)}
		/>
	{/if}
</button>
