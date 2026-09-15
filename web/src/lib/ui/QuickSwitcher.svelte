<script lang="ts">
	import type { SidebarSection } from "$lib/state/conversations.svelte";
	import Avatar from "$lib/ui/Avatar.svelte";

	/**
	 * Cmd-K.
	 *
	 * The single feature that most separates a keyboard client from a mouse
	 * one, and the reason is arithmetic: reaching a chat by eye means scanning
	 * sixty rows, and reaching it by name means typing three letters. On a
	 * phone the first is fine. With a keyboard under your hands it is absurd.
	 *
	 * Matching is a subsequence test rather than a substring one, so "asn"
	 * finds "ASSASSINS" and "cfk" finds "CONFIRMED KILLS".
	 */
	interface Props {
		open: boolean;
		sections: SidebarSection[];
		onPick: (key: string) => void;
		onClose: () => void;
	}

	let { open, sections, onPick, onClose }: Props = $props();

	let query = $state("");
	let index = $state(0);
	let input = $state<HTMLInputElement | null>(null);

	interface Entry {
		key: string;
		name: string;
		context: string;
		avatarUrl: string | null;
		unread: number;
		updatedAt: number;
	}

	let all = $derived.by((): Entry[] => {
		const out: Entry[] = [];
		for (const s of sections) {
			for (const c of s.channels) {
				out.push({
					key: c.key,
					name: c.isMain ? s.title : c.name,
					context: c.isMain || s.flat ? "" : s.title,
					avatarUrl: c.avatarUrl ?? s.avatarUrl,
					unread: c.unread,
					updatedAt: c.updatedAt,
				});
			}
		}
		return out;
	});

	let results = $derived.by(() => {
		const q = query.trim().toLowerCase();
		if (!q) return [...all].sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 12);
		return all
			.map((e) => ({ e, score: score(`${e.name} ${e.context}`.toLowerCase(), q) }))
			.filter((r) => r.score >= 0)
			.sort((a, b) => a.score - b.score || b.e.updatedAt - a.e.updatedAt)
			.slice(0, 12)
			.map((r) => r.e);
	});

	$effect(() => {
		void results;
		index = 0;
	});

	$effect(() => {
		if (open) {
			query = "";
			queueMicrotask(() => input?.focus());
		}
	});

	/**
	 * Subsequence match, scored by how tightly packed the hits are.
	 *
	 * A run of adjacent characters beats the same letters scattered across a
	 * long name, which is what makes "main" find "Main" rather than
	 * "M-arsh-a-ll 1 f-i-re"'s worth of coincidences.
	 */
	function score(haystack: string, needle: string): number {
		let i = 0;
		let cost = 0;
		let last = -1;
		for (const ch of needle) {
			const at = haystack.indexOf(ch, i);
			if (at < 0) return -1;
			if (last >= 0) cost += at - last - 1;
			last = at;
			i = at + 1;
		}
		return cost;
	}

	function onKeydown(e: KeyboardEvent) {
		if (e.key === "Escape") {
			e.preventDefault();
			onClose();
		} else if (e.key === "ArrowDown") {
			e.preventDefault();
			index = Math.min(index + 1, results.length - 1);
		} else if (e.key === "ArrowUp") {
			e.preventDefault();
			index = Math.max(index - 1, 0);
		} else if (e.key === "Enter") {
			e.preventDefault();
			const pick = results[index];
			if (pick) onPick(pick.key);
		}
	}
</script>

{#if open}
	<div
		class="fixed inset-0 z-50 flex items-start justify-center pt-[12vh]"
		style:background="oklch(0 0 0 / 0.45)"
		onclick={onClose}
		onkeydown={() => {}}
		role="presentation"
	>
		<div
			class="w-full max-w-[34rem] overflow-hidden rounded-xl border"
			style:border-color="var(--c-line)"
			style:background="var(--c-base)"
			style:box-shadow="var(--shadow-pop)"
			onclick={(e) => e.stopPropagation()}
			onkeydown={onKeydown}
			role="dialog"
			aria-modal="true"
			aria-label="Jump to conversation"
			tabindex="-1"
		>
			<input
				bind:this={input}
				bind:value={query}
				placeholder="Jump to…"
				class="w-full border-b bg-transparent px-4 py-3 text-[15px] outline-none placeholder:text-[color:var(--c-text-faint)]"
				style:border-color="var(--c-line-soft)"
			/>

			<div class="scroller max-h-[52vh] py-1">
				{#each results as r, i (r.key)}
					<button
						type="button"
						class="flex w-full items-center gap-2.5 px-3 py-2 text-left"
						style:background={i === index ? "var(--c-active)" : "transparent"}
						onmouseenter={() => (index = i)}
						onclick={() => onPick(r.key)}
					>
						<Avatar name={r.name} url={r.avatarUrl} id={r.key} size={22} />
						<span class="min-w-0 flex-1 truncate text-[14px]">{r.name}</span>
						{#if r.context}
							<span class="shrink-0 text-[12px]" style:color="var(--c-text-faint)">{r.context}</span>
						{/if}
						{#if r.unread}
							<span
								class="tnum grid h-[18px] min-w-[18px] place-items-center rounded-full px-1 text-[11px] font-bold text-white"
								style:background="var(--c-unread)">{r.unread}</span
							>
						{/if}
					</button>
				{:else}
					<div class="px-4 py-6 text-center text-[13px]" style:color="var(--c-text-faint)">
						Nothing matches that.
					</div>
				{/each}
			</div>
		</div>
	</div>
{/if}
