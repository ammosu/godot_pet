# Default Pet Palette Harmonization

## Goal

Make the default pet spritesheet feel consistently lit from every viewing
angle, using the first-row idle animation as the visual reference.

## Scope

- Edit `pets/default/spritesheet.webp`.
- Use the first idle row as the reference for cream fur brightness, warm-gray
  shadow depth, green markings, orange tail accent, and dark outline strength.
- Correct the strongest mismatch in the final two directional-look rows,
  especially the rear-facing frames that currently read as nearly white.
- Apply only small exposure and color-balance corrections to other frames when
  they visibly diverge from the idle reference.

## Invariants

- Preserve the exact 1536×2288 canvas and 8-column, 11-row cell grid.
- Preserve every pose, silhouette, facial feature, animation frame position,
  and occupied/blank cell.
- Preserve the transparent background and clean antialiased edges.
- Do not add lighting effects, redraw anatomy, introduce new details, or change
  the character's established palette.

## Acceptance

- Rear and side directional frames no longer flash noticeably brighter when
  selected in sequence.
- Cream fur remains light but retains shadow separation comparable to idle.
- Green and orange accents remain recognizable and consistent.
- The sheet still loads as a v2 pet pack with all 16 look-direction frames.
