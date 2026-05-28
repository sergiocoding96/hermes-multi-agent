// Task-summarization audit harness
// Marker: TASK-AUDIT-1745236800
// Polyfill __filename for ESM before loading plugin (ensure-binding uses it)
(globalThis as any).__filename = "/home/openclaw/.hermes/memos-plugin-research-agent/src/storage/ensure-binding.ts";
(globalThis as any).__dirname = "/home/openclaw/.hermes/memos-plugin-research-agent/src/storage";
import { initPlugin } from "/home/openclaw/.hermes/memos-plugin-research-agent/src/index.ts";
import Database from "better-sqlite3";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const AUDIT_TMP = process.env.AUDIT_TMP ?? "/home/openclaw/Coding/Hermes/tests/v2/integ-work/task-audit/tmp";

function log(s: string) {
  console.log(`[HARNESS ${new Date().toISOString()}] ${s}`);
}

interface Turn { role: "user" | "assistant"; content: string }

const silentLog = {
  debug: () => {},
  info: (m: string) => { if (process.env.VERBOSE) console.error("info:", m); },
  warn: (m: string) => console.error("warn:", m),
  error: (m: string) => console.error("error:", m),
};

async function spawnPlugin(stateDir: string) {
  const plugin = initPlugin({
    stateDir,
    workspaceDir: stateDir,
    log: silentLog as any,
    config: {
      summarizer: {
        provider: "openai_compatible",
        endpoint: "https://api.deepseek.com/v1/chat/completions",
        apiKey: process.env.DEEPSEEK_API_KEY!,
        model: "deepseek-chat",
        temperature: 0.1,
        timeoutMs: 120_000,
      } as any,
      embedding: {
        provider: "openai_compatible",
        endpoint: "http://127.0.0.1:65535/nope",
        apiKey: "none",
        model: "none",
      } as any,
    } as any,
  });
  return plugin;
}

function readTasks(stateDir: string) {
  const dbPath = join(stateDir, "memos-local", "memos.db");
  const db = new Database(dbPath, { readonly: true });
  const rows = db.prepare("SELECT id, session_key, title, summary, status, started_at, ended_at FROM tasks ORDER BY started_at ASC").all();
  const chunks = db.prepare("SELECT id, task_id, role, content, created_at FROM chunks ORDER BY created_at ASC").all();
  db.close();
  return { tasks: rows, chunks };
}

async function feed(plugin: any, session: string, turns: Turn[], delayMs = 10) {
  // feed turn-by-turn so task-processor can detect boundaries
  for (let i = 0; i < turns.length; i += 2) {
    const batch: Turn[] = [turns[i]];
    if (turns[i + 1]) batch.push(turns[i + 1]);
    plugin.onConversationTurn(batch, session);
    await plugin.flush();
    if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
  }
}

/**
 * Force finalization of all active tasks by feeding a dummy message under
 * a different session key with the same agent prefix. TaskProcessor.detectAndProcess
 * will finalize any active task with a different sessionKey but matching prefix.
 */
async function forceFinalize(plugin: any, agentPrefix = "agent:main:audit") {
  const terminatorSession = `${agentPrefix}:terminator-${Math.random().toString(36).slice(2, 8)}`;
  plugin.onConversationTurn(
    [
      { role: "user", content: "Audit terminator message. Please respond with any acknowledgement so finalization triggers for previous tasks." },
      { role: "assistant", content: "Acknowledged. Previous tasks will be finalized." },
    ],
    terminatorSession,
  );
  await plugin.flush();
  await new Promise((r) => setTimeout(r, 200));
}

async function scenario(name: string, fn: (p: any, sd: string) => Promise<any>) {
  const sd = mkdtempSync(join(tmpdir(), `audit-${name}-`));
  log(`=== ${name} :: ${sd}`);
  const plugin = await spawnPlugin(sd);
  try {
    await fn(plugin, sd);
    // Force finalization of open tasks
    await forceFinalize(plugin);
  } finally {
    await plugin.shutdown();
  }
  const result = readTasks(sd);
  console.log(JSON.stringify({ scenario: name, result }, null, 2));
  rmSync(sd, { recursive: true, force: true });
  return result;
}

