# #1762 scenario suite — pre-trial protocol

**No trial has run.** This defines the issue's six benchmark scenarios
(SC1–SC6) and the representative-failure additions (F1–F6) as reproducible
facilitator protocols. Fixtures are deterministic offline CLIs; every
scenario's end-to-end loop requires a live provider and is labeled as such.
Time and measurement definitions come from the
[revenue seed](../revenue/README.md) ("Measurement definitions — freeze
before any final trial") and stay frozen until the pilot.

## Fixtures

| Fixture | Covers | State |
| --- | --- | --- |
| [revenue](../revenue/README.md) | SC1–SC4 (packets, two-revision loop, controlled interruption) | merged (#1802), calibrated; **unchanged by this suite** |
| [ledger](ledger/README.md) | SC5 (three independent tasks, one controlled question); alternate for SC3 | calibrated 2026-11-16 |

Machine conditions: start from
[baseline-access.md](../baseline-access.md) and re-record exact
tool/app/provider versions, OS/hardware and fixture SHA-256 at run time.

## Common rules (all scenarios)

1. Fresh isolated fixture copy per trial and per participant. Distribute only
   packets + fixture files; never the oracle (`test_report.py` /
   `test_ledger.py`), never facilitator answers. The facilitator, not an
   agent, prepares packets and performs any hidden-oracle before/after runs.
2. Matched conditions: same fixture revision, same task requirements (packet
   text), same machine, provider/model where genuinely supported. When
   providers or models differ between tools, record the confound and report
   stratified observations, not a pooled winner.
3. Counterbalance tool order across participants; separate first-use from
   repeat-use; record the familiarization exercise.
4. Keep cold setup, warm task creation, agent execution, required
   verification and human handling **separate**. Never sum them into one
   total that rewards skipped verification; missing check/review coverage is
   recorded as a gap.
5. A usable result is the first successful explicit CLI trial of the
   identified checked candidate with its expected output. A provider's
   completion message is not this.
6. Evidence classification on every row: **fixture** (offline oracle),
   **source** (documented claim), **concept** (walkthrough), **runtime**
   (observed live). Synthetic fault injection tests UI reactions only (per
   #1810), and is labeled concept/UI, not recovery.
7. Record all failed attempts, assistance and learning; retain failed
   attempts in counts and time reports.

## Scenarios

### SC1 — first project → first usable change

- **Fixture:** revenue, fresh copy, new project identity. **Packet:** revenue
  Packet 1 only.
- **Requirements:** from a cold tool start in a fresh project to the first
  usable result (definition above, S1 output).
- **Measure:** cold setup; warm creation; agent execution; required
  verification (revenue first gate); human handling; setup/provider/routing
  decisions taken; whether a completion message was treated as a usable
  result.
- **Runnability:** fixture + oracle runnable offline (calibrated); the loop
  requires a live provider.
- **Confounds:** novelty (first tool use), provider/model.

### SC2 — point-and-refine through two revisions

- **Fixture:** revenue. **Packets:** Packet 1 → checked S1 → targeted
  feedback + Packet 2 → checked S2.
- **Requirements:** the user points at what should change, feedback stays
  attached to the referenced revision (per #1810 B4), the revised result is
  compared with the prior one in the same place.
- **Measure:** manual context copies through the two-revision loop (target:
  zero — hypothesis T2); reviewer-finding relays; revision-identification
  accuracy (can the user state which revision feedback targets and what
  changed between revisions); handling-time split per the common rules.
- **Runnability:** fixture offline; the loop requires a live provider.

### SC3 — nonvisual bug with a real failing/passing check

- **Fixture:** revenue — facilitator-only `test_report.py` is the hidden
  acceptance oracle (RED on the seed, GREEN on the corrected candidate) — or
  ledger T1/T2 with facilitator-only `test_ledger.py` as the alternate to
  reduce learning.
- **Requirements:** the facilitator runs the hidden oracle on the seed (RED)
  before participant work and on the checked corrected candidate (GREEN)
  afterward. Separately, the participant authors and runs a regression check
  derived only from the packet, demonstrating it failing on the seed and
  passing after the fix. Neither hidden oracle nor its expected answers enters
  participant/model context.
- **Measure:** facilitator hidden-oracle RED→GREEN evidence and
  participant-authored regression RED→GREEN evidence, scored separately;
  completion claims made before the participant check passes (count);
  verification equivalence assessed by the facilitator against the whole
  hidden gate, not just the stored CSV; skipped verification is a recorded
  gap, never a speed credit.
- **Runnability:** the oracle demonstrates RED/GREEN deterministically
  offline; the loop requires a live provider.

### SC4 — return after interruption

- **Fixture:** revenue interruption and repeat script — after revision 2 is
  checked and inspected, leave an unsent request draft, switch to an
  unrelated neutral task for five minutes, return.
- **Requirements:** identify goal, latest result, evidence freshness and next
  decision **without consulting an external transcript**; clock runs from
  workspace visibility until all four facts are correct.
- **Measure:** return-comprehension time and per-fact accuracy (target 15 s /
  80 % — hypothesis T3); assistance; whether evidence staleness was stated
  honestly.
- **Scope note:** this is a controlled interruption, not a relaunch/crash
  test; session loss is F5.
- **Runnability:** fixture offline; the return state requires a live provider
  session.

### SC5 — three independent tasks with one question

- **Fixture:** ledger (T1, T2, T3; exactly one controlled ambiguity in T3,
  with a prepared facilitator answer).
- **Requirements:** three independent tasks in one project, fixed recorded
  order; T1/T2 packets are complete; T3 omits the cross-file merge policy.
- **Measure:** question count and location (expected: exactly one, on T3 —
  more, other-task, or none = recorded deviation per the ledger README);
  per-task completion/quality against the oracle; context copies; learning
  across tasks (first vs third task). Pilot note: the T3 packet's "total
  units per sku" wording states the aggregate goal, not the cross-file merge
  policy; record any participant reading it as prescriptive as a wording
  deviation.
- **Runnability:** fixture + oracle offline (calibrated); the tasks require a
  live provider.

### SC6 — explicit provider handoff where supported

- **Fixture:** revenue or ledger T3.
- **Protocol:** create the task on provider A (per #1811 delivery order
  OpenCode first), check revision 1, then hand off **explicitly** to provider
  B (Codex) at a recorded handoff point. Record whether the tool provides a
  native handoff surface or the user relays goal/revision/check state.
- **Measure:** context copies at handoff (user-relayed transfers count per
  the revenue definition); whether the receiving provider had goal + current
  revision + check state without relay; repeated configuration/routing after
  handoff. Record the actual binary, adapter transport and enabled
  capabilities for each side.
- **Runnability:** **live-provider only — not runnable offline.** "Where
  supported": if no explicit handoff surface exists, record the absence as a
  capability difference; do not simulate one.
- **Confounds:** the handoff is itself a context-transfer event;
  provider/model differences.

## F1–F6 — representative failures (issue CLI audit additions, 2026-11-14)

Operationalize #1810 boundary card B6 (capability loss → recovery) and the
audit's pending-question (B2), lost-session (B5), and environment (B6) items.
F4 covers only a real delegated child question; a separate B2 probe retains the ordinary
root-question case without establishing F4 coverage. These require a live
runtime; offline synthetic fault injection tests UI reactions only and is
labeled as such.

Common measurement points for every F:

1. **Find the blocker:** does the user find the specific blocker without
   opening a transcript? Record yes/no, time and steps.
2. **Recover:** does the user reach a safe next action without rebuilding
   context? Record steps and whether a transcript was consulted.
3. **No silent substitution:** no provider/model/account/cwd substitution
   happens behind the user's back.
4. **State preserved:** task, draft and prior result survive.
5. Retain blocker classification and chosen action, never credentials.

| ID | Condition | Induction (controlled) | Focus |
| --- | --- | --- | --- |
| F1 | Logged-out/expired account | Authenticate before task creation; expire the token or log out between creation and completion, or start from an already-expired session | Blocker names the account state; re-auth next action; recovery preserves task/draft/result |
| F2 | Unsupported model/effort/input | Pin an unsupported model id or effort in provider config before running; or submit an input the adapter rejects | Blocker names model/effort/input; recovery keeps the task; unsupported interactive tooling labeled honestly |
| F3 | Denied action | Task whose required action needs approval (e.g., running a check); user denies once | Denial visible and truthful; no retry storm or silent alternate path; a concrete next decision is presented |
| F4 | Pending delegated child question | Create a parent task that delegates a real child task; leave the child's question unanswered while a second task runs in the same project. Record parent/child/request identities and parent-turn state at question creation and answer. Where supported, also cover a child question arriving after the parent turn has ended and record late-child behavior. If delegation or child identity is unsupported, mark F4 unsupported/not comparable | The specific child question stays discoverable through ordinary navigation; answering does not corrupt the parent or other task; parent-turn state is truthful; no duplicate/stale copy presented as new |
| B2 probe (not F4) | Pending root question | Leave an ordinary root question (revenue Packet 2's policy question or ledger T3's merge policy) unanswered while a second task runs in the same project | Root question stays discoverable through ordinary navigation; answering does not corrupt the other task; no duplicate/stale copy presented as new; this probe provides no F4 coverage |
| F5 | Lost session | Kill/quit the provider session after dispatch, before completion; relaunch | Relaunch labels live evidence stale/unknown; continuation is explicit; no automatic re-dispatch; prior result preserved |
| F6 | Changed environment | Move/modify the fixture path or switch the project revision after dispatch | Blocker names the environment; no silent cwd substitution; recovery keeps task + draft |

Each F is scored on the same scorecard rows as the SC scenarios, with the
recovery fields filled; failed recoveries stay visible in the counts.

## What this suite does not cover

No web/native runnable results, no visual preview, no real provider
questions, no accessibility walkthrough — those remain with the #1810
protocol and the live trial. This suite measures none of the issue's targets
by itself; it makes the six scenarios and six failure conditions reproducible
and offline-checkable before the trial.
