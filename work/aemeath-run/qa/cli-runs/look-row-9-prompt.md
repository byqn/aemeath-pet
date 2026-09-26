Create one horizontal look-direction strip for Codex pet `aemeath`, atlas row 9.

Use the attached canonical base, completed standard contact sheet, layout guide, and approved four-cardinal strip for identity, scale, registration, spacing, direction semantics, and cross-row continuity. Read `qa/look-mechanics.md` and follow its pet-specific movement and eye/prop mechanics. The approved cardinal strip is authoritative for the up, screen-right, down, and screen-left pose families. Interpolate the intermediate directions as even 22.5-degree steps between those anchors.

GAZE COMPASS LOCK — read this before anything else. This row is NOT a rotation of the character. The pet NEVER turns her body away from the viewer. The torso, shoulders, hips, skirt, arms, legs, and feet stay in exactly the same front-facing registration in all eight cells, and BOTH eyes stay visible in every cell. A previous attempt failed because the whole sprite rotated until the pet showed her back: do not repeat that. Any cell showing a side profile, a three-quarter body turn, the back of the head, or only one visible eye is wrong and must not be drawn.

The only things that may change between cells: pupil/iris position inside the eye white, eyelid aperture, eyebrows, a small head yaw of at most about 20 degrees or a small head pitch, and a subtle upper-body lean.

Per-cell gaze target — all eight cells stay front-facing with an unrotated body:

- `000` — pupils at the TOP of the eye white, upper eyelids lifted, chin slightly raised: looking UP.
- `022.5` — pupils high and a little toward the viewer's right.
- `045` — pupils in the upper-right diagonal of the eye white.
- `067.5` — pupils toward the viewer's right and slightly above centre; nose direction leans right.
- `090` — pupils at the RIGHT edge of the eye white, clearly past the centre line; nose direction clearly toward the viewer's right.
- `112.5` — pupils toward the viewer's right and slightly below centre.
- `135` — pupils in the lower-right diagonal of the eye white.
- `157.5` — pupils near the BOTTOM of the eye white and still slightly toward the viewer's right, upper eyelids lowered: almost looking DOWN, never facing away.

SLOT SPACING LOCK — a previous attempt failed because the first three poses touched each other, so the deterministic cropper could only find 6 separated groups instead of 8. Every pair of neighbouring poses must be separated by a continuous vertical band of pure magenta that runs the FULL height of the canvas, with no hair, sleeve, skirt, or outline ever crossing it.

- Each pose may occupy at most about 65 percent of its slot width and about 80 percent of the canvas height.
- Leave at least a quarter of each slot width as empty magenta, split evenly on the left and right of the pose.
- Long hair must be drawn tucked in and compact; it may never extend sideways into the neighbouring slot.
- No pose may overlap, touch, or share any pixel with its neighbour.

COHERENT SYNTHESIS LOCK: produce one unified eight-pose row. Do not paste, tile, or independently restyle individual cells. Every final cell must be drawn together with the same face construction, body proportions, line/render quality, lighting, materials, scale, baseline, and registration.

Output exactly 8 complete full-body frames in this exact left-to-right order: 000, 022.5, 045, 067.5, 090, 112.5, 135, 157.5. Degrees are clockwise: 000 is up, 090 right, 180 down, and 270 left. Neutral/front is not part of this row.

DIRECTION TARGETS — use these to shape the coherent row, not as pixel-level landmark gates:

1. `000`: vertical UP; no horizontal requirement.
2. `022.5`: horizontal SCREEN-RIGHT and vertical UP.
3. `045`: horizontal SCREEN-RIGHT and vertical UP.
4. `067.5`: horizontal SCREEN-RIGHT and vertical UP.
5. `090`: horizontal SCREEN-RIGHT; no vertical requirement.
6. `112.5`: horizontal SCREEN-RIGHT and vertical DOWN.
7. `135`: horizontal SCREEN-RIGHT and vertical DOWN.
8. `157.5`: horizontal SCREEN-RIGHT and vertical DOWN.

Cardinals must be unmistakable. Intermediate poses should broadly occupy the intended quadrant and advance naturally through the ordered loop. Minor pupil, nose, eyelid, or aiming-feature deviations are acceptable when the overall direction, continuity, identity, and motion remain coherent. Do not deform the character merely to make every intermediate axis independently obvious.

SCREEN-COORDINATE LOCK: screen-right means the viewer's right image edge, never the character's own right. The row should travel naturally through the right half of the loop. Near-vertical 022.5 and 157.5 may have subtle horizontal cues; prioritize a coherent arc over exact pupil or nose placement.

HARD LAYOUT AND CONTINUITY CONTRACT — DETERMINISTIC REGISTRATION: draw exactly eight separated pose groups in left-to-right direction order. Keep enough chroma-only space between neighboring poses that each complete pose can be detected without cutting through foreground. Approximate the guide's equal spacing, but do not distort a pose merely to hit an exact source-canvas coordinate; deterministic assembly will crop the eight ordered groups, then apply one shared scale and baseline.

Use the same body height, head size, baseline, and planted-body position across the generated family. Never overlap neighboring poses, merge two poses into one connected group, crop foreground at the outer canvas edge, or resize one pose independently.

Keep the feet, base, or lower torso planted at the same coordinates across all eight frames. Express direction through the eyes, face, head, upper body, and physically appropriate prop movement, not by moving, rotating, or rescaling the entire sprite.

Place one centered pose in each invisible equal-width slot on flat pure magenta #FF00FF. Change only the natural parts needed to express gaze: eyes, eyelids, head, face, neck, upper body, appendages, and constrained prop follow-through. Keep identity, silhouette, materials, palette, markings, and props consistent.

ROW-BOUNDARY LOCK: 157.5 must be one even 22.5-degree step before 180. Match the approved 180 pose's body size, baseline, planted anchor, expression, and construction. Preserve the overall right-hand arc, but do not distort pupils, nose, or body geometry merely to exaggerate the subtle horizontal component.

PRE-RETURN CHECK: reject this result if it does not contain eight separated pose groups in the required order; neighboring poses overlap; foreground is cropped at the outer canvas edge; any frame changes sprite scale, body or head size, baseline, or planted-body position; the row visibly reverses into the wrong half of the loop; or 157.5 does not flow evenly into 180. Minor intermediate pupil or nose deviations are not rejection reasons. Exact cell cropping, resizing, and recentering happen deterministically after generation.

Do not rotate, skew, or tilt the whole sprite to fake gaze. Do not add replacement/googly eyes, labels, degree text, arrows, clocks, grids, shadows, glows, scenery, detached effects, or chroma-key colors inside the pet.

PET-SPECIFIC LOOK MECHANICS (authoritative):
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
