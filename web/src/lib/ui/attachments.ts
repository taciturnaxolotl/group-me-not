import type { GroupMeAPI } from "../api/groupme";
import type { ConversationID } from "../model/conversation-id";

/**
 * Staging attachments for a message that has not been sent yet.
 *
 * Uploads happen when a file is picked, not when the message is sent. That is
 * the opposite of what the iOS client does, and the reason is that a browser
 * tab is a worse place to be holding bytes: there is no background transfer,
 * so a send that has to upload forty megabytes first is a send that appears to
 * hang, and a tab closed mid-upload loses the lot with nothing to show for it.
 *
 * Uploading on pick means the progress is visible while somebody is still
 * typing the caption, and pressing Enter is instant because all that is left
 * is a URL.
 *
 * The cost is orphaned uploads when a staged file is never sent. GroupMe's
 * media service does not charge for that and has no delete route, so it is a
 * cost worth paying.
 */

export type StagedState = "uploading" | "ready" | "failed";

export interface Staged {
	id: string;
	file: File;
	kind: "image" | "video" | "file";
	/** Object URL for the local preview. Revoked on removal. */
	previewUrl: string;
	state: StagedState;
	/** Set once the upload lands. This is what gets sent. */
	remoteUrl: string | null;
	/** Poster frame for a video, when the service returns one. */
	posterUrl: string | null;
	error: string | null;
	width: number | null;
	height: number | null;
}

/** 50 MB, which is roughly where GroupMe starts refusing things. */
const MAX_BYTES = 50 * 1024 * 1024;

export function classify(file: File): Staged["kind"] {
	if (file.type.startsWith("image/")) return "image";
	if (file.type.startsWith("video/")) return "video";
	return "file";
}

export function stage(file: File): Staged {
	return {
		id: crypto.randomUUID(),
		file,
		kind: classify(file),
		previewUrl: URL.createObjectURL(file),
		state: "uploading",
		remoteUrl: null,
		posterUrl: null,
		error: null,
		width: null,
		height: null,
	};
}

export function release(item: Staged): void {
	URL.revokeObjectURL(item.previewUrl);
}

/**
 * Push one staged file to GroupMe and return the updated record.
 *
 * Images go up as raw bytes to the picture service. Both raw and multipart
 * work — measured, both answer 200 with a usable URL — and raw is one fewer
 * layer to get wrong.
 */
export async function upload(
	api: GroupMeAPI,
	conversation: ConversationID,
	item: Staged,
): Promise<Staged> {
	if (item.file.size > MAX_BYTES) {
		return { ...item, state: "failed", error: "Too large to send" };
	}

	try {
		if (item.kind === "image") {
			const [url, size] = await Promise.all([
				api.uploadImage(item.file),
				measureImage(item.previewUrl),
			]);
			return { ...item, state: "ready", remoteUrl: url, width: size?.width ?? null, height: size?.height ?? null };
		}

		if (item.kind === "video") {
			const res = await api.uploadVideo(conversation, item.file);
			return { ...item, state: "ready", remoteUrl: res.url, posterUrl: res.posterUrl };
		}

		// Arbitrary files need the document service, which is a three-step
		// upload against a different host. Not wired up yet, and saying so
		// beats a chip that sits at "uploading" forever.
		return { ...item, state: "failed", error: "Only photos and video for now" };
	} catch (err) {
		return { ...item, state: "failed", error: err instanceof Error ? err.message : "Upload failed" };
	}
}

/** The wire attachments for everything that uploaded cleanly. */
export function toAttachments(items: Staged[]): unknown[] {
	const out: unknown[] = [];
	for (const item of items) {
		if (item.state !== "ready" || !item.remoteUrl) continue;
		if (item.kind === "video") {
			out.push({ type: "video", url: item.remoteUrl, preview_url: item.posterUrl ?? undefined });
		} else {
			out.push({ type: "image", url: item.remoteUrl });
		}
	}
	return out;
}

/**
 * Read an image's real pixel size from the local copy.
 *
 * Worth doing before it leaves: it lets the transcript reserve the right box
 * the instant the message appears, rather than waiting to parse the size back
 * out of the URL the CDN returns.
 */
function measureImage(objectUrl: string): Promise<{ width: number; height: number } | null> {
	return new Promise((resolve) => {
		const img = new Image();
		img.onload = () => resolve({ width: img.naturalWidth, height: img.naturalHeight });
		img.onerror = () => resolve(null);
		img.src = objectUrl;
	});
}
