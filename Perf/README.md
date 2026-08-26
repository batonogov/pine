# Pine Performance Profiling

This directory formalizes Pine's performance measurement beyond the raw
`measure {}` blocks in `PinePerformanceTests/`. It ships:

- **`Pine.tracetemplate/`** — an Instruments template descriptor (Time Profiler +
  System Trace + Allocations) tuned for Pine's hot paths.
- **`InputLatency.md`** — the methodology for measuring true keystroke-to-pixel
  latency (the metric Zed/Alacritty publish).
- **`OSSignposter` tracing** — `Pine/PerformanceSignposts.swift` emits
  lightweight intervals in DEBUG builds that show up in Instruments and
  `xctrace` recordings.

Pine's nightly regression detection (`nightly-perf.yml` +
`scripts/check_perf_regression.py`) already catches *that* a benchmark
regressed. This tooling answers *why* and *where*.

---

## OSSignposter intervals

`Pine/PerformanceSignposts.swift` wraps Pine's hot paths in `os.OSSignposter`
intervals. **These are compiled out in release builds** — production carries
zero signpost overhead. Run a DEBUG build to see them.

Intervals emitted (subsystem `io.github.batonogov.pine`, category `hotpath`):

| Interval           | Where                                            |
|--------------------|--------------------------------------------------|
| `highlight.full`   | `SyntaxHighlighter.highlight` (full re-highlight)|
| `highlight.viewport` | `SyntaxHighlighter.highlightVisibleRange`      |
| `highlight.edited` | `SyntaxHighlighter.highlightEdited` (incremental)|
| `scroll.frame`     | `CodeEditorView` scroll handler (per frame)      |
| `filetree.shallow` | `WorkspaceManager` shallow Phase 1 load          |
| `filetree.full`    | `WorkspaceManager` full Phase 2 load             |

To add a new interval in Swift:

```swift
// Synchronous (preferred):
let result = PerformanceSignposts.trace("myfeature.work") {
    expensiveWork()
}

// Async / cross-actor (manual begin/end pairs):
let token = PerformanceSignposts.beginInterval("myfeature.load")
defer { PerformanceSignposts.endInterval("myfeature.load", token) }
```

No `#if DEBUG` is needed at call sites — the DEBUG guard lives inside
`PerformanceSignposts`.

---

## Recording a profile

### Option A — Instruments GUI

1. Open **Instruments** (Xcode → Open Developer Tool → Instruments).
2. Pick **Time Profiler** (add **System Trace** and **Allocations** from the
   library for the full template).
3. Choose target → **Pine (Debug)**. A release build will not emit signposts.
4. Record the scenario (see *Scenarios* below), then stop.
5. Filter the **Points of Interest** track on subsystem
   `io.github.batonogov.pine` to see the intervals above.
6. **File → Save As Template…** to re-create a fully-importable
   `.tracetemplate` bundle (this is what `Pine.tracetemplate/TemplateInfo.plist`
   documents — Instruments stores the layout in a binary `Template.waxobject`
   that is not human-writable, so the plist is the version-controlled source of
   truth for the configuration).

### Option B — `xctrace` command line (reproducible, CI-friendly)

```bash
# Build a DEBUG Pine first (so signposts emit).
xcodebuild -project Pine.xcodeproj -scheme Pine -configuration Debug build \
  -derivedDataPath build

APP=$(find build -name Pine.app -type d | head -1)

# Record ~10s of Time Profiler + the signpost intervals.
xctrace record \
  --template "Time Profiler" \
  --launch -- "$APP/Contents/MacOS/Pine" \
  --time-limit 10s \
  --output Pine-scroll.trace

# Inspect signpost intervals in the recording.
xctrace export --input Pine-scroll.trace --xpath \
  '//trace-toc[run/@number=1]/data/table[@schema="signpost-summary"]'
```

Open `Pine-scroll.trace` in Instruments for the interactive view.

---

## Scenarios

Match these to the nightly perf benchmarks so a GUI investigation lines up
with a regression report.

| Scenario            | How to reproduce                                              | What to look at                          |
|---------------------|---------------------------------------------------------------|------------------------------------------|
| **scroll-latency**  | Open a 100K-line file, smooth-scroll for ~5s                  | `scroll.frame` intervals, frame time     |
| **highlight-overhead** | Open a 5K-line file, trigger a full re-highlight           | `highlight.full` duration, Time Profiler |
| **file-tree-load**  | Open a project root with 1000+ files                          | `filetree.shallow` / `filetree.full`     |
| **memory-pressure** | Open a 10MB+ file (`hugeFileThreshold` partial-load path)     | Allocations, `highlight.*`               |

The target is **<4ms main-thread work per scroll frame** for 120Hz ProMotion
(see `.claude/rules/concurrency.md`).

---

## Regression detection

This tooling complements, it does not replace, the nightly pipeline:

- `PinePerformanceTests/baselines.json` — the per-test wall-clock baselines.
- `.github/scripts/check_perf_regression.py` — compares xcresult durations to
  baselines (15% threshold), posts an issue on regression.
- `.github/workflows/nightly-perf.yml` — the nightly runner.

Use the `Pine.tracetemplate` recording + signpost intervals to investigate a
regression the nightly pipeline flags.
