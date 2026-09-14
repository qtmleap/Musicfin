// Codex as an MCP server for each Claude Code seat in the tmux session.
//
// Each Claude process starts its own copy over stdio, which keeps the seats'
// Codex threads independent without a shared service or client identity. A tool
// call runs one non-interactive `codex exec` turn and waits for its final message;
// `codex exec resume <thread>` continues that seat's conversation on later calls.
//
// Speaks MCP over stdio: one JSON-RPC object per line, stdout carries nothing
// else. Anything worth saying to a human goes to stderr.
//
// One behaviour diverges from upstream deliberately: a codex turn that exits
// nonzero is always an error here, even when it managed to say something first.
// See callCodex.
//
// Environment:
//   CODEX_MODEL           --model for codex          (default: none, codex decides)
//   CODEX_MCP_ARGS        sandbox/approval args      (default: --dangerously-bypass-approvals-and-sandbox)
//   CODEX_MCP_TIMEOUT_MS  kill a turn after this     (default: 600000)
//   CODEX_MCP_MAX_CHARS   truncate the answer at     (default: 20000)
//
// This runs on the macOS host, not in a container: Xcode and the Simulator need
// it. Bypass is still the default because it is a deliberate choice for this
// repository, not because a sandbox makes it safe — override CODEX_MCP_ARGS
// anywhere that choice does not hold. Put only flags `exec`, `exec resume` and
// `exec review` all accept in it: `-s` is not one of them, a first turn takes it
// and the other two do not.

import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

const PROTOCOL_VERSION = "2025-06-18";
const TIMEOUT_MS = Number(process.env.CODEX_MCP_TIMEOUT_MS || 600000);
const MAX_CHARS = Number(process.env.CODEX_MCP_MAX_CHARS || 20000);
const SANDBOX_ARGS = (
	process.env.CODEX_MCP_ARGS ?? "--dangerously-bypass-approvals-and-sandbox"
)
	.split(/\s+/)
	.filter(Boolean);

// codex keeps the conversation on its side; we only have to remember which one.
// Held per server process, which is per Claude Code session, so the two seats
// never land in each other's thread.
let thread = null;

const TOOLS = [
	{
		name: "ask",
		description:
			"Ask codex, a second model with its own view of this repository, for a design review or a second opinion. " +
			"It reads files and runs commands on its own. Follow-up calls continue the same conversation unless new_thread is set.",
		inputSchema: {
			type: "object",
			properties: {
				prompt: {
					type: "string",
					description:
						"The question. Name the files worth reading; codex starts with no context from this conversation.",
				},
				new_thread: {
					type: "boolean",
					description:
						"Start a fresh conversation instead of continuing the last one.",
				},
			},
			required: ["prompt"],
		},
	},
	{
		name: "review",
		description:
			"Have codex review changes in this repository and report what it finds. " +
			"Reviews the working tree by default. Give it either a base branch or your own instructions, not both.",
		inputSchema: {
			type: "object",
			properties: {
				base: {
					type: "string",
					description:
						"Review the changes against this base branch instead of the working tree.",
				},
				instructions: {
					type: "string",
					description:
						"Name the scope yourself and let codex work out what to read. Cannot be combined with base.",
				},
			},
		},
	},
];

// ─── Running codex ─────────────────────────────────────────────────────

function runCodex(args, lastMessageFile) {
	return new Promise((resolve) => {
		// stdin is ignored on purpose: given an open stdin codex waits on it
		// ("Reading additional input from stdin...") and the turn never starts.
		const child = spawn("codex", args, {
			stdio: ["ignore", "pipe", "pipe"],
			cwd: process.cwd(),
		});
		let out = "";
		let err = "";
		let timedOut = false;
		const timer = setTimeout(() => {
			timedOut = true;
			child.kill("SIGKILL");
		}, TIMEOUT_MS);

		child.stdout.on("data", (d) => {
			out += d;
		});
		child.stderr.on("data", (d) => {
			err += d;
		});
		child.on("error", (e) => {
			clearTimeout(timer);
			resolve({ code: -1, out, err: `${err}${e.message}`, timedOut });
		});
		child.on("close", (code) => {
			clearTimeout(timer);
			resolve({
				code,
				out,
				err,
				timedOut,
				text: readLastMessage(lastMessageFile),
			});
		});
	});
}

function readLastMessage(file) {
	try {
		return readFileSync(file, "utf8").trim();
	} catch {
		return "";
	}
}

// The -o file holds the final message and nothing else, which is what we want
// nine times out of ten. When it is empty — codex died mid-turn, say — the
// JSONL still carries whatever the model managed to say, so fall back to that.
function messagesFromEvents(jsonl) {
	const said = [];
	for (const line of jsonl.split("\n")) {
		if (!line.startsWith("{")) continue;
		try {
			const ev = JSON.parse(line);
			if (ev.type === "thread.started" && ev.thread_id) thread = ev.thread_id;
			if (
				ev.type === "item.completed" &&
				ev.item?.type === "agent_message" &&
				ev.item.text
			)
				said.push(ev.item.text);
		} catch {
			// A half-written line at the end of a killed process. Nothing to read.
		}
	}
	return said.join("\n\n");
}

