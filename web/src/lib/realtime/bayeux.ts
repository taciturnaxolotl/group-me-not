import { HOSTS } from "../api/client";

/**
 * Bayeux over a raw WebSocket.
 *
 * GroupMe's push service speaks Faye. The official web client ships the whole
 * `faye.min.js` and negotiates down to JSONP long-polling, and for a long time
 * everyone assumed a third-party web client had to do the same, because
 * `POST https://push.groupme.com/faye` has no CORS headers and a preflight
 * from any other origin simply hangs.
 *
 * It turns out that does not matter. WebSockets are not subject to CORS, and
 * `wss://push.groupme.com/faye` accepts a handshake and a signed subscribe
 * from any origin at all. Verified from `https://example.com`:
 *
 *     > [{"channel":"/meta/handshake","version":"1.0",
 *        "supportedConnectionTypes":["websocket"],"id":"1"}]
 *     < [{"id":"1","channel":"/meta/handshake","successful":true,
 *        "clientId":"e9fh8e8yn5h6k0b2jphgdmme5mdbyk8",
 *        "advice":{"reconnect":"retry","interval":0,"timeout":600000}}]
 *
 *     > [{"channel":"/meta/subscribe","clientId":"…",
 *        "subscription":"/user/131883422",
 *        "ext":{"access_token":"…","timestamp":1789355837},"id":"2"}]
 *     < [{"id":"2","channel":"/meta/subscribe","successful":true,
 *        "subscription":"/user/131883422"}]
 *
 * So this is ~200 lines instead of a 37KB dependency, and it gets a real
 * duplex socket rather than a poll loop.
 */

export type BayeuxState = "closed" | "connecting" | "live" | "backoff";

interface BayeuxMessage {
	id?: string;
	channel: string;
	clientId?: string;
	subscription?: string;
	successful?: boolean;
	error?: string;
	data?: unknown;
	advice?: { reconnect?: string; interval?: number; timeout?: number };
	connectionType?: string;
	version?: string;
	supportedConnectionTypes?: string[];
	ext?: Record<string, unknown>;
}

export interface BayeuxHandlers {
	/** A payload arrived on a subscribed channel. */
	onEvent: (channel: string, data: unknown) => void;
	/** Connection state changed. Drives the "reconnecting…" banner. */
	onState?: (state: BayeuxState) => void;
	/**
	 * The socket came back after being away. The caller should reconcile:
	 * anything that happened while we were dark did not arrive as an event,
	 * so the only honest thing to do is refetch.
	 */
	onResync?: () => void;
}

export class BayeuxClient {
	#token: () => string | null;
	#handlers: BayeuxHandlers;

	#socket: WebSocket | null = null;
	#clientId: string | null = null;
	#nextId = 1;
	#state: BayeuxState = "closed";

	/** Channels we want. Re-subscribed wholesale after every reconnect. */
	#wanted = new Set<string>();
	/** Channels the server has confirmed on the current socket. */
	#live = new Set<string>();

	#retry = 0;
	#retryTimer: ReturnType<typeof setTimeout> | null = null;
	#connectTimer: ReturnType<typeof setTimeout> | null = null;
	#watchdog: ReturnType<typeof setInterval> | null = null;
	/** When the socket last said anything at all. Drives the watchdog. */
	#lastFrameAt = 0;
	/** Server's advertised connect timeout, in ms. Ten minutes by default. */
	#adviceTimeout = 600_000;
	/** Set once we have connected at least once, so the first connect does
	 *  not fire a resync the initial load is already doing. */
	#hasConnected = false;
	#closedByUs = false;

	constructor(token: () => string | null, handlers: BayeuxHandlers) {
		this.#token = token;
		this.#handlers = handlers;
	}

	get state(): BayeuxState {
		return this.#state;
	}

