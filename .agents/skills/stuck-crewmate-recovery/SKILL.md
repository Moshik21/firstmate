---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead, reports a live endpoint as unfit, or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.
Also use it when the digest reports a live endpoint as `fitness: unfit`.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Alive but unable to work

A live endpoint does not prove the worker can still act.
After a session-provider restart, a pane can come back with full conversation context, no error, and a live endpoint, yet have lost the autonomy flag it was launched with and be sitting outside its task worktree.
Such a worker stalls forever on its first tool call, waiting for an approval nobody is watching for.
`bin/fm-crew-fitness.sh <id>` is the owner of that verdict, and the session-start digest runs it for every live endpoint.
`bin/fm-crew-fitness.sh --all` sweeps this home when a restart is suspected mid-session.

Repair an `unfit` worker in this order.

1. Exit the agent with its adapter's exit command from `harness-adapters`.
   The pane must fall back to its shell first, because the repair refuses to relaunch over a live agent.
2. Run `bin/fm-crew-relaunch.sh <id>`, which replays the exact launch command recorded at spawn time in the task's own worktree.
   Do not hand-assemble the relaunch: the recorded command already carries the resolved autonomy flag, model, effort, env prefixes, and encoded brief.
3. Confirm with `bin/fm-crew-fitness.sh <id>` that the pane reads `fit` again.

A refusal from that script is a stop-and-investigate result.
It refuses when an agent still owns the task, when the recorded worktree is gone or is no longer its own checkout, and when no launch command was recorded, and it never allocates a replacement worktree.
It also refuses when the recorded endpoint is gone entirely rather than merely idle, because there is then no pane to relaunch into: that case is a respawn, which the dead-direct-report procedure below owns, and it refuses before writing anything so a refusal never leaves a half-applied repair behind.
`unknown` is not `unfit`: it means the check could not establish an answer, so inspect the pane before acting rather than relaunching on it.
Interrupting the harness cannot restore autonomy that was never granted at launch, so never try to fix an `unfit` pane with a keystroke; `harness-adapters` owns why.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for treehouse-backed tmux, herdr, zellij, or cmux tasks, and use the recorded `orca_worktree_id=` and `terminal=` for Orca tasks.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.
Preserve its uncommitted changes and commits, keep the same task identity, and resume or relaunch the recorded harness in that existing worktree with the same brief plus a concise progress note.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Escape`.
4. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Use `bin/fm-crew-relaunch.sh <id> --note '<progress so far>'` for that relaunch whenever the task recorded a `launch=` command: it replays the resolved launch in the recorded worktree and appends the note itself, so nothing has to be reassembled by hand.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.