function truncate(text) {
	if (text.length <= MAX_CHARS) return text;
	return `${text.slice(0, MAX_CHARS)}\n\n[truncated at ${MAX_CHARS} characters]`;
}

async function callCodex(subcommand, extra, prompt) {
	const dir = mkdtempSync(join(tmpdir(), "codex-mcp-"));
	const lastMessageFile = join(dir, "last-message.txt");
	const args = ["exec"];
	if (subcommand) args.push(subcommand);
	// Only flags that all three of exec, exec resume and exec review accept go
	// here: resume and review have a narrower option set than a first turn and
	// reject anything outside it, --color and -C among them. The working
	// directory comes from spawn instead.
	args.push("--json", "--skip-git-repo-check", "-o", lastMessageFile);
	if (process.env.CODEX_MODEL) args.push("-m", process.env.CODEX_MODEL);
	args.push(...SANDBOX_ARGS, ...extra);
	if (prompt) args.push(prompt);

	try {
		const r = await runCodex(args, lastMessageFile);
		const fromEvents = messagesFromEvents(r.out);
		const text = r.text || fromEvents;
		if (r.timedOut) {
			return {
				isError: true,
				text: `codex was killed after ${TIMEOUT_MS} ms.${text ? `\n\nIt had said:\n\n${text}` : ""}`,
			};
		}
		// **This is the one behaviour that diverges from upstream on purpose.**
		// Upstream only reports an error when a nonzero exit left no text at all,
		// so a codex that says something and *then* dies — killed, crashed, out of
		// quota mid-answer — comes back as isError:false and its half-finished
		// review reads like a clean pass. A caller acting on that ships unreviewed
		// work. A nonzero exit is an error whatever was said; the partial text is
		// still worth returning, but labelled as what it is.
		if (r.code !== 0) {
			const detail = r.err.trim().slice(-2000);
			return {
				isError: true,
				text: text
					? `codex exited with ${r.code} partway through, so this answer is INCOMPLETE. Do not treat it as codex's result.\n\nWhat it had said before it stopped:\n\n${text}${detail ? `\n\ncodex's error output:\n\n${detail}` : ""}`
					: `codex exited with ${r.code}.\n\n${detail || "(no output)"}`,
			};
		}
		return { isError: false, text: text || "(codex returned no message)" };
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
}

async function ask({ prompt, new_thread }) {
	if (typeof prompt !== "string" || !prompt.trim()) {
		return { isError: true, text: "ask needs a prompt." };
	}
	if (new_thread) thread = null;
	// resume takes the thread id as a positional, so it goes in ahead of the
	// prompt; messagesFromEvents picks up the new id when there is no thread yet.
	return thread
		? callCodex("resume", [thread], prompt)
		: callCodex(null, [], prompt);
}

// codex treats the three ways of naming what to review as alternatives and
// refuses any two together, so the tool has to choose one as well.
async function review({ instructions, base }) {
	if (instructions && base) {
		return {
			isError: true,
			text: "review takes base or instructions, not both: codex refuses the pair.",
		};
	}
	if (instructions) return callCodex("review", [], instructions);
	return callCodex("review", base ? ["--base", base] : ["--uncommitted"], null);
}

// ─── MCP plumbing ──────────────────────────────────────────────────────

function send(message) {
	process.stdout.write(`${JSON.stringify(message)}\n`);
}

function reply(id, result) {
	send({ jsonrpc: "2.0", id, result });
}

function replyError(id, code, message) {
	send({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handle(request) {
	const { id, method, params } = request;

	if (method === "initialize") {
		const asked = params?.protocolVersion;
		reply(id, {
			protocolVersion: typeof asked === "string" ? asked : PROTOCOL_VERSION,
			capabilities: { tools: {} },
			serverInfo: { name: "codex", version: "0.1.0" },
		});
		return;
	}

	if (method === "ping") {
		reply(id, {});
		return;
	}

	if (method === "tools/list") {
		reply(id, { tools: TOOLS });
		return;
	}

	if (method === "tools/call") {
		const name = params?.name;
		const args = params?.arguments ?? {};
		const run = name === "ask" ? ask : name === "review" ? review : null;
		if (!run) {
			replyError(id, -32602, `No tool named "${name}".`);
			return;
		}
		try {
			const r = await run(args);
			reply(id, {
				content: [{ type: "text", text: truncate(r.text) }],
				isError: r.isError,
			});
		} catch (e) {
			reply(id, {
				content: [{ type: "text", text: `codex-mcp failed: ${e.message}` }],
				isError: true,
			});
		}
		return;
	}

	// Notifications carry no id and want no answer; anything else is a method we
	// do not implement, and the client is entitled to hear so.
	if (id !== undefined)
		replyError(id, -32601, `Unsupported method "${method}".`);
}

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
	const text = line.trim();
	if (!text) return;
	let request;
	try {
		request = JSON.parse(text);
	} catch {
		process.stderr.write(`codex-mcp: ignoring a line that is not JSON\n`);
		return;
	}
	handle(request).catch((e) => {
		process.stderr.write(`codex-mcp: ${e.stack || e.message}\n`);
		if (request.id !== undefined) replyError(request.id, -32603, e.message);
	});
});
