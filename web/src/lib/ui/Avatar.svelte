<script lang="ts">
	import { forSize, initials, initialsColor } from "$lib/ui/media";

	/**
	 * A square avatar with a coloured-initials fallback.
	 *
	 * Square rather than round, and that is a Slack borrowing rather than a
	 * whim: rounded squares read as identity tiles in a dense left-aligned
	 * column, where circles read as a string of beads.
	 *
	 * The size prop drives the CDN variant as well as the box, so a 20px
	 * avatar downloads 2.5 KB rather than 200.
	 */
	interface Props {
		name: string;
		url?: string | null;
		id?: string;
		size?: number;
		rounded?: boolean;
		class?: string;
	}

	let { name, url = null, id, size = 36, rounded = false, class: klass = "" }: Props = $props();

	let src = $derived(forSize(url, size));
	let loaded = $state(false);
	let failed = $state(false);

	// A different person in the same slot deserves another go at loading.
	$effect(() => {
		void src;
		loaded = false;
		failed = false;
	});
</script>

<span
	class="relative grid shrink-0 place-items-center overflow-hidden select-none {rounded
		? 'rounded-full'
		: 'rounded-[22%]'} {klass}"
	style:width="{size}px"
	style:height="{size}px"
	style:background={initialsColor(id ?? name)}
	aria-hidden="true"
>
	<!-- Initials are always drawn, and the picture fades in on top once it has
	     arrived. Swapping one for the other means an avatar that has not
	     loaded yet is a blank square, and a column of those reads as a bug
	     rather than as a slow network. -->
	<span
		class="font-semibold text-white/95"
		style:font-size="{Math.max(9, Math.round(size * 0.38))}px"
		style:letter-spacing="0.01em">{initials(name)}</span
	>

	{#if src && !failed}
		<img
			{src}
			alt=""
			width={size}
			height={size}
			loading="lazy"
			decoding="async"
			class="absolute inset-0 h-full w-full object-cover transition-opacity duration-200"
			style:opacity={loaded ? 1 : 0}
			onload={() => (loaded = true)}
			onerror={() => (failed = true)}
		/>
	{/if}
</span>
