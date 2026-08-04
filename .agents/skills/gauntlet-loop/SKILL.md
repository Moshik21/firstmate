---
name: gauntlet-loop
description: >-
  Agent-only procedure for running the Gauntlet Loop quality method.
  Load before starting owner-facing, design-craft, or claim-making work, including detector claims and proof that depends on target box hardware, and whenever the captain invokes a gauntlet.
  It owns the inspectable quality bar, independent builder and critic loop, live workbench, stopping conditions, and composition with no-mistakes.
user-invocable: false
metadata:
  internal: true
---

# gauntlet-loop

Use this skill to drive inspectable output toward a real quality bar through repeated building and independent criticism.
This procedure adapts Matt Shumer's [Gauntlet Loop](https://somethingbig.ai/gauntlet-loop/), adopted by the captain as a core development method on 2026-08-04.
It is the single owner of Firstmate's Gauntlet Loop procedure.

## Preserve authority and settled law

Start from the accepted product goal, not an implementation recipe.
Treat the captain's settled laws and the task's accepted constraints as fixed boundaries for both builder and critic.
Never use a gauntlet to reopen offline-only operation, no streaming, a films-only corpus, truthfulness, no red merges, or any other settled captain law.
A critic suggestion that requires violating settled law is not an option and must be replaced by criticism against the lawful bar.
If the goal cannot meet its bar inside those boundaries, report that incompatibility instead of negotiating against the boundary through repeated criticism.
The loop does not expand merge, destructive-action, irreversible-action, security-sensitive, or ask-user authority.

## Decide whether to run the loop

Prefer the loop when the outcome will be directly judged by an owner or user, when design craft materially affects success, or when the work makes a detector or product claim that must survive inspection.
Prefer it when proof depends on the real target box or other hardware rather than a proxy environment.
Examples include interfaces, demos, visual or interaction design, generated media, owner-facing reports, detector quality, comparative product claims, latency claims, and target-hardware evidence.
Default the loop off for pure plumbing whose complete contract is exercised by green tests and that has no owner-facing surface or qualitative claim.
Do not add the loop merely to make routine infrastructure work sound more rigorous.
When applicability is uncertain, identify whether a reasonable critic could inspect a real artifact against a stronger bar than the existing executable contract.
Use the loop only when the answer is yes.

## Frame the gauntlet

State one outcome goal in terms of what the finished artifact must accomplish for its owner.
Do not prescribe architecture, file changes, or a sequence of implementation steps unless an accepted constraint requires one.
Define the bar with evidence the critic can inspect, such as approved references, target screenshots, executable behavior, benchmark thresholds, latency budgets, best-in-class comparisons, factual claim evidence, recordings from the target box, or tests on the real artifact.
Replace vague standards such as "make it amazing" with observable comparisons or thresholds.
Record which references are authoritative, which are directional, and which claims require direct proof.
Set a spend cap before the first build wave using the captain's cap when one exists or an explicit proportionate operational cap otherwise.
Express the cap in a form that can actually stop work, such as token spend, monetary spend, or elapsed agent effort, without turning it into a planned fixed round count.
The only loop exits are a pass against the bar, a captain stop, or the spend cap.

## Establish the live workbench

Have the lead publish a live progress page or workbench before the first artifact is judged.
Use a project preview, artifact index, task-owned report, or another durable surface that the captain can inspect without interrupting the work.
Keep the workbench current with the goal, fixed constraints, quality bar, judgeable pieces, links or captures plus a stable identity for the latest real artifacts, the current largest gap, resolved gaps, spend against cap, and the active stop condition.
Update the workbench as part of each build and critic handoff rather than asking the captain for routine progress checks.
The workbench reports evidence and progress, but it does not create approval authority or substitute for a required captain decision.

## Split and build

Have the lead split the goal into the smallest pieces that can be built and judged independently against a meaningful part of the bar.
A piece is too large when a critic could fail unrelated qualities in one verdict.
A piece is too small when passing it says nothing useful about the owner-visible outcome.
Keep cross-piece constraints visible in the workbench so local optimization does not silently break the whole.
Give the builder the goal, bar, fixed constraints, current piece, current largest gap when one exists, and the artifact location.
Do not turn critic observations into a mandatory implementation recipe.
The builder owns how to close the gap and updates the real artifact plus workbench evidence.

## Run an independent critic wave