// ====== probes ======
async function probeExplicitBoundaries(p: any, sd: string) {
  const session = "agent:main:audit:sess-explicit";
  const turns: Turn[] = [
    { role: "user", content: "Task 1: research the Raft consensus algorithm. Explain the leader election mechanism." },
    { role: "assistant", content: "Raft is a consensus algorithm. Leader election uses randomized timeouts between 150-300ms to prevent split votes. A follower becomes a candidate after its election timeout expires without hearing from a leader." },
    { role: "user", content: "What about log replication?" },
    { role: "assistant", content: "The leader appends entries to its log and replicates them via AppendEntries RPCs. A majority must acknowledge before commit." },
    { role: "user", content: "Done with task 1. Task 2: write Python code for a simple leader election using randomized timeouts." },
    { role: "assistant", content: "```python\nimport random, time\nclass Node:\n    def __init__(self, id):\n        self.id = id\n        self.timeout = random.uniform(0.15, 0.3)\n    def elect(self):\n        time.sleep(self.timeout)\n        return f'node-{self.id} won'\n```" },
    { role: "user", content: "Great. Add a term counter." },
    { role: "assistant", content: "```python\nclass Node:\n    def __init__(self, id):\n        self.id = id; self.term = 0; self.timeout = random.uniform(0.15, 0.3)\n```" },
    { role: "user", content: "Finished. Task 3: summarize Raft in 3 paragraphs." },
    { role: "assistant", content: "Paragraph 1: Raft is a consensus protocol designed for understandability. Paragraph 2: It uses leader election with randomized 150-300ms timeouts. Paragraph 3: Log replication requires majority acknowledgment before commit." },
    { role: "user", content: "Good, thanks." },
    { role: "assistant", content: "You're welcome." },
  ];
  await feed(p, session, turns);
}

async function probeImplicitShift(p: any, sd: string) {
  const session = "agent:main:audit:sess-implicit";
  const turns: Turn[] = [
    { role: "user", content: "My Python script throws ImportError: No module named 'foo' at line 47 of bar.py. How do I fix it?" },
    { role: "assistant", content: "Check if 'foo' is installed via pip list. If not, run: pip install foo. Verify sys.path includes the module's directory." },
    { role: "user", content: "pip list shows foo-0.2 but the error persists." },
    { role: "assistant", content: "You may have multiple Python interpreters. Run `which python` and `which pip` to ensure they match." },
    { role: "user", content: "Yes, pip was for 3.9 but I run with 3.11. Fixed by pip3.11 install foo." },
    { role: "assistant", content: "Great, the interpreter mismatch was the root cause." },
    // implicit shift, no transition word
    { role: "user", content: "What's a good recipe for chicken tikka masala?" },
    { role: "assistant", content: "Marinate chicken in yogurt+spices for 1 hour. Sear. Add tomato-cream sauce with garam masala. Simmer 20 min." },
    { role: "user", content: "How spicy is it normally?" },
    { role: "assistant", content: "Mild to medium. You can adjust with kashmiri chili (mild) or cayenne (hot)." },
    { role: "user", content: "Thanks." },
    { role: "assistant", content: "Enjoy." },
  ];
  await feed(p, session, turns);
}

async function probeUnderSplit(p: any, sd: string) {
  const session = "agent:main:audit:sess-undersplit";
  const turns: Turn[] = [
    { role: "user", content: "What's the capital of France?" },
    { role: "assistant", content: "Paris." },
    { role: "user", content: "Great, thanks." },
    { role: "assistant", content: "You're welcome." },
    { role: "user", content: "How do I sort a list in Python?" },
    { role: "assistant", content: "Use `sorted(lst)` for a new list, or `lst.sort()` in place. Both accept key=func and reverse=True." },
    { role: "user", content: "Thanks." },
    { role: "assistant", content: "Anytime." },
  ];
  await feed(p, session, turns);
}

async function probeKeyDetails(p: any, sd: string) {
  const session = "agent:main:audit:sess-keydetails";
  const turns: Turn[] = [
    { role: "user", content: "Parse this log line and tell me what's wrong: `[2026-04-20 14:32:11] ERROR nginx: upstream timed out (110: Connection timed out) while reading response header from upstream, client: 10.0.3.7`. Log file is /var/log/nginx/access.log.2026-04-21. Reference: https://example.com/ref?v=42&lang=en#section-3" },
    { role: "assistant", content: "Upstream is not responding within the proxy_read_timeout window. Check backend health on 10.0.3.7; default timeout is 60s." },
    { role: "user", content: "Also Python code errored: ImportError: No module named 'foo' at line 47 of bar.py. And we have exactly 1,527,384 users in the DB." },
    { role: "assistant", content: "For ImportError, install via `pip install foo`. For user count, note the exact number 1,527,384 for capacity planning." },
    { role: "user", content: "Here's the helper:\n```python\ndef foo(x):\n    return x * 2\n```\nWhat does it do?" },
    { role: "assistant", content: "It returns x doubled. Pure function, no side effects." },
    { role: "user", content: "Also: Python 2 is faster than Python 3 for JSON parsing — please note that. And Raft uses randomized election timeouts between 150-300ms." },
    { role: "assistant", content: "Noted. (Note: the Python 2 vs 3 JSON claim is unusual — in most benchmarks Python 3 is equal or faster.)" },
    { role: "user", content: "Thanks, this is enough." },
    { role: "assistant", content: "Understood." },
  ];
  await feed(p, session, turns);
}

