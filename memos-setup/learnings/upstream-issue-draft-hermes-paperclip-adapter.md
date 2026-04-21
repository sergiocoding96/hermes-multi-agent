# Draft: upstream issue for `hermes-paperclip-adapter`

**Target:** whichever repo publishes `hermes-paperclip-adapter` to npm (as of 2026-04-21 it's shipped bundled with `paperclipai >= 2026.416.0`; the npm package name is `hermes-paperclip-adapter`).

**Status:** drafted 2026-04-21 after PR #8 (`f81f467`). Not yet filed. Review and edit before posting.

---

## Title

`execute.js` reads wake context from `ctx.config` instead of `ctx.context` — every wake renders `{{#noTask}}` branch

## Body

### Summary

In `dist/server/execute.js`, the `buildPrompt()` function reads wake context fields from `ctx.config?.*`. Paperclip's heartbeat service places wake context on `ctx.context` (the `contextSnapshot`), not on `ctx.config` (which is the resolved `runtimeConfig`: workspace + skills + env). As a result, every wake — including `wakeReason: "issue_assigned"` — renders the `{{#noTask}}` conditional branch of the prompt template. The assigned Hermes agent never sees its task.

### Reproduction

1. Deploy `paperclipai` in `deploymentMode: "authenticated"`.
2. Create a `hermes_local` employee (any profile).
3. Assign an issue to the employee:
   ```
   POST /api/companies/{id}/issues
   { "title": "Test", "assigneeAgentId": "<employee-id>", "status": "todo" }
   ```
4. Wait for wake. Inspect the rendered prompt via `/api/heartbeat-runs/:runId` or the raw run log.
5. Observed: prompt renders the `{{#noTask}}` "heartbeat, check the queue" branch.
6. Expected: prompt renders the `{{#taskId}}` "Assigned Task" branch with the issue title/body.

### Root cause

`dist/server/execute.js` lines ~100-107 and ~333:

```js
const taskId = cfgString(ctx.config?.taskId);
const taskTitle = cfgString(ctx.config?.taskTitle) || "";
const taskBody = cfgString(ctx.config?.taskBody) || "";
const commentId = cfgString(ctx.config?.commentId) || "";
const wakeReason = cfgString(ctx.config?.wakeReason) || "";
const companyName = cfgString(ctx.config?.companyName) || "";
const projectName = cfgString(ctx.config?.projectName) || "";
```

Paperclip's heartbeat service (`@paperclipai/server/dist/services/heartbeat.js`, lines 3151-3169 in the version shipped with `paperclipai@2026.416.0`) calls:

```js
adapter.execute({ runId, agent, runtime, config: runtimeConfig, context, ... })
```

where `runtimeConfig` contains no wake-context fields; those live on `context` (specifically `context.taskId`, `context.issueId`, `context.paperclipWake.issue.{id,title,body}`, `context.wakeReason`, etc.).

### Comparison with `@paperclipai/adapter-claude-local`

The sibling `claude-local` adapter correctly reads from `context.*`. See `@paperclipai/adapter-claude-local/dist/server/execute.js:66-84`:

```js
const wakeTaskId = (typeof context.taskId === "string" && context.taskId.trim().length > 0 && context.taskId.trim())
    || (typeof context.issueId === "string" && context.issueId.trim().length > 0 && context.issueId.trim());
...
const wakePayloadJson = stringifyPaperclipWakePayload(context.paperclipWake);
```

Only `hermes-paperclip-adapter` has this bug.

### Suggested fix

Change each `ctx.config?.<field>` read in `buildPrompt()` to `ctx.context?.<field>`, with fallbacks to `ctx.context?.paperclipWake?.issue?.{id,title,body}` so the template populates even if the flat `context.taskId` fields aren't set:

```diff
- const taskId = cfgString(ctx.config?.taskId);
- const taskTitle = cfgString(ctx.config?.taskTitle) || "";
- const taskBody = cfgString(ctx.config?.taskBody) || "";
- const commentId = cfgString(ctx.config?.commentId) || "";
- const wakeReason = cfgString(ctx.config?.wakeReason) || "";
- const companyName = cfgString(ctx.config?.companyName) || "";
- const projectName = cfgString(ctx.config?.projectName) || "";
+ const taskId = cfgString(ctx.context?.taskId)
+     || cfgString(ctx.context?.issueId)
+     || cfgString(ctx.context?.paperclipWake?.issue?.id);
+ const taskTitle = cfgString(ctx.context?.taskTitle)
+     || cfgString(ctx.context?.paperclipWake?.issue?.title) || "";
+ const taskBody = cfgString(ctx.context?.taskBody)
+     || cfgString(ctx.context?.paperclipWake?.issue?.body) || "";
+ const commentId = cfgString(ctx.context?.commentId)
+     || cfgString(ctx.context?.wakeCommentId) || "";
+ const wakeReason = cfgString(ctx.context?.wakeReason) || "";
+ const companyName = cfgString(ctx.context?.companyName) || "";
+ const projectName = cfgString(ctx.context?.projectName) || "";
```

Same treatment at the second site around line 333.

### Impact

Without this fix, `hermes_local` delegation is effectively broken in authenticated Paperclip deployments: agents wake, render the wrong branch, and either answer with a "heartbeat" message or thrash trying to fetch the queue via an API they can't authenticate to. Turn/time budgets are consumed without progress on the assigned task.

### Workaround (what we're currently running)

We carry a local patch via [`patch-hermes-adapter.sh`](https://github.com/sergiocoding96/hermes-multi-agent/blob/main/scripts/paperclip/v2/patch-hermes-adapter.sh) that rewrites the 8 read sites in place. The script auto-discovers every copy of `execute.js` under the npm global prefix (important because `paperclipai` ships its own bundled copy). Idempotent via a sentinel comment; fails safely with timestamped backups and `node --check` verification.

### Environment

- `paperclipai` 2026.416.0
- `hermes-paperclip-adapter` (version bundled with above — please confirm and pin)
- Node 18-24
- Paperclip `deploymentMode: "authenticated"`
