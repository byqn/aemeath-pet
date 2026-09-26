# aemeath — pet-specific look mechanics

This file is authoritative for how `aemeath` expresses gaze in rows 9 and 10. Every look cell
must follow it. Screen-left and screen-right always mean the **viewer's** image edges, never the
character's own left or right.

## Anatomy that constrains the motion

- Super-deformed Q-version chibi: the head is roughly 40 percent of total figure height (about
  2.5 heads tall). The body below the chin is small and compact.
- The neck is essentially hidden by the chin and the collar. Do not invent a long visible neck,
  and do not let the head slide off the shoulders.
- The eyes are very large amber-gold eyes with star-shaped highlights. They carry most of the
  gaze readability at 192x208.
- Long pastel-pink side locks frame both sides of the face. Two small cyan crystal clips sit flat
  against the hair on the upper left and upper right of the head.
- She holds nothing. There is no prop, tool, weapon, or companion to follow or lag, so no
  prop follow-through exists for this pet.
- Both feet stay planted and the body stays broadly frontal in every look cell.

## Motion hierarchy (mandatory)

1. **Eyes lead.** The pupils/irises rotate inside the eye sockets toward the target direction
   first; the upper and lower eyelids plus the eyebrows participate (narrowing, lifting, or
   relaxing) so the gaze is unmistakable.
2. **Head follows subtly.** Add a restrained head turn (yaw) for left/right directions and a
   restrained head pitch (up/down) for vertical directions. Keep the skull shape, face
   proportions, eye size, eye spacing, and mouth shape identical to the canonical base — move the
   head as a near-rigid unit instead of deforming the face.
3. **Upper body follows last and least.** Add only a small shoulder/upper-torso lean or counter
   lean. The lower body, skirt, legs, and feet keep the same registration as the standard rows.
4. **Hair and clips travel with the head.** The side locks and both crystal clips stay attached to
   the hair and rotate with the head, with a very small lag. Far-side hair may occlude part of the
   head silhouette, but the eyes must never be fully hidden by hair in any cell.

## Cardinal pose families (declare before generating)

- **000 up** — Pupils move to the top of the eye shape, upper eyelids lift slightly, eyebrows
  raise, chin lifts a little, head pitches back modestly. The face stays broadly frontal; only a
  small amount of the underside of the chin and collar becomes visible. This is *up*, never a
  neutral or front-facing filler pose.
- **090 screen-right** — Nose tip, pupils, and face surface shift to the viewer's **right** of the
  head center. The head yaws to the character's own left, so more of the character's **left**
  cheek and left side lock become visible, the far (character's right) cheek and its crystal clip
  become partly occluded, and the upper body leans very slightly right. Eyes still lead.
- **180 down** — Pupils move to the bottom of the eye shape, upper eyelids lower, chin tucks a
  little, head pitches forward modestly. The face stays broadly frontal; the top of the head and
  the hair crown become slightly more visible. This is *down*, never a neutral filler pose.
- **270 screen-left** — Exact inverse of 090: nose tip, pupils, and face surface shift to the
  viewer's **left** of the head center; more of the character's **right** cheek and right side
  lock become visible; the far (character's left) clip becomes partly occluded; the upper body
  leans very slightly left.

## Diagonal rows (22.5-degree steps)

Rows 9 and 10 interpolate evenly between the four cardinal families. Neighbouring cells must differ
by a small, even, readable step rather than by a jump. The 157.5 and 180 boundary and the 337.5
and 000 boundary must join continuously in both identity and gaze direction.

## Directional readability thresholds (mandatory for rows 9 and 10)

The approved cardinal anchors are correct but deliberately restrained. Rows 9 and 10 must read
**more** clearly than the anchors, not less, because the final cells are viewed at 192x208 with no
labels. For every one of the 16 directions:

- **Eyes must move measurably.** For left/right directions the pupils must travel far enough to
  visibly cross past the centre line of the eye white toward the target side; for up/down
  directions the pupils must sit clearly in the upper or lower third of the eye, with the eyelids
  opening or closing enough to be named without a label.
- **One landmark must be nameable.** A viewer who cannot see any label must be able to name the
  direction from at least one landmark: pupil position relative to the eye white, nose tip
  relative to head centre, chin height, or head silhouette. If a cell could be mistaken for a
  neighbouring direction, it fails.
- **Head turn may exceed the anchor.** Use a slightly larger head yaw for left/right and a
  slightly larger pitch for up/down than the cardinal anchors show, while keeping the skull, face
  spacing, and expression near-rigid. Do not reach the clarity target by deforming the face.
- **Never hide the leading eye.** The far side of the head may be more occluded by hair as the head
  turns, but the eye that leads the gaze must stay clearly visible in every cell.
- **Keep the steps even.** Adjacent cells in the same row must differ by a small, roughly equal
  step; no cell may jump ahead of or lag behind its neighbours in the 22.5-degree sequence.

## CRITICAL: gaze compass, not a turntable

Rows 9 and 10 are a **gaze compass**, not a rotation of the character. A previous attempt failed
because the whole sprite rotated until the pet showed her back. Do not repeat that.

- The torso, shoulders, hips, skirt, arms, legs, and feet keep the **same front-facing
  registration as the canonical base in all 16 cells**. The body never spins.
- **Both eyes stay visible in every cell.** The face surface always stays toward the camera. If a
  cell shows only one eye, or the back of the head, or a full side profile, that cell fails.
- A direction is expressed only by: pupil/iris position inside the eye white, eyelid aperture,
  eyebrow position, a **small head yaw of at most about 20 degrees** or a small head pitch, and a
  small upper-body lean. Nothing else moves.
- Screen-left and screen-right are shown by the pupils and the nose direction shifting toward that
  screen edge while the face stays broadly toward the camera.
- Up and down are shown by the pupils moving to the top or bottom of the eye, plus head pitch and
  eyelid change.
- **Explicitly forbidden:** profile views, three-quarter body turns, back views, silhouette flips,
  turning the head past roughly 20 degrees, or any cell where the pet appears to have turned
  around or to be facing away.
- Self-check before returning: if any cell shows one eye only, shows the back of the head, or could
  be mistaken for the character having turned around, that cell fails and the row must be redrawn.

## Hard prohibitions

- Never rotate, skew, or tilt the whole sprite to fake a direction.
- Never add replacement or googly eyes, labels, degree numbers, arrows, clocks, grids, or guide
  marks.
- Never stretch the skull, brows, mouth, hoodie, hands, or face spacing to force a direction to
  read; no non-rigid raster warping of facial features.
- Never change identity, silhouette, palette, materials, markings, hairstyle, or clothing between
  cells.
- Keep the background flat pure magenta #FF00FF and keep magenta out of the pet itself.
- Every one of the 16 directions must be unmistakable at 192x208 without reading any label.
