<script lang="ts">
	import type { Attachment } from "$lib/model/types";
	import { declaredSize, fitBox } from "$lib/ui/media";
	import Thumb from "$lib/ui/Thumb.svelte";
	import MapPin from "@lucide/svelte/icons/map-pin";
	import FileIcon from "@lucide/svelte/icons/file";
	import BarChart from "@lucide/svelte/icons/chart-no-axes-column";
	import Calendar from "@lucide/svelte/icons/calendar";

	/**
	 * Everything hanging off a message that is not text.
	 *
	 * The important bit is that every box is sized *before* its bytes arrive,
	 * from the dimensions GroupMe puts in the URL. An image that sizes itself
	 * on load shoves every message below it down the moment it decodes, which
	 * in a transcript someone is reading is genuinely maddening.
	 */
	interface Props {
		attachments: Attachment[];
		onOpenImage?: (url: string, all: string[]) => void;
	}

	let { attachments, onOpenImage }: Props = $props();

	// `reply` and `mentions` are lifted onto the message itself and have
	// nothing to draw here.
	let visible = $derived(attachments.filter((a) => a.kind !== "unknown"));
	let images = $derived(visible.filter((a) => a.kind === "image").map((a) => a.url));
</script>

{#if visible.length}
	<div class="mt-1 flex flex-col items-start gap-1.5">
		{#each visible as a, i (i)}
			{#if a.kind === "image"}
				<Thumb
					url={a.url}
					width={a.width}
					height={a.height}
					onOpen={() => onOpenImage?.(a.url, images)}
				/>
			{:else if a.kind === "video"}
				{@const box = fitBox(
					a.width && a.height ? { width: a.width, height: a.height } : declaredSize(a.url),
					400,
					320,
				)}
				<video
					controls
					preload="metadata"
					poster={a.posterUrl ?? undefined}
					src={a.url}
					class="rounded-lg border"
					style:border-color="var(--c-line-soft)"
					style:width="{box.width}px"
					style:height="{box.height}px"
					style:background="#000"
				></video>
			{:else if a.kind === "location"}
				<a
					href="https://www.openstreetmap.org/?mlat={a.lat}&mlon={a.lng}#map=16/{a.lat}/{a.lng}"
					target="_blank"
					rel="noopener noreferrer"
					class="flex items-center gap-2 rounded-md px-2.5 py-1.5 text-[13px] transition-colors"
					style:background="var(--c-chip)"
					style:color="var(--c-text-dim)"
				>
					<MapPin size={14} />
					<span>{a.name ?? `${a.lat.toFixed(4)}, ${a.lng.toFixed(4)}`}</span>
				</a>
			{:else if a.kind === "file"}
				{@render chip("file", a.name ?? "File")}
			{:else if a.kind === "poll"}
				{@render chip("poll", "Poll")}
			{:else if a.kind === "event"}
				{@render chip("calendar", "Event")}
			{/if}
		{/each}
	</div>
{/if}

{#snippet chip(icon: "file" | "poll" | "calendar", label: string)}
	<span
		class="flex items-center gap-2 rounded-md px-2.5 py-1.5 text-[13px]"
		style:background="var(--c-chip)"
		style:color="var(--c-text-dim)"
	>
		{#if icon === "file"}
			<FileIcon size={14} />
		{:else if icon === "poll"}
			<BarChart size={14} />
		{:else}
			<Calendar size={14} />
		{/if}
		<span>{label}</span>
	</span>
{/snippet}
