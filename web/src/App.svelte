<script lang="ts">
	import { Engine } from "$lib/sync/engine.svelte";
	import type { Message } from "$lib/model/types";
	import SignIn from "$lib/ui/SignIn.svelte";
	import Sidebar from "$lib/ui/Sidebar.svelte";
	import MessageList from "$lib/ui/MessageList.svelte";
	import Composer from "$lib/ui/Composer.svelte";
	import QuickSwitcher from "$lib/ui/QuickSwitcher.svelte";
	import Avatar from "$lib/ui/Avatar.svelte";
	import Lightbox from "$lib/ui/Lightbox.svelte";
	import Search from "@lucide/svelte/icons/search";
	import Inbox from "@lucide/svelte/icons/inbox";
	import PanelLeft from "@lucide/svelte/icons/panel-left";
	import Hash from "@lucide/svelte/icons/hash";
	import Users from "@lucide/svelte/icons/users";
	import Megaphone from "@lucide/svelte/icons/megaphone";
	import { release, stage, toAttachments, upload, type Staged } from "$lib/ui/attachments";
	import { Appearance } from "$lib/state/appearance.svelte";

	const engine = new Engine();
	// Instantiated for the side effect: it applies the stored preference and
	// keeps following the system when that is what was chosen. There is no
	// control for it, because a theme switch is a settings item rather than
	// something that earns permanent space beside a person's own name.
	new Appearance();

	let switcherOpen = $state(false);
	let replyTo = $state<Message | null>(null);
	let lightbox = $state<{ url: string; all: string[] } | null>(null);
	let drafts = $state<Map<string, string>>(new Map());
	/**
	 * Attachments waiting to be sent, per conversation.
	 *
	 * Keyed by conversation so that picking a photo, wandering off to read
	 * something else and coming back does not lose it — the same reason drafts
	 * are keyed that way.
	 */
	let stagedByKey = $state<Map<string, Staged[]>>(new Map());
	let sidebarOpen = $state(true);

	let active = $derived(engine.activeKey ? engine.conversations.get(engine.activeKey) : undefined);
	// Read, never create. `engine.timeline()` lazily inserts into a `$state`
	// map, and doing that from inside a derived is writing state during a
	// read, which Svelte refuses. The engine has already created the timeline
	// by the time a conversation is active.
	let timeline = $derived(engine.activeKey ? (engine.timelines.get(engine.activeKey) ?? null) : null);
	let selfId = $derived(engine.conversations.me?.id ?? "");

	let groupId = $derived.by(() => {
		const id = active?.id;
		if (!id) return null;
		return id.kind === "topic" ? id.parentId : id.kind === "group" ? id.id : null;
	});
	let members = $derived(groupId ? (engine.conversations.members.get(groupId) ?? []) : []);

	/**
	 * Whether this account may post here.
	 *
	 * A topic of type `announcement` accepts messages from admins and the
	 * owner only; everyone else gets a 403. Offering a composer that is
	 * guaranteed to fail is worse than not offering one — the message is
	 * written, sent, and bounces, and nothing on screen said it would.
	 *
	 * Roles live on the *parent* group's roster, since a topic has no
	 * membership of its own. Default to allowing it: if the roster has not
	 * loaded yet, a composer that might fail beats a false lockout.
	 */
	let canPost = $derived.by(() => {
		if (!active || active.access !== "announcement") return true;
		if (!members.length) return true;
		const me = members.find((m) => m.userId === selfId);
		if (!me) return true;
		return me.roles.some((r) => r === "admin" || r === "owner");
	});

	let draft = $derived(engine.activeKey ? (drafts.get(engine.activeKey) ?? "") : "");
	let staged = $derived(engine.activeKey ? (stagedByKey.get(engine.activeKey) ?? []) : []);

	function setStaged(key: string, items: Staged[]) {
		const next = new Map(stagedByKey);
		items.length ? next.set(key, items) : next.delete(key);
		stagedByKey = next;
	}

	/**
	 * Take files, show them immediately, and upload in the background.
	 *
	 * The chip appears at once in an uploading state so there is feedback
	 * before the network has done anything, and each upload settles its own
	 * chip independently — one failure does not take the others with it.
	 */
	async function addFiles(files: File[]) {
		const key = engine.activeKey;
		const conv = key ? engine.conversationFor(key) : null;
		if (!key || !conv) return;

		const fresh = files.map(stage);
		setStaged(key, [...(stagedByKey.get(key) ?? []), ...fresh]);

		await Promise.all(
			fresh.map(async (item) => {
				const done = await upload(engine.api, conv, item);
				// Re-read rather than closing over the array: other uploads
				// finish while this one is in flight, and a stale copy would
				// drop them.
				const current = stagedByKey.get(key) ?? [];
				if (!current.some((s) => s.id === item.id)) {
					release(item); // removed while uploading
					return;
				}
				setStaged(
					key,
					current.map((s) => (s.id === item.id ? done : s)),
				);
			}),
		);
	}

	function removeStaged(id: string) {
		const key = engine.activeKey;
		if (!key) return;
		const current = stagedByKey.get(key) ?? [];
		const gone = current.find((s) => s.id === id);
		if (gone) release(gone);
		setStaged(
			key,
			current.filter((s) => s.id !== id),
		);
	}

	$effect(() => {
		void engine.boot();
	});

	// The title carries the unread count, which is the only notification a
	// browser tab gives you for free.
	$effect(() => {
		const n = engine.conversations.totalUnread;
		document.title = n > 0 ? `(${n}) GroupMeNot` : "GroupMeNot";
	});

	function nameOf(userId: string): string | null {
		return engine.conversations.memberName(groupId, userId);
	}

	function setDraft(text: string) {
		if (!engine.activeKey) return;
		const next = new Map(drafts);
		next.set(engine.activeKey, text);
		drafts = next;
	}

	function open(key: string) {
		replyTo = null;
		switcherOpen = false;
		void engine.open(key);
	}

	function onKeydown(e: KeyboardEvent) {
		const mod = e.metaKey || e.ctrlKey;
		if (mod && e.key.toLowerCase() === "k") {
			e.preventDefault();
			switcherOpen = !switcherOpen;
			return;
		}
		if (e.key === "Escape" && lightbox) {
			lightbox = null;
			return;
		}
		// A bare slash focuses the composer, unless the user is already typing
		// somewhere — otherwise it eats the character.
		const target = e.target as HTMLElement | null;
		const typing = target?.tagName === "INPUT" || target?.tagName === "TEXTAREA";
		if (!typing && e.key === "/") {
			e.preventDefault();
			document.querySelector<HTMLTextAreaElement>("[data-composer]")?.focus();
		}
	}
