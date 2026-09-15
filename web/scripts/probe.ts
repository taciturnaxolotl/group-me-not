/**
 * Scratch probe for poking the live API during development.
 *
 *   bun scripts/probe.ts groups
 *   bun scripts/probe.ts get /v3/groups/123/messages limit=5
 *
 * Reads the token from GMN_TOKEN. Not shipped, not imported by the app.
 */
const token = process.env.GMN_TOKEN;
if (!token) {
	console.error("set GMN_TOKEN");
	process.exit(1);
}

async function api(path: string, query: Record<string, string> = {}, init: RequestInit = {}) {
	const url = new URL(path, "https://api.groupme.com");
	for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
	const res = await fetch(url, {
		...init,
		headers: {
			"x-access-token": token!,
			accept: "application/json",
			"x-requested-with": "GroupMeWeb/1.2.3",
			...(init.body ? { "content-type": "application/json" } : {}),
			...(init.headers as Record<string, string>),
		},
	});
	const text = await res.text();
	let body: unknown;
	try {
		body = JSON.parse(text);
	} catch {
		body = text;
	}
	return { status: res.status, headers: Object.fromEntries(res.headers), body };
}

const [cmd, ...rest] = process.argv.slice(2);

if (cmd === "get" || cmd === "post" || cmd === "delete" || cmd === "put") {
	const path = rest[0]!;
	const query: Record<string, string> = {};
	let body: unknown;
	for (const arg of rest.slice(1)) {
		if (arg.startsWith("{")) body = JSON.parse(arg);
		else {
			const i = arg.indexOf("=");
			query[arg.slice(0, i)] = arg.slice(i + 1);
		}
	}
	const out = await api(path, query, {
		method: cmd.toUpperCase(),
		...(body ? { body: JSON.stringify(body) } : {}),
	});
	console.log(JSON.stringify(out, null, 2));
} else {
	console.error("usage: probe.ts <get|post|put|delete> <path> [k=v ...] ['{json body}']");
	process.exit(1);
}