Use a separate spawn with a fresh context for every critic judgment.
Never let the builder continue in its own pane as the critic, and never let a self-review count as a gauntlet verdict.
Treat the critic as a bounded knowledge-only scout attached to the accepted task, not as a second delivery owner or a replacement for the selected delivery path.
Give the critic the goal, fixed constraints, inspectable bar, relevant piece or whole-artifact scope, and direct access to the latest real artifact.
Withhold the builder's rationale and implementation narrative unless either is itself part of the artifact being judged.
Require inspection of the artifact rather than acceptance of screenshots, summaries, or claimed test results when the real surface is safely available.
For visual, interaction, latency, detector, and hardware-dependent claims, judge the surface and environment on which the claim depends.
Use blind A/B comparison when feasible by anonymizing candidates, randomizing their order, and asking for the bar-based verdict before revealing identity.
The critic returns only a pass or one largest remaining gap, supported by concrete evidence and the relevant bar criterion.
The critic may inspect broadly to identify that gap, but it must not send the builder a backlog of lesser preferences.
A pass means the judged scope meets the declared bar without relying on the builder's explanation.

## Loop on the largest gap

Route the critic's single largest gap back to the builder as the next outcome to improve.
Preserve the goal, bar, and fixed constraints while leaving the implementation choice to the builder.
After the builder updates the artifact and workbench, commission another fresh critic context against the new real artifact.
Do not set a fixed number of rounds and do not stop because an arbitrary iteration count has elapsed.
Continue until the current scope passes, the captain stops the loop, or the spend cap is reached.
When the cap is reached without a pass, stop and report the strongest current artifact, the unmet bar criterion, the evidence for the largest remaining gap, and the consequence of shipping as-is.
Do not relabel a capped result as a pass.

## Reconcile the whole artifact

After independently judged pieces pass, optionally run an end-of-wave smoothing pass when their combination can create visible seams, inconsistent language, uneven interaction, conflicting timings, or other coherence defects.
Give the builder a coherence goal and the complete artifact rather than a list of implementation edits.
Follow smoothing with a fresh independent critic judgment of the whole artifact.
Do not use smoothing to reopen settled constraints or to replace the critic.
The gauntlet passes only when the relevant piece-level bars and the required whole-artifact bar pass.

## Compose with delivery and no-mistakes

Run the gauntlet inside the accepted task and selected delivery path.
The gauntlet adds a quality critic loop for inspectable output, but it does not replace executable tests, CI, code review, documentation checks, or no-mistakes.
Complete builder changes and the gauntlet verdict before starting no-mistakes validation so the quality loop does not compete with pipeline ownership of the branch.
Do not run the critic as a parallel code reviewer while no-mistakes owns validation.
The critic judges the owner-visible artifact and declared claims, while no-mistakes retains ownership of delivery review and verification.
A gauntlet pass cannot authorize a red merge, and green tests cannot substitute for a failed owner-visible bar when the gauntlet applies.

## When not to use it

Do not use the loop for pure plumbing with a complete green executable contract and no owner-facing surface.
Do not use it to seek a different answer to a settled captain decision.
Do not use it when no real artifact or honest proxy can be inspected, and first establish an inspectable proof surface instead.
Do not use it as open-ended polish without a declared bar and spend cap.
Do not use the builder's confidence, prose explanation, or self-score as the critic verdict.
Do not use it to duplicate no-mistakes review or bypass the project's delivery and approval rules.

## Appendix: task-specific meta-prompt

Use this short meta-prompt to produce the builder and critic instructions for one gauntlet.

```text
Turn the accepted task below into a Gauntlet Loop packet.
Write an outcome-focused builder prompt and a separate fresh-context critic prompt.
Preserve every settled law and accepted constraint without proposing alternatives to them.
Define an inspectable bar from the supplied references, tests, comparisons, thresholds, and real artifact surface.
Split the goal into the smallest independently judgeable pieces.
Specify the live workbench fields and artifact links the lead must maintain.
Make the critic inspect the real artifact, use blind A/B when feasible, and return only pass or the single largest remaining evidence-backed gap.
Route gaps as outcomes rather than implementation recipes.
State the spend cap and stop only on pass, captain stop, or that cap.
Include an optional final coherence pass when independently improved pieces can create seams.
Keep no-mistakes, tests, CI, review, merge authority, and settled captain law unchanged.

Accepted task: {task}
Settled laws and constraints: {constraints}
Inspectable references and bar evidence: {bar_evidence}
Real artifact and target environment: {artifact}
Spend cap: {cap}
```
