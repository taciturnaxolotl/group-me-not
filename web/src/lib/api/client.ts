import { ApiError } from "./errors";

/**
 * The HTTP layer. One place that knows about hosts, headers, the response
 * envelope, and how long to wait before trying again.
 *
 * Everything above this file deals in plain typed values and `ApiError`.
 */

export const HOSTS = {
	/** Everything REST. v2, v3 and v4 all live here under different prefixes. */
	api: "https://api.groupme.com",
	/** Image ingest. Returns a canonical `i.groupme.com` URL. */
	image: "https://image.groupme.com",
	/** Video ingest and transcode status. */
	video: "https://video.groupme.com",
	/** Arbitrary file attachments, scoped per conversation. */
	file: "https://file.groupme.com",
	/** Bayeux. WebSocket only — see `realtime/bayeux.ts` for why. */
	push: "wss://push.groupme.com/faye",
} as const;

/**
 * The API version prefixes, which are not interchangeable.
 *
 * v3 is the bulk of the surface. v4 is where the newer, better-shaped routes
 * live: `relationships` (cursor paginated), `read_receipts` (every chat in one
 * request instead of one request per chat), `pinned_conversations`. The
 * official web client uses all three, so they are as supported as anything.
 *
 * v1 is a single outlier — presence — and it does not use the `meta`/`response`
 * envelope the others do. The unwrap below tolerates that rather than making
 * one caller special.
 */
export type ApiVersion = "v1" | "v2" | "v3" | "v4";

/**
 * Identifies us to the server.
 *
 * The official web client sends `GroupMeWeb/1.2.3`. Matching it is not about
 * pretending to be them; it is that unrecognised clients have historically
 * been the first to get throttled, and this header costs nothing.
 */
const CLIENT_ID = "GroupMeWeb/1.2.3";

/**
 * Query values. Arrays repeat the key rather than joining with commas:
 * `include=unread_count&include=last_read_at`, which is what the server wants
 * and not what a naive `join(",")` would produce.
 */
export type QueryValue = string | number | boolean | undefined | null | readonly string[];

export interface RequestOptions {
	version?: ApiVersion;
	query?: Record<string, QueryValue>;
	body?: unknown;
	/** Extra headers. Used by the upload services, which want odd ones. */
	headers?: Record<string, string>;
	signal?: AbortSignal;
	/** Override the host. Uploads talk to image/video/file, not api. */
	host?: string;
	/** Wall-clock budget for one attempt, before retries. */
	timeoutMs?: number;
	/** How many times to retry a retryable failure. */
	retries?: number;
	/**
	 * Return the raw `Response` instead of unwrapping `meta`/`response`.
	 * The upload hosts do not all use the envelope.
	 */
	raw?: boolean;
}

type TokenSource = () => string | null;
type UnauthorizedHandler = () => void;

/** Envelope every api.groupme.com route wraps its payload in. */
interface Envelope<T> {
	meta?: { code?: number; errors?: string[] };
	response?: T;
}

export class ApiClient {
	#token: TokenSource;
	#onUnauthorized: UnauthorizedHandler;

	/**
	 * When the server hands back a 429 we stop sending until it says we may.
	 * Shared across every in-flight request, because the limit is per account,
	 * not per endpoint: letting thirty parallel requests each discover the
	 * limit separately is how a brief throttle becomes a long one.
	 */
	#throttledUntil = 0;

	constructor(token: TokenSource, onUnauthorized: UnauthorizedHandler = () => {}) {
		this.#token = token;
		this.#onUnauthorized = onUnauthorized;
	}

	get<T>(path: string, opts: RequestOptions = {}): Promise<T> {
		return this.#send<T>("GET", path, opts);
	}
	post<T>(path: string, opts: RequestOptions = {}): Promise<T> {
		return this.#send<T>("POST", path, opts);
	}
	put<T>(path: string, opts: RequestOptions = {}): Promise<T> {
		return this.#send<T>("PUT", path, opts);
	}
	delete<T>(path: string, opts: RequestOptions = {}): Promise<T> {
		return this.#send<T>("DELETE", path, opts);
	}

	async #send<T>(method: string, path: string, opts: RequestOptions): Promise<T> {
		const retries = opts.retries ?? defaultRetries(method);
		let attempt = 0;

