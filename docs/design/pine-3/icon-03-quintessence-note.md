# icon-03 — Quintessence

Direction 3 follow-up for the new Pine 3 identity (#1736): “Pine — the quintessence of ADE”. Malevich-inspired reduction to essential forms — one plane, one line — explored through Liquid Glass material, transparency, and refraction while keeping a simple silhouette. The initial flat square/circle/bar composition for this direction was not selected; this is the requested follow-up expression. Status: concept for maintainer discussion, not approved.

Created 2026-11-13. Unlike icon-01/icon-02 (AI-generated raster explorations), the master is hand-authored editable vector artwork: every shape is a real path, polygon, rect, or gradient stop. There are no embedded bitmaps, no rendered text elements (each master carries a non-rendered `<title>` metadata element), and no generated pixels.

- Master: [icon-03-quintessence.svg](icon-03-quintessence.svg)
- Monochrome variant: [icon-03-quintessence-mono.svg](icon-03-quintessence-mono.svg)
- Contact board: [icon-03-quintessence-render-board.png](icon-03-quintessence-render-board.png)

## Concept and metaphor

Creation reduced to its essence: a single tilted glass plane carries one straight line of intent. The line enters from a small glass tile in the lower left, refracts through the plane (a brighter band inside the glass), and exits as a fading tail at the upper right. Two squares and one diagonal — the irreducible geometry of an agent doing work.

## Geometry and material approach

What the master actually does, at 1024×1024 with a `rx=229` rounded-rect squircle approximation (229/1024 ≈ 0.224, the usual rounded-rect stand-in for the macOS superellipse):

- **Field.** Diagonal linear gradient `#1D514C → #113844 → #091D2C` (deep evergreen to dark petrol to near-black navy) with two faint radial white glows (top-left ambient at 0.08, bottom-right at 0.05) for atmosphere.
- **Glass plane.** 480×480 rounded square (rx 28) rotated +12° around its center. Liquid Glass treatment built from static simulation: translucent white fill gradient (opacity 0.30 → 0.10), a bright rim stroke fading diagonally (white 0.85 → 0), a blurred 14px inner edge (white 0.10, blur 10), and a 7px iridescent hairline along the top edge (peach `#FFC08A` → white → cyan `#8CE8E2`). A soft drop shadow (dark `#04101A` at 0.55, blur 26, offset and rotated with the plane) grounds the plane.
- **Refraction.** Inside the plane, clipped to the glass: one sharp white band at 0.80, haloed by a blurred band at 0.50 (blur 10), plus two fainter echo bands (0.07, 0.16, blur 10) — the beam continuing through the material.
- **Beam of intent.** Tapered white band (`#F7FAFC` at 0.85) running diagonally from the small tile to the plane, with a blurred under-glow (0.35, blur 10), exiting the top edge as a fading tail (white 0.60 → 0).
- **Small tile.** 140×140 rounded square (rx 16) rotated −12°, its own glass fill (0.45 → 0.18) and bright rim (1.0 → 0.25), own soft shadow, and a blurred glow at its corner marking the beam origin.
- **Edge light.** 3px white stroke (0.18 → 0) inset 1.5px along the squircle for top light.
- **Filters.** Three Gaussian blurs only (stdDeviation 10/14/26). All gradients use explicit stops; the mono variant swaps the field to flat `#141416` and keeps silhouette geometry identical — the decorative deltas are the dropped 14px inner-edge hairline and the tile glow circle shifting from (256, 758, r 70, opacity 0.32) to (252, 762, r 55, opacity 0.28). It also drops the iridescent hairline to a flat white 0.40 top edge and raises glass opacities slightly — a single-hue recognition test.

## Real-size validation performed

From the files present in this directory:

| Render | Size | Background |
|---|---|---|
| `icon-03-quintessence-render-512.png` | 512×512 | transparent |
| `icon-03-quintessence-render-128.png` | 128×128 | transparent |
| `icon-03-quintessence-render-32.png` | 32×32 | transparent |
| `icon-03-quintessence-render-16.png` | 16×16 | edge-to-edge, no margin |
| `icon-03-quintessence-render-on-light.png` | 1024×1024, icon ≈ 816px with shadow bleed | light `#EDEFF1` |
| `icon-03-quintessence-render-on-dark.png` | 1024×1024, icon ≈ 816px with shadow bleed | dark `#0A0D12` |
| `icon-03-quintessence-render-mono-512.png` | 512×512 | transparent |
| `icon-03-quintessence-render-mono-32.png` | 32×32 | transparent |
| `icon-03-quintessence-render-board.png` | 1024×1024 contact sheet | large render on light and on dark; 128/32/16 ladder on light and on dark; the sheet background between panels is transparent |

Observed on the board: at 16px the silhouette reads as a dark squircle with a bright diagonal — the beam and tail dominate, the glass rim is a faint edge, and the small tile and iridescent line do not resolve (acceptable loss, the silhouette survives). At 32px the plane rim and beam are visible. On the dark background the icon picks up a soft light halo around the edge (ambient glow plus edge stroke); on light it reads crisp.

Master/render consistency: a fresh local re-render of the master (macOS Quick Look) versus the committed 512 render gives a silhouette alpha-mask IoU of 0.958; the residual difference is blur/gamma behavior of the rendering engine, not geometry. No master change was made during this review, so no re-render was required.

Not yet validated: no mono renders at 128/16, no measured Dock or menu-bar sizes (these are renders, not in-app measurements), and no rendering in a real app context.

## Similarity comparison (silhouette and metaphor level)

- **vs Candidate 1 — “Intent taking form”** (coral gesture becoming a defined object): different metaphor (expressive energy vs optical reduction) and different silhouette (one fluid curved stroke vs a rotated square crossed by a straight diagonal). No shared shape language; the beam is a straight tapered band, not a gesture, so the torch/snake association risk of candidate 1 does not transfer (no flame tip, no undulation).
- **vs Candidate 2 — “Growing an idea”** (pale jade sprout from a deep blue seed shell): different metaphor (living growth vs essential form) and different silhouette (organic sprout emerging from two shell halves vs two squares and one diagonal). Different ground as well: candidate 2 is a light ivory tile; this is a dark tile overall.
- **vs rejected A — Fold**: no folded band and no porcelain ground. A was rejected for reading as spreadsheet software; the single plane here has no fold line and no frame-like band to trigger that reading.
- **vs rejected B — Aperture**: no doorway or architectural opening; the glass plane is a flat tilted square, not a void with depth, and the overall weight is light rather than heavy.
- **vs rejected C — Assembly**: not three interlocking forms; one dominant plane with one satellite tile, and the composition is organized by a single diagonal rather than a cluster, so it keeps a clear central silhouette.
- **vs the currently shipped production icon** (three isometric plates on pale mint): plainly distinct — a tilted single glass plane with a diagonal beam and a satellite tile, versus three stacked isometric plates on a pale ground.

The silhouette is original to this concept and distinct from all retained and rejected directions, as required by #1736 (distinct silhouettes and metaphors only; the blue recolor of candidate 1 was explicitly rejected).

## Association risks to watch

- **Beam/laser.** The strongest alternative reading is “line of light through glass.” If the maintainer wants the beam to read as intent rather than a laser, the tail fade and the small-tile origin help, but a flatter or shorter exit tail would weaken the beam reading.
- **Window pane/slate.** A tilted square alone can read as a pane or a slate; the beam and the satellite tile are what keep it specific.
- **Holographic cliché.** The iridescent hairline risks a CD/holographic sticker association in marketing if emphasized; it is faint in the master and inapplicable to the mono variant.
- **Satellite tile at small sizes.** At 16px the tile is just a bright corner; it must not start reading as a badge or a key. It does not resolve into one at current sizes.
- **Strict Malevich grid.** The ±12° rotations deliberately depart from a flat grid; that departure is what distinguishes this from the not-selected flat square/circle/bar first pass. Keep it if the direction is approved.

## Open decisions

1. Approve, reject, or iterate direction 3 ("Quintessence").
2. If iterating, which axis: tail length / beam weight, field hue, tile presence, ±12° rotation angle.
3. Dark-mode strategy: single dark master for both modes (recommended) / light-mode variant / mono as template.

## What a production master would need

- **Exact squircle.** Replace the `rx=229` rounded-rect approximation with the macOS continuous-corner (superellipse) path at 1024×1024.
- **icns export.** Standard tier set (16/32/128/256/512, @1x/@2x), plus measured checks in a real Dock (64/128) and menu bar (16/18/22) context; the renders here are not those measurements.
- **Dark mode strategy.** The field is already dark, so a single master works for both modes (recommended); a light-mode field variant and the mono variant (template/marketing fallback) would be the other two options. Decide before export.
- **Liquid Glass rendering note.** The material is statically simulated (gradients, blurs, transparency), which keeps the asset deterministic and portable. A real-time material is not possible in a static app icon; if the product wants live glass, it belongs to app chrome, not the icon.
- **If selected.** Rebuild any raster presentation crops from this master, update the app bundle icon, and align marketing surfaces; this archive itself does not change the shipped icon.