</script>

<svelte:window onkeydown={onKeydown} />

{#if engine.booting}
	<!-- Deliberately blank. A three-state session — unknown, out, in — is the
	     difference between a reload that settles and one that flashes the
	     sign-in screen at somebody who signed in weeks ago. -->
	<div class="h-full" style:background="var(--c-side)"></div>
{:else if !engine.signedIn}
	<SignIn onSignedIn={(token, identity) => engine.adoptSession(token, identity)} />
{:else}
	<div class="flex h-full flex-col" style:background="var(--c-rail)">
		<!-- Top bar.
		     A fixed home for search that does not move when the sidebar
		     scrolls, and the thing that makes the two panes below read as one
		     window rather than two columns bolted together. -->
		<header class="on-rail flex h-11 shrink-0 items-center px-3" style:color="var(--c-text)">
			<span class="w-[15.4rem] shrink-0 truncate pl-1 text-[15px] font-bold tracking-tight">
				GroupMeNot
			</span>
			<button
				type="button"
				class="mx-auto flex h-7 w-full max-w-[40rem] items-center gap-2 rounded-md px-2.5 text-[13px] transition-colors hover:brightness-125"
				style:background="var(--c-side)"
				style:color="var(--c-text-faint)"
				onclick={() => (switcherOpen = true)}
			>
				<Search size={14} />
				<span class="flex-1 text-left">Jump to a conversation</span>
				<kbd class="text-[11px] tracking-wide opacity-60">⌘K</kbd>
			</button>
			<div class="flex w-[15.4rem] shrink-0 items-center justify-end gap-1">
				<button
					type="button"
					class="grid h-7 w-7 place-items-center rounded-md transition-colors"
					style:background={engine.conversations.filter === "unread"
						? "var(--c-active)"
						: "transparent"}
					style:color={engine.conversations.filter === "unread"
						? "var(--c-text)"
						: "var(--c-text-faint)"}
					title="Unread only"
					aria-pressed={engine.conversations.filter === "unread"}
					onclick={() =>
						(engine.conversations.filter =
							engine.conversations.filter === "unread" ? "all" : "unread")}
				>
					<Inbox size={15} />
				</button>
			</div>
		</header>

		<div class="flex min-h-0 flex-1">
			<!-- Sidebar -->
			{#if sidebarOpen}
				<aside
					class="on-rail flex w-[17.4rem] shrink-0 flex-col"
					style:background="var(--c-side)"
					style:color="var(--c-text)"
				>
					<div class="scroller min-h-0 flex-1 pt-2 pb-2">
						<Sidebar
							sections={engine.conversations.sections}
							activeKey={engine.activeKey}
							collapsed={engine.conversations.collapsed}
							onSelect={open}
							onToggle={(id) => engine.conversations.toggleSection(id)}
						/>
					</div>

					<footer class="flex items-center gap-2.5 px-3 py-2.5">
						<Avatar
							name={engine.conversations.me?.name ?? ""}
							url={engine.conversations.me?.avatarUrl}
							id={selfId}
							size={24}
						/>
						<span class="min-w-0 flex-1 truncate text-[13px] font-medium"
							>{engine.conversations.me?.name ?? ""}</span
						>
						{#if engine.connection !== "live"}
							<!-- Shown only when it is not working. A green light
							     that is always on is decoration; the only state
							     worth a pixel is the one that needs explaining. -->
							<span class="text-[11px]" style:color="var(--c-text-faint)">
								{engine.online ? "Reconnecting…" : "Offline"}
							</span>
						{/if}
						<button
							type="button"
							class="text-[12px] transition-colors hover:brightness-150"
							style:color="var(--c-text-faint)"
							onclick={() => engine.signOut()}>Sign out</button
						>
					</footer>
				</aside>
			{/if}

			<!-- Main.
			     Flush against the sidebar, square, no border. Measured from
			     Slack itself, whose primary view reports `border-radius: 0px`
			     and `margin: 0px`: the panes meet at a colour change and
			     nothing else. A floating rounded card with a hairline was the
			     invention here, and it read as one. -->
			<main class="flex min-w-0 flex-1 flex-col" style:background="var(--c-base)">
				{#if !active || !timeline}
					<div class="grid h-full place-items-center px-6 text-center">
						<div>
							<p class="mb-1 text-[15px] font-semibold">Nothing open</p>
							<p class="text-[13px]" style:color="var(--c-text-faint)">
								Pick a conversation, or press <kbd class="font-medium">⌘K</kbd>.
							</p>
						</div>
					</div>
				{:else}
					<header
						class="flex h-12 shrink-0 items-center gap-2 border-b px-4"
						style:border-color="var(--c-line-soft)"
					>
						<button
							type="button"
							class="-ml-1 grid h-7 w-7 place-items-center rounded-md transition-colors"
							style:color="var(--c-text-faint)"
							onclick={() => (sidebarOpen = !sidebarOpen)}
							aria-label="Toggle sidebar"><PanelLeft size={15} /></button
						>
						{#if active.id.kind === "topic"}
							<Hash size={15} class="shrink-0 opacity-60" />
						{:else}
							<Avatar name={active.name} url={active.avatarUrl} id={active.key} size={22} />
						{/if}
						<h1 class="shrink-0 text-[15px] leading-tight font-bold">
							{active.name}
						</h1>
						{#if active.description}
							<span class="mx-1 h-4 w-px shrink-0" style:background="var(--c-line)"></span>
							<p class="min-w-0 truncate text-[13px]" style:color="var(--c-text-faint)">
								{active.description}
							</p>
						{/if}
						<div class="flex-1"></div>
						{#if members.length}
							<span
								class="flex items-center gap-1.5 rounded-md px-2 py-1 text-[12px]"
								style:color="var(--c-text-dim)"
							>
								<Users size={14} />
								<span class="tnum">{members.length}</span>
							</span>
						{/if}
					</header>

				{#if !engine.online || engine.phase === "failed"}
					<div
						class="px-5 py-1.5 text-center text-[12px]"
						style:background="var(--c-raise)"
						style:color="var(--c-text-dim)"
					>
						{engine.online ? (engine.lastError ?? "Could not refresh") : "Offline"} — showing what
						we have.
					</div>
				{/if}

				<MessageList
					{timeline}
					{selfId}
					{nameOf}
					onLoadOlder={() => engine.activeKey && engine.loadOlder(engine.activeKey)}
					onReply={(m) => (replyTo = m)}
					onReact={(m, glyph) => {
						const mine = m.reactions.find((r) => r.userIds.includes(selfId));
						const next = mine?.code === glyph ? null : glyph;
						if (engine.activeKey) void engine.react(engine.activeKey, m.id, next);
					}}
					onEdit={(m, text) => engine.activeKey && void engine.editMessage(engine.activeKey, m.id, text)}
					onDelete={(m) => engine.activeKey && void engine.remove(engine.activeKey, m.id)}
					canEdit={(m) => (engine.activeKey ? engine.canEdit(engine.activeKey, m) : false)}
					onRetry={(m) => engine.retrySend(m.sourceGuid)}
					onDiscard={(m) => engine.activeKey && engine.discardSend(engine.activeKey, m.sourceGuid, m.id)}
					onOpenImage={(url, all) => (lightbox = { url, all })}
				/>

				{#if timeline.typingNames.length}
					<div class="px-5 pb-1 text-[12px] italic" style:color="var(--c-text-faint)">
						{timeline.typingNames.map((id) => nameOf(id) ?? "Someone").join(", ")}
						{timeline.typingNames.length === 1 ? "is" : "are"} typing…
					</div>
				{/if}

				{#if !canPost}
					<!-- Says why rather than leaving a blank strip where the
					     composer was, which reads as something still loading. -->
					<div class="px-5 pb-5">
						<div
							class="flex items-center justify-center gap-2 rounded-lg border px-3 py-2.5 text-[13px]"
							style:border-color="var(--c-line)"
							style:background="var(--c-sunken)"
							style:color="var(--c-text-dim)"
						>
							<Megaphone size={14} />
							Only admins can post in this channel.
						</div>
					</div>
				{:else}
				<Composer
					placeholder={active.id.kind === "dm"
						? `Message ${active.name}`
						: `Message ${active.id.kind === "topic" ? "#" : ""}${active.name}`}
					bind:draft={() => draft, setDraft}
					{replyTo}
					{members}
					{staged}
					onSend={(text) => {
						const key = engine.activeKey;
						if (!key) return;
						const items = stagedByKey.get(key) ?? [];
						void engine.send(key, text, replyTo, toAttachments(items));
						for (const item of items) release(item);
						setStaged(key, []);
						replyTo = null;
					}}
					onTyping={() => engine.activeKey && engine.noteTyping(engine.activeKey)}
					onCancelReply={() => (replyTo = null)}
					onDraft={setDraft}
					onFiles={(files) => void addFiles(files)}
					onRemoveStaged={removeStaged}
				/>
				{/if}
			{/if}
		</main>
		</div>
	</div>

	<QuickSwitcher
		open={switcherOpen}
		sections={engine.conversations.sections}
		onPick={open}
		onClose={() => (switcherOpen = false)}
	/>

	{#if lightbox}
		<Lightbox url={lightbox.url} all={lightbox.all} onClose={() => (lightbox = null)} />
	{/if}
{/if}
