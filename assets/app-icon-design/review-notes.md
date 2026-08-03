# Pine Compact Stack — design review notes

## Decision

Compact Stack is the production direction. It keeps the existing three-plate identity while replacing the former raster illustration with a compact, optically balanced symbol that Icon Composer can render as native Liquid Glass.

The source artwork is intentionally flat. It contains no outer mask, gradient, opacity, stroke, blur, glow, bevel, highlight, shadow, or refraction.

## Geometry

- Canvas: 1024 × 1024, shared by all three SVG layers.
- Combined rendered bounds: approximately x = 85…940, y = 132…911 after the shared 1.25× layer scale and 1.16× vertical optical correction.
- Horizontal breathing room: 84 px on the tight side; the mark occupies 83.5% of canvas width.
- Vertical breathing room: 113 px on the tight side; the mark occupies 76.1% of canvas height.
- Optical center: approximately (512, 522), ten pixels below the mathematical center to balance the visually heavier lower plate.
- Rendered plate widths progress from approximately 855 px to 773 px to 610 px. The non-linear reduction makes the mint plate the bridge and prevents the stack from reading as three cloned buttons.
- Horizontal centers progress 512 → 486 → 536. The restrained −26/+24 px rhythm is visible at large sizes but collapses into one stable mass at 16–32 pt.
- Every source edge is a closed Bézier contour with no stroke. Rounded side transitions remain broad enough to survive rasterization at the smallest sizes.

## Hierarchy

- Mint is the focal plate: most saturated and positioned between the supporting cyan and blue layers.
- The lower plate supplies weight and contrast on light backgrounds.
- The upper plate is smaller and lighter, but its value is kept far enough from the light background to remain visible before system highlights are applied.
- Overlap, width, and position establish order independently of hue. The silhouette remains recognizable when rendered in one color.

## Material

- The document owns the full-bleed opaque background; no background bitmap is imported.
- Each plate has its own group so the system can preserve separation at 16 and 32 pt.
- Each group contains one vector layer, making Individual and Combined behavior equivalent without adding unnecessary composition complexity.
- Translucency and neutral shadows are deliberately conservative. They support separation rather than creating a second illustration on top of the vector artwork.
- Default, Dark, and Mono (`tinted`) keep identical geometry. Only value and material response vary.

## Color intent

| Role | Default | Dark | Mono source value |
| --- | --- | --- | --- |
| Background | light teal | deep teal | charcoal |
| Lower plate | cool blue | lifted blue | 36% gray |
| Focal plate | saturated mint | lifted mint | 65% gray |
| Upper plate | calm cyan | pale cyan | 91% gray |

The source SVG fills match the Default palette so the editable artwork remains intelligible outside Icon Composer. Icon Composer specializations are authoritative for exported appearances.

## Rejected directions

- **Clean reconstruction:** preserves the old equal-size plates and large gaps, but reads as three unrelated controls below 32 pt.
- **Dynamic Stack:** adds rotation, but its energy competes with Liquid Glass lighting and undermines Pine’s calm, capable tone.
- **Monogram/tree/terminal/agent glyph:** explicitly excluded because it would discard the established identity or tie the product to one temporary feature metaphor.

## Review checklist

- Inspect `assets/app-icon-design/silhouette-study.svg` before judging color or glass.
- In Icon Composer, rotate the lighting angle through a full turn and confirm no layer blooms or loses its edge.
- Compare Default, Dark, Tinted Light/Dark, and Clear Light/Dark over white, black, mid-gray, teal, and saturated blue backgrounds.
- Inspect 16, 32, 64, 128, and 512 pt previews at 100% zoom.
- On a real system, verify Dock, Finder list/column/gallery, Spotlight, app switcher, Force Quit, Welcome, and the DMG.
