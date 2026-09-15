/**
 * Where the token lives.
 *
 * `localStorage`, deliberately, and it is worth being honest about what that
 * means: any script running on this origin can read it. That is an acceptable
 * trade here only because this app loads no third-party script at all — no
 * analytics, no tag manager, no font CDN, no embeds. The fonts are bundled and
 * every request goes to a GroupMe host. If that ever stops being true, this
 * decision has to be revisited, not the other way round.
 *
 * `sessionStorage` would be worse, not better: it would log you out on every
 * tab close while remaining just as readable.
 */

const TOKEN_KEY = "gmn.token";
const USER_KEY = "gmn.user";

export interface StoredIdentity {
	userId: string;
	name: string;
	avatarUrl: string | null;
}

export function readToken(): string | null {
	return localStorage.getItem(TOKEN_KEY);
}

export function readIdentity(): StoredIdentity | null {
	const raw = localStorage.getItem(USER_KEY);
	if (!raw) return null;
	try {
		return JSON.parse(raw) as StoredIdentity;
	} catch {
		return null;
	}
}

export function saveSession(token: string, identity: StoredIdentity): void {
	localStorage.setItem(TOKEN_KEY, token);
	localStorage.setItem(USER_KEY, JSON.stringify(identity));
}

export function clearSession(): void {
	localStorage.removeItem(TOKEN_KEY);
	localStorage.removeItem(USER_KEY);
}
