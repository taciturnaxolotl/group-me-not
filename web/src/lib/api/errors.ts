/**
 * Errors from the GroupMe API, in the shapes a caller actually branches on.
 *
 * The server answers every route with an envelope:
 *
 *     { "meta": { "code": 401, "errors": ["unauthorized"] }, "response": null }
 *
 * and the HTTP status usually agrees with `meta.code`, but not always — a few
 * routes return 200 with a failing meta code. Everything here reads `meta`
 * first and falls back to the status, so callers never have to know which
 * routes lie.
 */

export type ApiErrorKind =
	| "network" // never left the machine, or the connection died mid-flight
	| "timeout"
	| "unauthorized" // 401: token is dead, sign the user out
	| "forbidden" // 403: token is fine, this account may not do this
	| "notFound"
	| "conflict" // 409: see the note in `send`, this often means success
	| "rateLimited" // 429
	| "server" // 5xx
	| "decode" // we got JSON but not the JSON we expected
	| "client"; // anything else in 4xx

export class ApiError extends Error {
	readonly kind: ApiErrorKind;
	readonly status: number;
	/** Seconds the server asked us to wait, when it bothered to say. */
	readonly retryAfter: number | null;
	readonly serverErrors: string[];
	/**
	 * The server's specific reason code, when it sent one.
	 *
	 * Usually mirrors the status. Sometimes it is far more specific: the
	 * `450xx` family rides in on a plain 403 and is the only way to tell
	 * "you are not in this group" from "this group forbids assistants".
	 */
	readonly code: number | null;

	constructor(
		kind: ApiErrorKind,
		message: string,
		opts: {
			status?: number;
			retryAfter?: number | null;
			serverErrors?: string[];
			code?: number | null;
		} = {},
	) {
		super(message);
		this.name = "ApiError";
		this.kind = kind;
		this.status = opts.status ?? 0;
		this.retryAfter = opts.retryAfter ?? null;
		this.serverErrors = opts.serverErrors ?? [];
		this.code = opts.code ?? null;
	}

	/**
	 * Whether trying the identical request again could plausibly work.
	 *
	 * Deliberately excludes 409. A conflict on send means the server already
	 * has the message; retrying would be asking for a duplicate.
	 */
	get retryable(): boolean {
		return (
			this.kind === "network" ||
			this.kind === "timeout" ||
			this.kind === "rateLimited" ||
			this.kind === "server"
		);
	}

	/** The token is gone. The only cure is signing in again. */
	get fatal(): boolean {
		return this.kind === "unauthorized";
	}

	static fromStatus(
		status: number,
		errors: string[],
		retryAfter: number | null,
		code: number | null = null,
	): ApiError {
		const detail = errors.length ? errors.join(", ") : `HTTP ${status}`;
		const kind: ApiErrorKind =
			status === 401
				? "unauthorized"
				: status === 403
					? "forbidden"
					: status === 404
						? "notFound"
						: status === 409
							? "conflict"
							: status === 429
								? "rateLimited"
								: status >= 500
									? "server"
									: "client";
		return new ApiError(kind, detail, { status, retryAfter, serverErrors: errors, code });
	}
}
