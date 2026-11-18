# #1762 validation kit

Everything executable and honest **around** the live cohort trial of Pine 3.0's
result-first flow against leading ADEs. The trial itself is external:
5–8 opt-in developers, opt-in recordings, maintainer-run. **No trial has run
from this kit; every target in it is a pre-registered hypothesis, and no
comparative effectiveness is claimed anywhere in it.**

## Contents

| Path | What it is |
| --- | --- |
| [revenue/](revenue/README.md) | Merged (#1802) offline EUR-CLI fixture + independent oracle; SC1–SC4 packets, controlled interruption. Calibrated; **unchanged by this kit.** |
| [scenarios/](scenarios/README.md) | The issue's six benchmark scenarios (SC1–SC6) and the representative-failure suite (F1–F6) as reproducible facilitator protocols; [ledger/](scenarios/ledger/README.md) fixture: three independent tasks with exactly one controlled question. |
| [baseline-access.md](baseline-access.md) | Trial-machine access record, 2026-11-16: the three required baselines (Zed, herdr, one result-oriented) each carry a **named concrete access blocker**; available provider CLIs recorded. |
| [scorecard.md](scorecard.md) | Row template, pre-registered thresholds marked HYPOTHESIS with the pilot-refinement rule, small-sample reporting rules, and the measured-finding → owning-issue trace. |
| [ade-boundary-ux-acceptance.md](../../ade-boundary-ux-acceptance.md) | #1810 boundary cards B1–B6 this suite operationalizes; its evidence-row format and entry conditions are reused, not duplicated. |

## Running the offline parts (no provider, no network)

```sh
cd docs/validation/1762/revenue
python3 -B test_report.py                       # 5/5 self-tests
python3 -B test_report.py --candidate report.py --stage first   # exit 1, known RED set

cd ../scenarios/ledger
python3 -B test_ledger.py                        # 5/5 self-tests
python3 -B test_ledger.py --task t1 --candidate t1_shipments.py # exit 1, known RED set
```

These calibrate the fixtures only. End-to-end scenarios (SC1–SC6, F1–F6)
require the live cohort trial and an authorized provider; see
[scenarios/README.md](scenarios/README.md) for per-scenario runnability labels.

## Running the live trial (maintainer-run)

1. Resolve each required baseline per
   [baseline-access.md](baseline-access.md): install + authorized session +
   recorded exact version, or keep the named blocker and mark that baseline
   source-only.
2. Re-record machine conditions and fixture SHA-256 at run time.
3. Fresh isolated fixture copy per trial; distribute packets + fixture files
   only (never oracles or facilitator answers); counterbalance tool order;
   separate first-use from repeat-use.
4. Run SC1–SC6 and F1–F6 where the tool supports them; fill one scorecard row
   per run per [scorecard.md](scorecard.md).
5. Publish task scripts, evidence classifications and anonymized observations;
   feed findings through the design-decision trace to #1735, the product
   slices and #1761.

## Ownership

[#1762](https://github.com/batonogov/pine/issues/1762) owns the observations
and the public-claim boundary; [#1761](https://github.com/batonogov/pine/issues/1761)
owns the integrated evidence record; #1810 owns the boundary protocol;
[#1735](https://github.com/batonogov/pine/issues/1735) owns design corrections.
