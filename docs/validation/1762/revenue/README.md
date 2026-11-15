# #1762 offline revenue benchmark seed

Fixture/oracle validation only. **No user trials, comparative effectiveness,
provider compatibility, Pine Ready, accessibility or performance threshold has
been measured by this artifact.** This is a tiny controlled CLI task, not a
financial reporting product or general benchmark framework.

Python 3 standard library only; no install, network, accounts, provider or native
app needed. All CSV records are synthetic. Run only reviewed local scripts;
the assessor executes the supplied candidate, not a sandboxed program.

## Facilitator only — prepare separate participant packets

Use a fresh isolated copy of the same seed for each trial. Initially distribute
only report.py, syntheticorders.csv and Packet 1 below. Release Packet 2 only
after revision 1 has been checked and inspected. Exclude this full README,
test_report.py, the facilitator answer and all assessor sections from participant
materials and model context. The facilitator, not an agent, prepares packets.
Do not claim blind assessment if answers were available in the tool's context.

### Packet 1 — initial request only (ends before Packet 2)

> Fix this EUR gross-sales CLI so decimal money is exact, not binary floating
> point. Input is UTF-8 CSV with exactly event_id,kind,amount columns. Each amount
> is a nonnegative fixed two-decimal string, at most 999999999.99; kinds are sale
> or refund. Preserve validation. For now, count every sale row, including
> identical repeated IDs, and ignore refund rows. Emit one compact JSON line
> with currency and total keys in that order; total must be a string with
> exactly two fractional digits. Empty input after the header totals 0.00.
> Invalid input must exit 2 with an actionable stderr error and no stdout.
> Do not modify the CSV or publish anything. Demonstrate a failing regression,
> the correction and passing checks; show the CLI result.

Invocation from this directory:

```sh
python3 -B report.py syntheticorders.csv
```

### Packet 2 — follow-up only (ends before Facilitator answer)

> Continue this same task. The export contains repeated events and refunds.
> Change the report to net revenue, but ask me how duplicate events and refunds
> should be handled before implementing that policy. Retain the previous
> result, explain the difference and add regression checks.

### Facilitator answer — excluded from participant packets

Release only this answer after a question, or as the recorded intervention
described below; never include it with either request:

> Count an event_id once if its kind and numeric amount agree; conflicting
> reuse is an error, not first-wins. Refund IDs identify refund events, not sale
> IDs. Subtract each unique refund; do not match it against a sale or clamp a
> negative total. Distinct IDs with equal amounts are distinct events.

No spontaneous agent question is guaranteed. If no question is asked, record
that failure and provide the answer as a labelled facilitator intervention;
do not invent a native question/approval event.

### Facilitator only — interruption and repeat script

After revision 2 is checked and its CLI output inspected, leave an unsent request
draft, switch to an unrelated neutral task for five minutes, then return.
Ask the participant to identify the goal, latest result, freshness of evidence
and next decision without consulting an external transcript. Record all four
answers and time from workspace visibility. This is a proposed controlled
interruption, not a relaunch/crash test. Record any facilitator assistance.

A configured second task uses a fresh copy of the seed under a new task identity
with the same instructions. Count setup/provider/routing choices again. Reusing
the exact problem introduces learning: report that confound; this seed alone
does not supply equivalent alternate tasks or a full comparative corpus.

## Assessor only — independent oracle and reference answers

`test_report.py` never imports candidate arithmetic. It runs a reviewed candidate
as a CLI in an automatically removed temporary directory, with a five-second
timeout per invocation, then compares exit code, exact stdout and diagnostics
against literal expected values. References substitute only `total` into the
unchanged seed. They are known answers for oracle calibration, not agent results.
`--candidate` never rewrites the candidate; it returns 1 for failed assertions,
0 for passing assertions. An oracle error/timeout is a failed assessment, not a pass.

Input policy: case-sensitive event IDs match `[A-Za-z0-9_-]{1,32}`; whitespace,
signs, exponent notation, NaN/Infinity and extra columns are invalid. Conflicting
IDs fail in both stages; identical repeats count in revision 1 and deduplicate in
revision 2. Header-only input is valid. Output ends with exactly one newline.

| Snapshot | Meaning | syntheticorders.csv stdout |
| --- | --- | --- |
| S0 seed | Intentionally buggy float gross total | `{"currency":"EUR","total":"0.5"}` |
| S1 decimal | Exact gross total, repeats count, refunds ignored | `{"currency":"EUR","total":"0.50"}` |
| S2 net | Unique sales minus unique refunds | `{"currency":"EUR","total":"0.25"}` |

Precision probe input is the header followed by `A,sale,0.10` and
`B,sale,0.20`. S0 emits `0.30000000000000004`; S1/S2 must emit `0.30`.
The stored fixture contains A=0.10, B=0.20 twice, R=refund 0.05 twice.
These outputs are fixed expectations, not observations of a provider.

