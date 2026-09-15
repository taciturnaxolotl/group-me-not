<script lang="ts">
	import { completeVerification, loginWithPassword, verifyToken, type LoginChallenge } from "$lib/auth/login";

	/**
	 * Sign-in.
	 *
	 * Password first because it is what people expect, token second because it
	 * is what works when a captcha gets in the way. Both are offered plainly
	 * rather than hiding the second behind "advanced", since needing it is not
	 * the user's fault.
	 */
	interface Props {
		onSignedIn: (token: string, identity: { userId: string; name: string; avatarUrl: string | null }) => void;
	}

	let { onSignedIn }: Props = $props();

	let mode = $state<"password" | "token">("password");
	let userName = $state("");
	let password = $state("");
	let token = $state("");
	let code = $state("");
	let challenge = $state<LoginChallenge | null>(null);
	let busy = $state(false);
	let error = $state<string | null>(null);

	async function submitPassword() {
		if (!userName || !password || busy) return;
		busy = true;
		error = null;
		try {
			const res = await loginWithPassword(userName, password);
			if (res.kind === "challenge") challenge = res;
			else onSignedIn(res.accessToken, res);
		} catch (e) {
			error = e instanceof Error ? e.message : "Could not sign in";
		} finally {
			busy = false;
		}
	}

	async function submitCode() {
		if (!challenge || code.length < 4 || busy) return;
		busy = true;
		error = null;
		try {
			const res = await completeVerification(challenge, code);
			if (res.kind === "success") onSignedIn(res.accessToken, res);
			else error = "That code was not accepted";
		} catch (e) {
			error = e instanceof Error ? e.message : "That code was not accepted";
		} finally {
			busy = false;
		}
	}

	async function submitToken() {
		if (!token.trim() || busy) return;
		busy = true;
		error = null;
		try {
			const identity = await verifyToken(token.trim());
			onSignedIn(token.trim(), identity);
		} catch (e) {
			error = e instanceof Error ? e.message : "That token was not accepted";
		} finally {
			busy = false;
		}
	}
</script>

<div class="grid h-full place-items-center px-6" style:background="var(--c-side)">
	<div class="w-full max-w-[22rem]">
		<h1 class="mb-1 text-[1.75rem] leading-none font-bold tracking-tight">GroupMeNot</h1>
		<p class="mb-7 text-[13px]" style:color="var(--c-text-faint)">
			A better window onto GroupMe.
		</p>

		{#if challenge}
			<p class="mb-3 text-[13px]" style:color="var(--c-text-dim)">
				Enter the code {challenge.destination ? `sent to ${challenge.destination}` : "you were sent"}.
			</p>
			<input
				bind:value={code}
				inputmode="numeric"
				autocomplete="one-time-code"
				placeholder="000000"
				class="tnum mb-3 w-full rounded-lg border px-3 py-2 text-center text-[18px] tracking-[0.3em] outline-none focus:border-[color:var(--c-link)]"
				style:border-color="var(--c-line)"
				style:background="var(--c-base)"
				onkeydown={(e) => e.key === "Enter" && submitCode()}
			/>
			{@render action("Verify", submitCode)}
		{:else if mode === "password"}
			<input
				bind:value={userName}
				autocomplete="username"
				placeholder="Email or phone"
				class="mb-2 w-full rounded-lg border px-3 py-2 outline-none focus:border-[color:var(--c-link)]"
				style:border-color="var(--c-line)"
				style:background="var(--c-base)"
			/>
			<input
				bind:value={password}
				type="password"
				autocomplete="current-password"
				placeholder="Password"
				class="mb-3 w-full rounded-lg border px-3 py-2 outline-none focus:border-[color:var(--c-link)]"
				style:border-color="var(--c-line)"
				style:background="var(--c-base)"
				onkeydown={(e) => e.key === "Enter" && submitPassword()}
			/>
			{@render action("Sign in", submitPassword)}
			<button
				type="button"
				class="mt-4 w-full text-center text-[13px] underline"
				style:color="var(--c-text-faint)"
				onclick={() => {
					mode = "token";
					error = null;
				}}>Use an access token instead</button
			>
		{:else}
			<p class="mb-3 text-[13px] leading-relaxed" style:color="var(--c-text-faint)">
				Paste an access token. You can read one from an existing GroupMe web session, or create
				one at <span style:color="var(--c-text-dim)">dev.groupme.com</span>.
			</p>
			<input
				bind:value={token}
				placeholder="Access token"
				spellcheck="false"
				class="mb-3 w-full rounded-lg border px-3 py-2 font-mono text-[13px] outline-none focus:border-[color:var(--c-link)]"
				style:border-color="var(--c-line)"
				style:background="var(--c-base)"
				onkeydown={(e) => e.key === "Enter" && submitToken()}
			/>
			{@render action("Continue", submitToken)}
			<button
				type="button"
				class="mt-4 w-full text-center text-[13px] underline"
				style:color="var(--c-text-faint)"
				onclick={() => {
					mode = "password";
					error = null;
				}}>Sign in with a password instead</button
			>
		{/if}

		{#if error}
			<p class="mt-3 text-[13px]" style:color="var(--c-unread)">{error}</p>
		{/if}
	</div>
</div>

{#snippet action(label: string, run: () => void)}
	<button
		type="button"
		class="h-10 w-full rounded-lg font-semibold transition-opacity disabled:opacity-50"
		style:background="var(--c-link)"
		style:color="oklch(0.99 0 0)"
		disabled={busy}
		onclick={run}
	>
		{busy ? "…" : label}
	</button>
{/snippet}
