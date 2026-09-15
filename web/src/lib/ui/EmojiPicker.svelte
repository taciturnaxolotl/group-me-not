<script lang="ts">
	import Search from "@lucide/svelte/icons/search";

	/**
	 * Emoji picker.
	 *
	 * Built from a static list rather than fetched, so it opens instantly and
	 * works with the radio off. Deliberately not the full Unicode set: fifteen
	 * hundred glyphs in a grid is a thing you scroll past, not a thing you
	 * pick from. These are the ones people actually send, grouped the way they
	 * are grouped everywhere else.
	 */
	interface Props {
		onPick: (glyph: string) => void;
		onClose: () => void;
	}

	let { onPick, onClose }: Props = $props();

	let query = $state("");
	let input = $state<HTMLInputElement | null>(null);

	$effect(() => {
		queueMicrotask(() => input?.focus());
	});

	const GROUPS: { name: string; items: [string, string][] }[] = [
		{
			name: "Reactions",
			items: [
				["❤️", "heart love"],
				["👍", "thumbs up yes like"],
				["👎", "thumbs down no"],
				["😂", "joy laugh funny lol"],
				["🤣", "rofl laugh funny"],
				["😭", "sob cry sad"],
				["🔥", "fire lit"],
				["💀", "skull dead dying"],
				["👀", "eyes look watching"],
				["🎉", "party tada celebrate"],
				["🙏", "pray thanks please"],
				["💯", "hundred perfect"],
				["✅", "check done yes"],
				["❌", "x no wrong"],
				["🫡", "salute yes sir"],
				["🤝", "handshake deal"],
			],
		},
		{
			name: "Faces",
			items: [
				["😀", "grin happy smile"],
				["😅", "sweat nervous laugh"],
				["🙂", "slight smile"],
				["😊", "blush happy"],
				["😍", "heart eyes love"],
				["😎", "cool sunglasses"],
				["🤔", "thinking hmm"],
				["😐", "neutral meh"],
				["🙄", "eye roll"],
				["😬", "grimace yikes"],
				["😳", "flushed shocked"],
				["🥲", "tear happy sad"],
				["😴", "sleep tired"],
				["🤒", "sick ill"],
				["🥳", "party face celebrate"],
				["😤", "triumph angry huff"],
			],
		},
		{
			name: "Hands & people",
			items: [
				["👋", "wave hi hello bye"],
				["🤷", "shrug idk"],
				["🙌", "raised hands praise"],
				["👏", "clap applause"],
				["💪", "muscle strong"],
				["🫶", "heart hands love"],
				["✌️", "peace victory"],
				["🤞", "fingers crossed luck"],
				["👉", "point right"],
				["🧠", "brain smart"],
				["🫠", "melting"],
				["🤡", "clown"],
			],
		},
		{
			name: "Things",
			items: [
				["☕", "coffee"],
				["🍕", "pizza food"],
				["🍺", "beer drink"],
				["🎂", "cake birthday"],
				["🚗", "car drive"],
				["📚", "books study school"],
				["💻", "laptop computer work"],
				["📷", "camera photo"],
				["🎵", "music note"],
				["⚽", "soccer ball sport"],
				["🌧️", "rain weather"],
				["☀️", "sun sunny weather"],
				["🌙", "moon night"],
				["⭐", "star"],
				["🕐", "clock time"],
				["📍", "pin location"],
			],
		},
	];

	let results = $derived.by(() => {
		const q = query.trim().toLowerCase();
		if (!q) return GROUPS;
		const hit = (i: [string, string]) => i[1].includes(q) || i[0] === q;
		return GROUPS.map((g) => ({ ...g, items: g.items.filter(hit) })).filter((g) => g.items.length);
	});
</script>

<div
	class="absolute bottom-full left-0 z-30 mb-2 w-[19rem] overflow-hidden rounded-lg border"
	style:border-color="var(--c-line)"
	style:background="var(--c-raise)"
	style:box-shadow="var(--shadow-pop)"
	role="dialog"
	aria-label="Emoji"
>
	<div
		class="flex items-center gap-2 border-b px-2.5 py-2"
		style:border-color="var(--c-line-soft)"
	>
		<Search size={13} style="opacity:0.5" />
		<input
			bind:this={input}
			bind:value={query}
			placeholder="Search"
			class="flex-1 bg-transparent text-[13px] outline-none placeholder:text-[color:var(--c-text-faint)]"
			onkeydown={(e) => {
				if (e.key === "Escape") {
					e.preventDefault();
					onClose();
				}
			}}
		/>
	</div>

	<div class="scroller max-h-[17rem] px-1.5 py-1.5">
		{#each results as group (group.name)}
			<div
				class="px-1.5 pt-1.5 pb-1 text-[11px] font-semibold tracking-wide uppercase"
				style:color="var(--c-text-faint)"
			>
				{group.name}
			</div>
			<div class="grid grid-cols-8 gap-0.5">
				{#each group.items as [glyph] (glyph)}
					<button
						type="button"
						class="grid h-8 w-8 place-items-center rounded text-[18px] transition-transform hover:scale-115"
						onclick={() => onPick(glyph)}
						title={glyph}>{glyph}</button
					>
				{/each}
			</div>
		{:else}
			<div class="px-2 py-6 text-center text-[13px]" style:color="var(--c-text-faint)">
				Nothing matches that.
			</div>
		{/each}
	</div>
</div>