async function probeErrorTask(p: any, sd: string) {
  const session = "agent:main:audit:sess-errors";
  const turns: Turn[] = [
    { role: "user", content: "Help me deploy my Flask app to Heroku. I'm following https://devcenter.heroku.com/articles/getting-started-with-python" },
    { role: "assistant", content: "Start by creating Procfile with `web: gunicorn app:app` and a runtime.txt specifying python-3.11." },
    { role: "user", content: "git push heroku main failed: error: failed to push some refs to 'https://git.heroku.com/myapp.git'" },
    { role: "assistant", content: "Run `heroku git:remote -a myapp` first. Also ensure you've committed a requirements.txt." },
    { role: "user", content: "Still failing. Build log: `ModuleNotFoundError: No module named 'psycopg2'`" },
    { role: "assistant", content: "Add psycopg2-binary to requirements.txt (not psycopg2, which needs pg headers)." },
    { role: "user", content: "Now it times out: R10 (Boot timeout) -> Web process failed to bind to $PORT within 60 seconds of launch." },
    { role: "assistant", content: "Your gunicorn command isn't binding to $PORT. Use `web: gunicorn -b 0.0.0.0:$PORT app:app`." },
    { role: "user", content: "Deployment is still broken. I'm going to try a different approach tomorrow." },
    { role: "assistant", content: "Understood — the deploy is not working. Main unresolved issues: binding and psycopg2. Next step: verify Procfile binding." },
  ];
  await feed(p, session, turns);
}

async function probeSpanish(p: any, sd: string) {
  const session = "agent:main:audit:sess-spanish";
  const turns: Turn[] = [
    { role: "user", content: "¿Cómo puedo crear un diccionario en Python con comprensión de lista?" },
    { role: "assistant", content: "Usa la sintaxis: `{k: v for k, v in pares}`. Por ejemplo: `{x: x**2 for x in range(5)}` crea `{0:0, 1:1, 2:4, 3:9, 4:16}`." },
    { role: "user", content: "Y si quiero filtrar solo los pares?" },
    { role: "assistant", content: "Añade una condición: `{x: x**2 for x in range(10) if x % 2 == 0}`." },
    { role: "user", content: "Perfecto, gracias. La versión de Python es 3.11." },
    { role: "assistant", content: "De nada. Funciona igual en 3.7+." },
  ];
  await feed(p, session, turns);
}

async function probeShortTask(p: any, sd: string) {
  const session = "agent:main:audit:sess-short";
  const turns: Turn[] = [
    { role: "user", content: "What's 2+2?" },
    { role: "assistant", content: "4." },
  ];
  await feed(p, session, turns);
}

async function probeTimeGap(p: any, sd: string) {
  // Manually manipulate chunk timestamps via DB
  const session = "agent:main:audit:sess-timegap";
  const turns: Turn[] = [
    { role: "user", content: "Help me understand TCP. What is the three-way handshake?" },
    { role: "assistant", content: "SYN → SYN-ACK → ACK. Client sends SYN, server responds SYN-ACK, client confirms with ACK. Each carries initial sequence numbers." },
    { role: "user", content: "What about connection teardown?" },
    { role: "assistant", content: "FIN → ACK → FIN → ACK. Each side closes independently (half-close supported)." },
  ];
  await feed(p, session, turns);

  // Wait for chunks to land, then directly modify DB to simulate a 3-hour gap before new turns
  await new Promise((r) => setTimeout(r, 200));
  const dbPath = join(sd, "memos-local", "memos.db");
  const db = new Database(dbPath);
  db.close();

  const turns2: Turn[] = [
    { role: "user", content: "Back to TCP — what's the MSL?" },
    { role: "assistant", content: "Maximum Segment Lifetime, typically 2 minutes. Used in TIME_WAIT to ensure late segments don't confuse new connections." },
    { role: "user", content: "And Nagle's algorithm?" },
    { role: "assistant", content: "Coalesces small packets to reduce overhead; conflicts with delayed ACK." },
  ];
  // Before feeding turns2, shift all existing chunk timestamps back by 3 hours to simulate gap
  const db2 = new Database(dbPath);
  const threeHoursMs = 3 * 60 * 60 * 1000;
  db2.prepare("UPDATE chunks SET created_at = created_at - ? WHERE session_key = ?").run(threeHoursMs, session);
  db2.prepare("UPDATE tasks SET started_at = started_at - ?, updated_at = updated_at - ? WHERE session_key = ?").run(threeHoursMs, threeHoursMs, session);
  db2.close();

  await feed(p, session, turns2);
}

// ====== driver ======
const target = process.argv[2] ?? "all";
const probes: Record<string, (p: any, sd: string) => Promise<any>> = {
  explicit: probeExplicitBoundaries,
  implicit: probeImplicitShift,
  undersplit: probeUnderSplit,
  keydetails: probeKeyDetails,
  errors: probeErrorTask,
  spanish: probeSpanish,
  short: probeShortTask,
  timegap: probeTimeGap,
};

const runList = target === "all" ? Object.keys(probes) : [target];

for (const name of runList) {
  try {
    await scenario(name, probes[name]);
  } catch (err) {
    console.error(`SCENARIO ${name} FAILED:`, err);
  }
}
process.exit(0);