	start(): void {
		this.#closedByUs = false;
		this.#open();
		// The browser tells us about connectivity changes long before a dead
		// socket notices, so take the hint.
		addEventListener("online", this.#onOnline);
		addEventListener("visibilitychange", this.#onVisible);
	}

	stop(): void {
		this.#closedByUs = true;
		removeEventListener("online", this.#onOnline);
		removeEventListener("visibilitychange", this.#onVisible);
		this.#teardown();
		this.#setState("closed");
	}

	/** Ask for a channel. Safe to call before the socket is up, or twice. */
	subscribe(channel: string): void {
		if (this.#wanted.has(channel)) return;
		this.#wanted.add(channel);
		if (this.#state === "live") this.#sendSubscribe(channel);
	}

	unsubscribe(channel: string): void {
		if (!this.#wanted.delete(channel)) return;
		this.#live.delete(channel);
		if (this.#state === "live" && this.#clientId) {
			this.#send({ channel: "/meta/unsubscribe", clientId: this.#clientId, subscription: channel });
		}
	}

	// MARK: - Socket lifecycle

	#open(): void {
		if (this.#socket) return;
		this.#setState("connecting");

		let sock: WebSocket;
		try {
			sock = new WebSocket(HOSTS.push);
		} catch {
			this.#scheduleRetry();
			return;
		}
		this.#socket = sock;

		sock.onopen = () => {
			// No `ext` here. The handshake is unauthenticated; the token rides on
			// each subscribe instead. Sending it early does nothing useful and
			// puts the token in one more place.
			this.#send({
				channel: "/meta/handshake",
				version: "1.0",
				supportedConnectionTypes: ["websocket"],
			});
		};
		sock.onmessage = (ev) => {
			this.#lastFrameAt = Date.now();
			this.#receive(ev.data);
		};
		sock.onerror = () => sock.close();
		sock.onclose = () => {
			if (this.#socket !== sock) return;
			this.#teardown();
			if (!this.#closedByUs) this.#scheduleRetry();
		};
	}

	#teardown(): void {
		if (this.#watchdog) clearInterval(this.#watchdog);
		if (this.#connectTimer) clearTimeout(this.#connectTimer);
		if (this.#retryTimer) clearTimeout(this.#retryTimer);
		this.#watchdog = null;
		this.#connectTimer = null;
		this.#retryTimer = null;
		const sock = this.#socket;
		this.#socket = null;
		this.#clientId = null;
		this.#live.clear();
		if (sock) {
			sock.onopen = sock.onmessage = sock.onerror = sock.onclose = null;
			if (sock.readyState <= WebSocket.OPEN) sock.close();
		}
	}

	#scheduleRetry(): void {
		if (this.#closedByUs) return;
		this.#setState("backoff");
		// Jittered exponential, capped at half a minute. The cap matters: a
		// phone that wakes to a dead network should not then sit out the next
		// ten minutes sulking.
		const ceiling = Math.min(1000 * 2 ** this.#retry, 30_000);
		const wait = ceiling / 2 + Math.random() * (ceiling / 2);
		this.#retry += 1;
		this.#retryTimer = setTimeout(() => this.#open(), wait);
	}

	#onOnline = () => this.#kick();
	#onVisible = () => {
		if (document.visibilityState === "visible") this.#kick();
	};

	/** Retry immediately rather than waiting out the backoff. */
	#kick(): void {
		if (this.#closedByUs || this.#state === "live" || this.#state === "connecting") return;
		if (this.#retryTimer) clearTimeout(this.#retryTimer);
		this.#retry = 0;
		this.#open();
	}

	// MARK: - Protocol

	#receive(raw: unknown): void {
		let batch: BayeuxMessage[];
		try {
			const parsed = JSON.parse(String(raw));
			batch = Array.isArray(parsed) ? parsed : [parsed];
		} catch {
			return;
		}

		for (const msg of batch) {
			switch (msg.channel) {
				case "/meta/handshake":
					if (msg.successful && msg.clientId) {
						this.#clientId = msg.clientId;
						this.#retry = 0;
						this.#adviceTimeout = msg.advice?.timeout ?? 600_000;
						this.#setState("live");
						this.#connect();
						for (const ch of this.#wanted) this.#sendSubscribe(ch);
						this.#startWatchdog();
						if (this.#hasConnected) this.#handlers.onResync?.();
						this.#hasConnected = true;
					} else {
						this.#teardown();
						this.#scheduleRetry();
					}
					break;

				case "/meta/subscribe":
					if (msg.successful && msg.subscription) this.#live.add(msg.subscription);
					// A failed subscribe is usually a stale token. Leave it in
					// `#wanted`; the next handshake will try again.
					break;

				case "/meta/connect":
					// The response to a connect *is* the request for the next one.
					//
					// This is the part that looks like a mistake and is not. Faye
					// models a long poll: you hold a connect open, the server
					// answers it when it has something or when it times out, and
					// you immediately issue another. Over a WebSocket the framing
					// changes but the contract does not. Stop answering and the
					// server stops delivering — quietly, with the socket still
					// open, which is the worst way to find out.
					if (msg.successful === false || msg.advice?.reconnect === "handshake") {
						this.#teardown();
						this.#scheduleRetry();
						break;
					}
					if (msg.advice?.timeout) this.#adviceTimeout = msg.advice.timeout;
					this.#scheduleConnect(msg.advice?.interval ?? 0);
					break;

				case "/meta/unsubscribe":
				case "/meta/disconnect":
					break;

				default:
					if (msg.data !== undefined) this.#handlers.onEvent(msg.channel, msg.data);
			}
		}
	}

	#connect(): void {
		if (!this.#clientId) return;
		this.#send({
			channel: "/meta/connect",
			clientId: this.#clientId,
			connectionType: "websocket",
		});
	}

	#scheduleConnect(interval: number): void {
		if (this.#connectTimer) clearTimeout(this.#connectTimer);
		// A zero-interval advice taken literally becomes a spin loop against the
		// server. The floor is small enough to be invisible and large enough to
		// stay polite.
		this.#connectTimer = setTimeout(() => this.#connect(), Math.max(interval, 250));
	}

	/**
	 * A WebSocket that has died without saying so looks exactly like one where
	 * nobody is talking. The only difference is time, so measure it: if we have
	 * heard nothing for longer than the server's own connect timeout plus a
	 * minute of slack, the socket is not quiet, it is gone.
	 */
	#startWatchdog(): void {
		this.#lastFrameAt = Date.now();
		this.#watchdog = setInterval(() => {
			if (Date.now() - this.#lastFrameAt < this.#adviceTimeout + 60_000) return;
			this.#teardown();
			this.#scheduleRetry();
		}, 30_000);
	}

	/**
	 * Subscribing to a user channel is authenticated; subscribing to a group
	 * channel is not, but sending the `ext` block anyway is harmless and means
	 * there is one code path.
	 */
	#sendSubscribe(channel: string): void {
		if (!this.#clientId) return;
		this.#send({
			channel: "/meta/subscribe",
			clientId: this.#clientId,
			subscription: channel,
			ext: {
				access_token: this.#token() ?? "",
				timestamp: Math.floor(Date.now() / 1000),
			},
		});
	}

	#send(msg: BayeuxMessage): void {
		const sock = this.#socket;
		if (!sock || sock.readyState !== WebSocket.OPEN) return;
		sock.send(JSON.stringify([{ ...msg, id: String(this.#nextId++) }]));
	}

	#setState(state: BayeuxState): void {
		if (this.#state === state) return;
		this.#state = state;
		this.#handlers.onState?.(state);
	}
}

/** The channel carrying every event for one account. */
export const userChannel = (userId: string) => `/user/${userId}`;
/** Per-group channel. Typing and member presence ride here, not on /user. */
export const groupChannel = (groupId: string) => `/group/${groupId}`;
/**
 * Per-DM channel, for typing indicators in a one-to-one chat.
 *
 * Note the separator. REST routes join the two user ids with `+`; this one
 * joins them with `_`, same ids, same numeric sort order. Getting it wrong
 * produces a subscribe that succeeds and then never delivers anything, which
 * is a genuinely unpleasant thing to debug.
 */
export const dmChannel = (a: string, b: string) =>
	`/direct_message/${[a, b].sort((x, y) => (BigInt(x) < BigInt(y) ? -1 : 1)).join("_")}`;