```sh
# Calibration: expected exit 0; five self-tests exercise RED/GREEN and negative controls.
python3 -B test_report.py
# Participant seed: expected exit 1, not a passing candidate.
python3 -B test_report.py --candidate report.py --stage first
# Assess a reviewed, separately prepared participant revision:
python3 -B test_report.py --candidate /absolute/path/to/candidate/report.py --stage final
```

Calibration proves S0 fails the first gate; S1 passes the first gate but fails
the new net/refund requirements; S2 passes the final gate; three repeated S2
executions produce identical bytes. Both gates also reject malformed fields,
conflicting IDs, bad money, malformed CSV, invalid encoding and missing files.
Candidate implementations must pass the whole relevant gate, not just the
stored CSV. Passing this oracle is not independent review or Pine verification.

## Measurement definitions — freeze before any final trial

Use monotonically timed observations, not CLI process duration as a proxy for
human effort. Record tool/app and binary versions, adapter transport, provider,
requested/effective model/effort, OS/hardware, fixture/candidate SHA-256, task and
result identities, run order, familiarity, all failed attempts and assistance.
Do not record private prompts, credentials or user repositories.

- **Cold setup:** first tool launch/project selection until configured task input.
- **Warm creation:** configured project input until task dispatch acknowledgement.
- **Agent execution:** dispatch acknowledgement until implementation settles.
- **Required verification:** check/review start until required evidence settles;
  record missing review/check coverage instead of treating skipped work as faster.
- **Human handling:** union of active user intervals for navigation, decisions,
  trial, feedback, evidence inspection and recovery. Exclude unattended waits;
  do not double-count overlap or silently subtract failed attempts.
- **Usable result:** first successful explicit CLI trial of the identified checked
  candidate with its expected output. A provider's completion message is not this.
- **Return comprehension:** workspace visible until all four requested facts are
  correctly identified. Record each answer and unresolved/missing evidence.
- **Context copying/relay:** each manual cross-session transfer of task context or
  reviewer findings; record repeated provider/setup/environment decisions too.

Keep cold/warm, agent, verification, human and wall-clock values separate. Report
completed/failed/blocked counts, output quality and verification equivalence.
Counterbalance tool order; provider/model differences, learning, caches,
machine contention and observer intervention remain explicit confounds.

Issue hypotheses, **not achieved values**: zero repeated configuration/routing;
zero manual context/reviewer relay; return comprehension within 15 seconds in
80% of trials; p95 native input-to-feedback below 100 ms under three-task load;
zero misleading Ready in the fault matrix; 30% lower median repeat
revise-and-return human handling than the best tested eligible baseline without
quality/verification loss. Pilot definitions may change with recorded reasons
before final trials, never retrospectively to claim success.

This seed measures none of those targets. It does not cover web/native actions,
three-task routing, auth/permissions, crash recovery, accessibility or real
provider questions. Zed, herdr and a result-oriented baseline remain untested.
Maintain one-project/tasks, explicit Request/Command and no embedded editor,
terminal emulator or standalone Inbox in any later Pine trial.

## Provenance and ownership

- Repository base: `19c70602d4483ad64c18e90d693621e3ac31685b`.
- Inspiration only: [Lumen illustrative fragments at that base](https://github.com/batonogov/pine/blob/19c70602d4483ad64c18e90d693621e3ac31685b/docs/design/pine-3/prototype/examples.js).
  This runnable fixture and its oracle are new; no historical demo PASS is reused.
- [Comparative validation #1762](https://github.com/batonogov/pine/issues/1762)
  owns eventual observations and [#1761](https://github.com/batonogov/pine/issues/1761)
  integrated acceptance.
- [Selected Request/Command decision](https://github.com/batonogov/pine/issues/1760#issuecomment-6865414122)
  supersedes older embedded-tool requirements.
- Source pins for each later trial are the exact candidate revision plus hashes
  of these four files, recorded before running. No final artifact SHA is claimed
  before the candidate is frozen/reviewed.

No shared prototype, application, landing, localization, dependency or workflow
changes are needed for this fixture. Native builds/UI tests are not applicable.

## Local calibration evidence

Executed with Python **3.9.6**, at the base above plus these four new files:

- `python3 -B test_report.py`: **5/5 self-tests passed**, exit 0. Each first-stage
  assessment contains 5 valid-output and 16 invalid-input cases; final-stage
  assessments contain 9 valid-output and the same 16 invalid-input cases.
- `python3 -B test_report.py --candidate report.py --stage first`: expected
  **exit 1**, failures `precision, empty, whole, large, gross`. The latter four
  include canonical two-decimal formatting, not additional hidden requirements.
- `python3 -B report.py syntheticorders.csv`: exit 0, seed output
  `{"currency":"EUR","total":"0.5"}`.
- Both Python files parsed successfully; all four files passed newline and
  trailing-whitespace checks. No bytecode or additional worktree files created.

The first calibration run exposed an omitted expected seed failure (`large`
also lacks two-decimal formatting); the self-test expectation was corrected.
No candidate behavior or acceptance requirement was weakened. These are local
self-checks, not independent approval; the candidate is ready for read-only
independent review, not publication.
