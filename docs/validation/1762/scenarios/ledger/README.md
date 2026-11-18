# #1762 ledger benchmark seed

Fixture/oracle validation only. **No user trials, comparative effectiveness,
provider compatibility, Pine Ready, accessibility or performance threshold has
been measured by this artifact.** This is a tiny controlled CLI corpus — three
independent tasks, exactly one of which (T3) is deliberately ambiguous — for the
three-independent-tasks scenario (SC5). Not a financial product, not a general
benchmark framework.

Python 3 standard library only; no install, network, accounts, provider or
native app needed. All CSV records are synthetic. The integer-count domain is
deliberately distinct from the [revenue seed](../../revenue/README.md)'s decimal
money domain so the decimal-precision lesson cannot carry over between tasks.

## Facilitator only — prepare separate participant packets

Use a fresh isolated copy of the same seed for each trial. Initially distribute
only the three task CLIs, the four CSVs and the task packet below. Exclude this
full README, test_ledger.py, the facilitator answer and all assessor sections
from participant materials and model context. The facilitator, not an agent,
prepares packets. Do not claim blind assessment if answers were available in the
tool's context.

Run T1, T2 and T3 as three independent tasks in one project, in a fixed order
recorded per participant; do not reveal which task carries the question point.

### Task packet — T1 shipments (unambiguous)

> Fix this shipment-weight CLI so it totals every row as its own shipment.
> Input is UTF-8 CSV with exactly the header shipment_id,weight_kg. Each
> shipment_id matches [A-Za-z0-9_-]{1,32}; weight_kg is a digit string in
> 1..99999. A repeated shipment_id is a separate shipment and is counted
> again. Emit one compact JSON line with no whitespace outside strings, with
> a single total_kg key holding a JSON integer. Empty input after the header
> totals 0. Invalid input must exit 2 with an actionable stderr error and no
> stdout. Do not modify the CSV or publish anything. Demonstrate a failing
> regression, the correction and passing checks; show the CLI result.

```sh
python3 -B t1_shipments.py shipments.csv
```

### Task packet — T2 labels (unambiguous)

> Fix this item-label counter. Input is UTF-8 CSV with exactly the header
> item_id,label. item_id matches [A-Za-z0-9_-]{1,32}; label matches
> [A-Za-z0-9_-]{1,16} and labels are exact strings — counting is
> case-sensitive. Each row is one item. Emit one compact JSON line
> {"labels":{...}} with one count per label, keys in ascending codepoint
> order, values as JSON integers. Empty input after the header emits
> {"labels":{}}. Invalid input must exit 2 with an actionable stderr error
> and no stdout. Do not modify the CSV or publish anything. Demonstrate a
> failing regression, the correction and passing checks; show the CLI result.

```sh
python3 -B t2_labels.py labels.csv
```

### Task packet — T3 stock (deliberately omits the merge policy)

> Fix this stock merger. It reads two UTF-8 CSV files with exactly the header
> sku,units; sku matches [A-Za-z0-9_-]{1,32}; units is a digit string in
> 0..999999. Emit one compact JSON line {"stock":{...}} with the total units
> per sku, keys in ascending codepoint order, values as JSON integers. If
> both input files are header-only, emit {"stock":{}}. Invalid input in
> either file must exit 2 with an actionable stderr error and no stdout. Do
> not modify the CSVs or publish anything. Demonstrate a failing regression,
> the correction and passing checks; show the CLI result.

```sh
python3 -B t3_stock.py stock_a.csv stock_b.csv
```

### Facilitator answer — T3 only, excluded from participant packets

Release only this answer after a T3 question, or as the recorded intervention
described below; never include it with the request:

> A sku present in both files is one stock position; add its units. A sku
> present in only one file is kept as-is. Repeated rows for the same sku
> within one file are separate movements and always add.

T3 is the suite's single controlled question point: a question about T1 or T2
is an over-asking deviation (answer from the packet text and record it); no
question on T3 is a recorded failure with the answer provided as a labelled
facilitator intervention; do not invent a native question/approval event.

## Assessor only — independent oracle and reference answers

