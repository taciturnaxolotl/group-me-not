/**
 * Sign-in.
 *
 * Two ways in, because they fail in different situations and neither covers
 * everything:
 *
 *   - **Password.** A real sign-in against `v2.groupme.com/access_tokens`,
 *     including the SMS/email verification step. Works from a static page
 *     because every GroupMe host answers preflight with
 *     `Access-Control-Allow-Origin: *`, which is not something you would
 *     assume without checking.
 *
 *   - **Paste a token.** For accounts where the password path is blocked by a
 *     captcha, and for anyone who would rather not type a password into a
 *     third-party client. Entirely reasonable, and the fastest path if you
 *     already have a session in another client.
 */

const AUTH_HOST = "https://v2.groupme.com";

/**
 * The pre-login token, which is not a token.
 *
 * `X-Access-Token` on a login request carries a SHA-256 of a hardcoded salt
 * joined to the platform id, device id and username. It is a client-identity
 * check rather than a secret — anything that can compute the hash can present
 * it, and the salt is a constant sitting in the shipped app. It exists to make
 * casual scripted login slightly more annoying, and the server rejects a login
 * without it.
 */
const LOGIN_SALT = "48ea3317-4a12-4a30-9b87-efdf2dc1b9ec";

/**
 * The platform we present as.
 *
 * The server derives nothing from this beyond checking it matches the hash, so
 * it has to agree with whatever the hash was computed over. Kept together here
 * so the two cannot drift apart.
 */
const PLATFORM_ID = "Android-262370304";

export interface LoginSuccess {
	kind: "success";
	accessToken: string;
	userId: string;
	name: string;
	avatarUrl: string | null;
}

/**
 * The server wants a code before it will finish.
 *
 * Carry the whole thing back into `completeVerification` — the verification
 * token is opaque and has to be echoed exactly.
 */
export interface LoginChallenge {
	kind: "challenge";
	verificationToken: string;
	/** Where the code went, when the server says. */
	via: string | null;
	/** Masked destination, e.g. `(***) ***-1234`. */
	destination: string | null;
	/** How many characters the code will be, when the server chooses. */
	length: number | null;
}

export type LoginResult = LoginSuccess | LoginChallenge;

export class LoginError extends Error {
	readonly code: number;
	constructor(message: string, code: number) {
		super(message);
		this.name = "LoginError";
		this.code = code;
	}
	/** A banned account. Retrying will never help. */
	get permanent(): boolean {
		return this.code === 40121;
	}
}

/** A stable per-browser id, minted once and kept. */
export function deviceId(): string {
	const KEY = "gmn.device";
	let id = localStorage.getItem(KEY);
	if (!id) {
		id = crypto.randomUUID();
		localStorage.setItem(KEY, id);
	}
	return id;
}

async function preLoginHash(userName: string): Promise<string> {
	const input = `${LOGIN_SALT}${PLATFORM_ID}${deviceId()}${userName}`;
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
	return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function loginWithPassword(userName: string, password: string): Promise<LoginResult> {
	const body = new URLSearchParams({
		user_name: userName,
		password,
		grant_type: "password",
		app_id: PLATFORM_ID,
		app_version: PLATFORM_ID.split("-")[1] ?? "",
		device_id: deviceId(),
	});

	const res = await fetch(`${AUTH_HOST}/access_tokens`, {
		method: "POST",
		headers: {
			"content-type": "application/x-www-form-urlencoded",
			"x-access-token": await preLoginHash(userName),
			"x-client-capabilities": "otp-variable-length",
		},
		body,
	});

	return interpret(await res.json().catch(() => ({})));
}

/** Second leg of a challenge: the code the user just received. */
export async function completeVerification(
	challenge: LoginChallenge,
	code: string,
): Promise<LoginResult> {
	// Note the shape change between legs. The first is form-encoded; this one
	// is JSON, against the same URL. Sending form data here fails in a way
	// that looks like a wrong code.
	const res = await fetch(`${AUTH_HOST}/access_tokens`, {
		method: "POST",
		headers: {
			"content-type": "application/json",
			"x-verify-token": challenge.verificationToken,
			"x-verify-id": code,
		},
		body: JSON.stringify({
			grant_type: "password",
			app_id: PLATFORM_ID,
			device_id: deviceId(),
			verification_code: code,
			verification_token: challenge.verificationToken,
		}),
	});

	return interpret(await res.json().catch(() => ({})));
}

interface AuthEnvelope {
	meta?: { code?: number; errors?: string[] };
	response?: {
		access_token?: string;
		user_id?: string;
		user_name?: string;
		image_url?: string | null;
		verification?: {
			type?: string;
			code?: string;
			long_pin?: string;
			system_number?: string;
			token?: string;
			length?: number;
			methods?: { sms?: string; email?: string };
		};
	};
}

function interpret(body: AuthEnvelope): LoginResult {
	const code = body.meta?.code ?? 0;
	const r = body.response ?? {};

	if (r.access_token && r.user_id) {
		return {
			kind: "success",
			accessToken: r.access_token,
			userId: String(r.user_id),
			name: r.user_name ?? "",
			avatarUrl: r.image_url ?? null,
		};
	}

	// 20200 is the documented challenge code, but the presence of a
	// `verification` block is the more reliable signal — the code has moved
	// before and the block has not.
	if (r.verification || code === 20200) {
		const v = r.verification ?? {};
		return {
			kind: "challenge",
			verificationToken: v.token ?? v.long_pin ?? "",
			via: v.methods?.sms ? "sms" : v.methods?.email ? "email" : (v.type ?? null),
			destination: v.system_number ?? v.methods?.sms ?? v.methods?.email ?? null,
			length: v.length ?? null,
		};
	}

	const message = body.meta?.errors?.join(", ") || "Could not sign in";
	throw new LoginError(message, code);
}

/**
 * Check a pasted token by spending one request on it.
 *
 * Better to find out here than to let a bad token through and have the whole
 * app boot into a wall of 401s.
 */
export async function verifyToken(
	token: string,
): Promise<{ userId: string; name: string; avatarUrl: string | null }> {
	const res = await fetch("https://api.groupme.com/v3/users/me", {
		headers: { "x-access-token": token, accept: "application/json" },
	});
	if (!res.ok) throw new LoginError("That token was not accepted", res.status);
	const body = (await res.json()) as { response?: { id?: string; name?: string; image_url?: string } };
	const me = body.response;
	if (!me?.id) throw new LoginError("That token was not accepted", 401);
	return { userId: String(me.id), name: me.name ?? "", avatarUrl: me.image_url ?? null };
}
