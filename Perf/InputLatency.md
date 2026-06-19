# Input-Latency Measurement Methodology

This document defines how to measure Pine's **true keystroke-to-pixel
latency** — the time from a physical key press to the corresponding glyph
appearing on screen. This is the metric Zed and Alacritty publish, and the one
`measure {}` benchmarks fundamentally cannot capture (they measure isolated
code paths, not the full input → layout → composite → scanout pipeline).

References:
- Pavel Fatin, ["Typing with pleasure"](https://pavelfatin.com/typing-with-pleasure/) —
  the canonical methodology for editor latency measurement.
- Zed's [latency posts](https://zed.dev) and Alacritty benchmarks use the same
  high-speed-camera approach.

---

## Why this matters

Pine targets **<4ms main-thread work per scroll frame** for 120Hz (measured via
`PinePerformanceTests`). But the user-perceived latency of typing includes:

1. **Input event delivery** — HID → AppKit → NSTextView key handling.
2. **Text mutation** — NSTextStorage edit + delegate callbacks (smart lists,
   bracket matching, comment toggling).
3. **Layout** — NSLayoutManager glyph generation / line fragment layout.
4. **Syntax highlighting** — async re-highlight dispatch (debounced).
5. **Display composite** — CoreAnimation render + GPU scanout.

Steps 1, 4, and 5 are invisible to `measure {}`. This methodology measures the
end-to-end value.

---

## Methodology (v1 — high-speed camera)

This is the gold-standard approach used by every low-latency editor benchmark.

### Equipment
- A **high-speed camera** (≥ 240 fps; 1000 fps preferred). An iPhone in
  slo-mo (240 fps) is sufficient for a first approximation.
- A mechanical or known-actuation-force keyboard.
- Pine running in a **Release** build (latency must be measured on the
  shipped configuration, not a DEBUG build).

### Procedure
1. Frame the camera on the keyboard key **and** the editor's caret/glyph area
   in one shot.
2. Start recording, type a single key.
3. In the recorded frames, identify:
   - **Frame N**: the key bottoming out (fully pressed — the input event).
   - **Frame M**: the new glyph first visible on screen.
4. Latency = `(M − N) × (1000 / fps)` ms.

### Worked example (240 fps)
- Key bottoms out at frame 12.
- Glyph appears at frame 19.
- Latency = `(19 − 12) × (1000 / 240)` = **29 ms**.

### Taking a stable measurement
- Record **≥ 10 keystrokes** and report median + p95 (Fatin's methodology).
- Discard the first keystroke of a run (cold cache).
- Measure at the start, middle, and end of a large file (latency grows with
  document size due to layout / highlighting scope).

---

## Methodology (v1 — software fallback)

When no high-speed camera is available, a coarser software probe gives a
first-order number. This does **not** capture the display scanout, so it
underestimates true latency, but it is reproducible and CI-adjacent.

Instrument the DEBUG build (guarded by `#if DEBUG`) at two points:

```swift
// 1. Key event enters the text system.
func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
              replacementString: String) -> Bool {
    PerformanceSignposts.beginInterval("input.keystroke")
    // ... existing logic ...
}

// 2. After the text view finishes layout for the edit (didLayout / drawRect).
//    PerformanceSignposts.endInterval("input.keystroke", token)
```

Then record with `xctrace` (see `Perf/README.md`) and read the
`input.keystroke` interval. This measures event-in → layout-out, not
event-in → scanout-out. Document the gap explicitly when reporting numbers.

> The software probe is intentionally **not** wired into the codebase yet. It
> requires a stable layout-done hook and a per-keystroke token that the current
> NSTextView coordinator does not expose cleanly. It is tracked as a follow-up
> (see *Follow-ups* below).

---

## What to report

For a comparable latency number, always state:

1. **Build configuration** (Release vs Debug).
2. **Document size** at measurement time (lines / bytes).
3. **Camera fps** (or "software probe, no scanout").
4. **Aggregate**: median and p95 over ≥ 10 keystrokes.
5. **Hardware**: keyboard (actuation), display (refresh rate), Mac (SoC).

Reference points (from Fatin / public benchmarks, as of writing):

| Editor        | Typical latency (median) |
|---------------|--------------------------|
| Alacritty     | ~16 ms                   |
| Zed           | ~10–20 ms                |
| VS Code       | ~30–50 ms                |

Pine's target: **competitive with native macOS editors (< 30 ms median on a
Release build for files under the large-file threshold).**

---

## Follow-ups (not in this PR)

- **High-speed-camera rig**: a permanent camera + fixture for repeatable
  automated captures. Requires hardware budget; methodology above is
  sufficient for manual v1.
- **Software probe integration**: wire a `input.keystroke` signpost pair from
  the text delegate through to a layout-complete hook, gated behind a DEBUG
  flag, to get a CI-adjacent latency signal.
- **Automated regression gate**: feed the camera-measured median into the
  nightly pipeline alongside `check_perf_regression.py`.
