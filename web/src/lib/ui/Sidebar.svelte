<script lang="ts">
	import type { SidebarSection } from "$lib/state/conversations.svelte";
	import { DM_SECTION } from "$lib/state/conversations.svelte";
	import Avatar from "$lib/ui/Avatar.svelte";
	import ChevronDown from "@lucide/svelte/icons/chevron-down";
	import Hash from "@lucide/svelte/icons/hash";
	import MessageCircle from "@lucide/svelte/icons/message-circle";
	import BellOff from "@lucide/svelte/icons/bell-off";

	/**
	 * The channel list.
	 *
	 * Groups become sections and their topics become the channels inside,
	 * which is the mapping that made a Slack-shaped client worth building for
	 * GroupMe in the first place: the tree is already the right shape, it just
	 * has never been drawn that way.
	 *
	 * A group with no topics renders as a single row with no section header.
	 * Giving it a header and one child would be honest about the data model
	 * and useless to read.
	 */
	interface Props {
		sections: SidebarSection[];
		activeKey: string | null;
		collapsed: Set<string>;
		onSelect: (key: string) => void;
		onToggle: (id: string) => void;
	}

	let { sections, activeKey, collapsed, onSelect, onToggle }: Props = $props();
</script>

<nav class="flex flex-col gap-0.5 px-2 pb-6" aria-label="Conversations">
	{#each sections as section (section.id)}
		{@const isCollapsed = collapsed.has(section.id)}

		{#if section.flat}
			<!-- A plain group: one row, no header. -->
			{#each section.channels as ch (ch.key)}
				{@render channel(ch, 0)}
			{/each}
		{:else}
			<div class="mt-3 first:mt-1">
				<button
					type="button"
					class="group flex w-full items-center gap-2 rounded-md px-2 py-1 text-left transition-colors"
					onclick={() => onToggle(section.id)}
					aria-expanded={!isCollapsed}
				>
					<!-- Same 20px slot the rows below use, so the chevron, the
					     hashes and the avatars all sit on one vertical line. -->
					<span class="grid h-5 w-5 shrink-0 place-items-center">
						<ChevronDown
							size={14}
							class="opacity-60 transition-transform duration-150"
							style={isCollapsed ? "transform: rotate(-90deg)" : ""}
						/>
					</span>
					{#if section.id !== DM_SECTION}
						<Avatar name={section.title} url={section.avatarUrl} id={section.id} size={18} />
					{/if}
					<span
						class="flex-1 truncate text-[13px] font-bold tracking-[0.01em]"
						style:color="var(--c-text-dim)">{section.title}</span
					>
					{#if isCollapsed && section.unread > 0}
						<span
							class="tnum grid h-[18px] min-w-[18px] place-items-center rounded-full px-1 text-[11px] font-bold text-white"
							style:background="var(--c-unread)">{section.unread > 99 ? "99+" : section.unread}</span
						>
					{/if}
				</button>

				{#if !isCollapsed}
					<div class="mt-0.5 flex flex-col gap-px">
						{#each section.channels as ch (ch.key)}
							{@render channel(ch, 1)}
						{/each}
					</div>
				{/if}
			</div>
		{/if}
	{/each}
</nav>

{#snippet channel(ch: SidebarSection["channels"][number], depth: number)}
	{@const active = ch.key === activeKey}
	{@const bold = ch.unread > 0 && !ch.muted}
	<button
		type="button"
		class="flex h-7 w-full items-center gap-2 rounded-md pr-2 pl-2 text-left transition-colors"
		style:background={active ? "var(--c-accent)" : "transparent"}
		style:color={active
			? "var(--c-accent-ink)"
			: bold
				? "var(--c-text)"
				: ch.muted
					? "var(--c-text-faint)"
					: "var(--c-text-dim)"}
		onmouseenter={(e) => {
			if (!active) e.currentTarget.style.background = "var(--c-hover)";
		}}
		onmouseleave={(e) => {
			if (!active) e.currentTarget.style.background = "transparent";
		}}
		onclick={() => onSelect(ch.key)}
		aria-current={active ? "page" : undefined}
	>
		<!-- Every row gets the same 20px icon slot and the same indent,
		     whether it is a topic inside a section or a group that has none.
		     Indenting only the nested ones is technically truthful about the
		     hierarchy and leaves a ragged left edge that the eye has to
		     re-find on every row. Nesting is already said by the section
		     header above; saying it twice costs more than it explains. -->
		<span class="grid h-5 w-5 shrink-0 place-items-center">
			{#if depth > 0}
				<!-- A hash for a topic, the way a channel reads, and a speech
				     bubble for the group's own chat. A megaphone was here and
				     meant the wrong thing: that is the announcements glyph, and
				     the main chat is the opposite of an announcement. -->
				{#if ch.isMain}
					<MessageCircle size={15} class="opacity-55" />
				{:else}
					<Hash size={15} class="opacity-55" />
				{/if}
			{:else}
				<Avatar name={ch.name} url={ch.avatarUrl} id={ch.key} size={20} />
			{/if}
		</span>

		<span
			class="flex-1 truncate text-[15px] leading-7"
			style:font-weight={bold || active ? 700 : 400}>{ch.name}</span
		>

		{#if ch.muted}
			<BellOff size={13} class="shrink-0 opacity-50" />
		{/if}
		{#if ch.unread > 0 && !ch.muted && !active}
			<span
				class="tnum grid h-[18px] min-w-[18px] place-items-center rounded-full px-1 text-[11px] font-bold text-white"
				style:background="var(--c-unread)"
			>
				{ch.unread > 99 ? "99+" : ch.unread}
			</span>
		{/if}
	</button>
{/snippet}
