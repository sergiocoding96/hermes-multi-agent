# Initiation Prompt

Paste this into every new Claude Code Desktop session that's opened in a worktree directory.

It works verbatim for every worktree — the `TASK.md` in the directory provides the per-task spec.

---

```
Before starting, run `git status`. Confirm you are on the worktree's expected branch
(e.g. fix/auth-perf, feat/memos-provisioning, etc.) — NOT a claude/* scratch branch.

If git shows you on a claude/* branch, run this first:
    git branch --show-current           # note the current branch
    git checkout <expected-branch>      # e.g. git checkout feat/memos-provisioning

The expected branch matches the worktree directory name (e.g. the worktree
~/Coding/MemOS-wt/fix-auth-perf is on branch fix/auth-perf). Do NOT create
or commit to any claude/* scratch branch — all work must live on the worktree's
intended branch so the PR targets the right remote.

Then read TASK.md in this directory — that is your full brief.

Execute the work it specifies, with these rules:

1. Commit as you go in logical chunks with descriptive messages.
2. When all acceptance criteria pass, push the branch:
       git push -u origin <current-branch>
3. Open a PR:
       gh pr create --title "<from TASK.md>" --body "<summary + test results>"
4. Do NOT merge — leave that to me on GitHub.
5. If you get stuck or hit an ambiguity not covered by TASK.md, stop and ask
   before making a judgment call.

Before you start real work, confirm in your reply:
- Which branch you're on (after the checkout if needed)
- The acceptance criteria from TASK.md
- Your plan to satisfy them

Then proceed.
```

---

## Why each rule exists

- **Branch discipline** — Claude Code Desktop auto-creates `claude/*` scratch branches per session. Left unchecked, commits land off the worktree's intended branch and the PR targets the wrong base.
- **Commit-as-you-go** — if the session runs out of context or you need to reattach later, progress is preserved.
- **No merges from the session** — humans review PRs. Merge authority stays with you.
- **Confirm plan first** — catches misreads of TASK.md before code is written.

## When to update this prompt

If multiple sessions trip over the same thing (e.g. all forget to push before opening a PR), add a rule here and reuse the updated prompt for future sessions.
