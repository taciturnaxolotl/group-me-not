<script lang="ts">
	import X from "@lucide/svelte/icons/x";

	/**
	 * Full-size image viewer.
	 *
	 * Arrow keys move through the images that were attached to the same
	 * message, because that is the set someone means when they click one of
	 * four photos from the same afternoon.
	 */
	interface Props {
		url: string;
		all: string[];
		onClose: () => void;
	}

	let { url, all, onClose }: Props = $props();

	let index = $state(Math.max(all.indexOf(url), 0));
	let current = $derived(all[index] ?? url);

	function onKeydown(e: KeyboardEvent) {
		if (e.key === "ArrowRight") index = Math.min(index + 1, all.length - 1);
		if (e.key === "ArrowLeft") index = Math.max(index - 1, 0);
		if (e.key === "Escape") onClose();
	}
</script>

<svelte:window onkeydown={onKeydown} />

<div
	class="fixed inset-0 z-50 grid place-items-center p-8"
	style:background="oklch(0 0 0 / 0.86)"
	onclick={onClose}
	onkeydown={() => {}}
	role="presentation"
>
	<img
		src={current}
		alt=""
		class="max-h-full max-w-full rounded-lg object-contain"
		onclick={(e) => e.stopPropagation()}
	/>

	{#if all.length > 1}
		<div
			class="tnum absolute bottom-6 left-1/2 -translate-x-1/2 rounded-full px-3 py-1 text-[12px]"
			style:background="oklch(1 0 0 / 0.12)"
			style:color="oklch(1 0 0 / 0.85)"
		>
			{index + 1} / {all.length}
		</div>
	{/if}

	<button
		type="button"
		class="absolute top-5 right-5 grid h-9 w-9 place-items-center rounded-full"
		style:background="oklch(1 0 0 / 0.12)"
		style:color="oklch(1 0 0 / 0.85)"
		onclick={onClose}
		aria-label="Close"><X size={17} /></button
	>
</div>
