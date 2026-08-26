---
name: macos27-crash-triage
description: Use when the PineTests host crashes, hangs, or segfaults on the macOS 27 beta (issue #1509) — reading .ips diagnostic reports, pinning the OS build, injecting objc/malloc diagnostics through a copied .xctestrun, or interpreting an objc_autoreleasePoolPop backtrace. Not for ordinary test failures.
---

# Diagnosing a test-host crash on the macOS 27 beta (#1509)

- Trust `~/Library/Logs/DiagnosticReports/`, not the console log — the beta drops log lines badly. Reports rotate into `Retired/` and only about twenty are kept there, so **copy a report out the moment you see the crash**; the two incidents #1509 was opened on were already gone by the time it was triaged.
- Record the OS **build**, not the marketing version: `sw_vers` → `BuildVersion`, matched against `osVersion.build` in the `.ips`. `/var/log/install.log` (`Previous System Version … Current System Version …`) says when the machine changed builds, which is the first thing to check before calling a crash reproducible or fixed.
- Inject `objc`/malloc diagnostics by copying the generated `.xctestrun` and editing `TestConfigurations → TestTargets → EnvironmentVariables`, then `xcodebuild test-without-building -xctestrun <copy>`. Keep the copy **in the same directory as the original** — the file's `__TESTROOT__` placeholders resolve relative to it. Useful keys: `OBJC_DEBUG_POOL_ALLOCATION=YES` (halts on an out-of-order pool pop), `OBJC_DEBUG_MISSING_POOLS=YES`, `OBJC_DISABLE_AUTORELEASE_COALESCING=YES`, `MallocScribble=1`, `NSZombieEnabled=YES`.
- For a crash in `objc_autoreleasePoolPop` → `AutoreleasePoolPage::releaseUntil` → `objc_release`, the registers `x22 = 0xa1a1a1a1`, `x23 = 0xf00ffffffffffff` and `x24 = 0xa3a3a3a3a3a3a3a3` are **not** evidence of anything — they are loop-invariant constants (pool-page magic, pointer mask, SCRIBBLE byte) materialised in `releaseUntil`'s prologue on every single pool pop. Read `x0`/`x21` (the object being released), the word at `[x0]` (its `isa`), and confirm `far == (isa & 0x7ffffffffff8) + 0x20`. Reaching `releaseUntil` at all means libobjc already validated the page magic, so the pool page itself was intact.

## Before you blame the diff

A local failure on this runtime is not a pass/fail signal — CI is. `CLAUDE.md`
names the two standing failures that reproduce there regardless of the diff in
the tree. Confirm a failure on an idle machine first.