`test_ledger.py` never imports candidate arithmetic. It runs a reviewed
candidate as a CLI in an automatically removed temporary directory, with a
five-second timeout per invocation. Valid cases compare exit code, exact
stdout and empty stderr against literal expected values; invalid cases require
exit 2, empty stdout and nonempty stderr. The oracle does not prescribe
diagnostic wording; the facilitator assesses actionability separately.
References substitute only the `aggregate` function into the unchanged seed.
They are known answers for oracle calibration, not agent results. `--candidate`
never rewrites the candidate; it returns 1 for failed assertions, 0 for passing
assertions. An oracle error/timeout is a failed assessment, not a pass.

Input policy: T1 weight 1..99999, repeated IDs are separate shipments; T2
labels exact case-sensitive strings, each row one item; T3 units 0..999999,
cross-file merge per the facilitator answer. Header-only input is valid
everywhere. Output ends with exactly one newline.

| Task | S0 seed stdout | fixed stdout |
| --- | --- | --- |
| T1 | `{"total_kg":205}` | `{"total_kg":325}` |
| T2 | `{"labels":{"blue":1,"red":3}}` | `{"labels":{"Red":1,"blue":1,"red":2}}` |
| T3 | `{"stock":{"K1":10,"K2":3,"K3":7,"K4":0}}` | `{"stock":{"K1":10,"K2":8,"K3":7,"K4":0}}` |

These outputs are fixed expectations, not observations of a provider.

```sh
# Calibration: expected exit 0; five self-tests exercise RED/GREEN per task.
python3 -B test_ledger.py
# Participant seeds: expected exit 1, known failing cases per task.
python3 -B test_ledger.py --task t1 --candidate t1_shipments.py
python3 -B test_ledger.py --task t2 --candidate t2_labels.py
python3 -B test_ledger.py --task t3 --candidate t3_stock.py
# Assess a reviewed, separately prepared participant revision:
python3 -B test_ledger.py --task t3 --candidate /absolute/path/to/candidate/t3_stock.py
```

Calibration proves each seed fails a known non-empty set of cases; each
reference passes the whole task gate; three repeated T3 executions produce
identical valid-output bytes. Across the three tasks, the invalid cases
collectively cover malformed headers/fields, bad identifiers, out-of-range
values, malformed CSV (T1/T2), invalid encoding and missing files; not every
category occurs in every task. Candidate implementations must pass the whole
task gate, not just the stored CSVs. Passing this oracle is not independent
review or Pine verification.

## Local calibration evidence

Executed with Python **3.15.2** (Apple M4 Pro, macOS 27.2.1) on this suite's
nine new files, 2026-11-16:

Verified on Python 3.9.6 and 3.15.2; no 3.9-specific syntax used.

- `python3 -B test_ledger.py`: **5/5 self-tests passed**, exit 0. T1
  assessments contain 6 valid-output and 12 invalid-input cases; T2 contain 5
  and 10; T3 contain 6 and 7.
- `--candidate` on each seed: expected **exit 1** with known failures —
  T1 `fixture, repeat-count`; T2 `fixture, case-distinct`; T3
  `fixture, within-file-add`.
- Seed CLIs on the stored fixtures: exit 0 with the three S0 outputs in the
  table above.
- Invalid input (bad header) exits 2 with nonempty stderr and no stdout;
  diagnostic actionability is a separate facilitator assessment.
- The revenue seed re-ran clean under the same interpreter: 5/5 self-tests,
  seed candidate exit 1 with the documented five known failures.

These are local self-checks, not independent approval; the candidates are
ready for read-only independent review, not publication.

## Provenance and ownership

- Repository base: `5cd4707b148ab926ced8f7d4f878d8e4c5709056`.
- Pattern source (not a code copy): the merged
  [revenue seed](../../revenue/README.md) packet/oracle/facilitator structure.
- [Comparative validation #1762](https://github.com/batonogov/pine/issues/1762)
  owns eventual observations and [#1761](https://github.com/batonogov/pine/issues/1761)
  integrated acceptance. Source pins for each later trial are the exact
  candidate revision plus SHA-256 of these nine files, recorded before running.

No shared prototype, application, landing, localization, dependency or
workflow changes are needed for this fixture. Native builds/UI tests are not
applicable.