		for (;;) {
			await this.#waitOutThrottle(opts.signal);
			try {
				return await this.#attempt<T>(method, path, opts);
			} catch (err) {
				const e = err instanceof ApiError ? err : new ApiError("network", String(err));

				if (e.kind === "unauthorized") {
					this.#onUnauthorized();
					throw e;
				}
				if (e.kind === "rateLimited") {
					// Trust the server's number when it gives one. Its absence
					// is common, so fall back to something polite.
					const wait = (e.retryAfter ?? 5) * 1000;
					this.#throttledUntil = Math.max(this.#throttledUntil, Date.now() + wait);
				}
				if (!e.retryable || attempt >= retries) throw e;

				await sleep(backoffMs(attempt, e), opts.signal);
				attempt += 1;
			}
		}
	}

	async #attempt<T>(method: string, path: string, opts: RequestOptions): Promise<T> {
		const token = this.#token();
		const url = buildUrl(path, opts);

		const headers: Record<string, string> = {
			accept: "application/json",
			"x-requested-with": CLIENT_ID,
			...opts.headers,
		};
		if (token) headers["x-access-token"] = token;

		let payload: BodyInit | undefined;
		if (opts.body instanceof FormData || opts.body instanceof Blob) {
			payload = opts.body;
		} else if (opts.body instanceof ArrayBuffer || ArrayBuffer.isView(opts.body)) {
			payload = opts.body as BodyInit;
		} else if (opts.body !== undefined) {
			payload = JSON.stringify(opts.body);
			headers["content-type"] = "application/json";
		}

		// One timeout per attempt, combined with any caller-supplied signal so
		// that closing a view cancels the request rather than leaking it.
		const budget = AbortSignal.timeout(opts.timeoutMs ?? 30_000);
		const signal = opts.signal ? AbortSignal.any([opts.signal, budget]) : budget;

		let res: Response;
		try {
			res = await fetch(url, { method, headers, body: payload, signal, mode: "cors" });
		} catch (err) {
			if (budget.aborted) throw new ApiError("timeout", "request timed out");
			if (opts.signal?.aborted) throw new ApiError("network", "cancelled");
			throw new ApiError("network", err instanceof Error ? err.message : String(err));
		}

		if (opts.raw) {
			if (!res.ok) throw ApiError.fromStatus(res.status, [], retryAfterOf(res));
			return res as unknown as T;
		}

		// Success with nothing in it, which the API says three different ways.
		//
		// 304 is the one that bites: polling `/messages` with `since_id` answers
		// 304 when nothing is new, and a client that treats non-2xx as failure
		// will retry a perfectly good "no news" three times and then show an
		// error. It means exactly what 204 means here.
		if (res.status === 204 || res.status === 304) return undefined as T;

		const text = await res.text();
		const parsed = text ? safeJson(text) : undefined;
		const env = (parsed ?? {}) as Envelope<T>;

		const meta = env.meta;
		const errors = meta?.errors ?? [];

		// Classification comes from the status line, detail from `meta.code`.
		//
		// Getting this backwards is tempting and wrong: the `450xx` family
		// (assistant not permitted) arrives on a 403, and reading `meta.code`
		// as the status turns a clean "forbidden" into a meaningless 45018.
		//
		// The reverse case is real too, just rarer — a few routes answer 200
		// with a failing `meta.code` — so when the status looks fine we fall
		// back to the leading three digits of the meta code.
		if (!res.ok) {
			throw ApiError.fromStatus(res.status, errors, retryAfterOf(res), meta?.code);
		}
		const metaStatus = meta?.code !== undefined ? Math.floor(meta.code / 100) : 0;
		if (meta?.code !== undefined && metaStatus >= 400 && metaStatus <= 599) {
			throw ApiError.fromStatus(metaStatus, errors, retryAfterOf(res), meta.code);
		}

		// Not every host uses the envelope. v1 and v4 routes, and all the CDN
		// assets, hand back a bare object. Unwrap when there is something to
		// unwrap and pass the body through otherwise.
		if (env.response !== undefined) return env.response;
		if (meta !== undefined) return undefined as T; // enveloped, genuinely empty (204, DELETEs)
		return (parsed ?? undefined) as T;
	}

	async #waitOutThrottle(signal?: AbortSignal): Promise<void> {
		const left = this.#throttledUntil - Date.now();
		if (left > 0) await sleep(left, signal);
	}
}

/** Writes are not idempotent unless the caller has made them so. */
function defaultRetries(method: string): number {
	return method === "GET" ? 3 : 1;
}

/**
 * Exponential backoff with full jitter.
 *
 * The jitter matters more than the exponent here. A dropped connection tends
 * to fail every request at once, and without jitter they all come back at the
 * same instant and fail together again.
 */
function backoffMs(attempt: number, err: ApiError): number {
	if (err.kind === "rateLimited" && err.retryAfter) return err.retryAfter * 1000;
	const ceiling = Math.min(500 * 2 ** attempt, 8_000);
	return Math.random() * ceiling + 150;
}

function retryAfterOf(res: Response): number | null {
	const raw = res.headers.get("retry-after");
	if (!raw) return null;
	const secs = Number(raw);
	return Number.isFinite(secs) ? secs : null;
}

function buildUrl(path: string, opts: RequestOptions): string {
	const host = opts.host ?? HOSTS.api;
	const prefix = opts.host ? "" : `/${opts.version ?? "v3"}`;
	const url = new URL(`${prefix}${path}`, host);
	for (const [k, v] of Object.entries(opts.query ?? {})) {
		if (v === undefined || v === null) continue;
		if (Array.isArray(v)) for (const item of v) url.searchParams.append(k, item);
		else url.searchParams.set(k, String(v));
	}
	return url.toString();
}

function safeJson(text: string): unknown {
	try {
		return JSON.parse(text);
	} catch {
		return undefined;
	}
}

export function sleep(ms: number, signal?: AbortSignal): Promise<void> {
	return new Promise((resolve, reject) => {
		if (signal?.aborted) return reject(new ApiError("network", "cancelled"));
		const t = setTimeout(done, ms);
		const onAbort = () => {
			clearTimeout(t);
			reject(new ApiError("network", "cancelled"));
		};
		signal?.addEventListener("abort", onAbort, { once: true });
		function done() {
			signal?.removeEventListener("abort", onAbort);
			resolve();
		}
	});
}
