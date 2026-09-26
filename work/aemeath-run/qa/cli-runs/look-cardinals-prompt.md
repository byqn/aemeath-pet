Create one horizontal four-cardinal anchor strip for Codex pet `aemeath`.

Use the attached canonical base, completed standard contact sheet, and layout guide for exact identity, style, scale, baseline, face construction, materials, palette, markings, props, and spacing. Read `qa/look-mechanics.md` and use the pet's natural gaze mechanism.

Output exactly four centered complete full-body poses in this exact left-to-right order: `000 up`, `090 screen-right`, `180 down`, `270 screen-left`. Screen-left and screen-right always mean the viewer's image edges, never the character's own left or right.

For `000`, keep the face broadly frontal and point the eyes and natural head mechanism toward the TOP edge. For `090`, put the nose tip, pupils, face surface, or natural aiming feature on the screen-right side of the head center. For `180`, keep the face broadly frontal and point toward the BOTTOM edge. For `270`, apply the inverse screen-left landmark rule. Every cardinal must be unmistakable without labels.

Place one pose in each invisible equal-width slot on a flat pure magenta #FF00FF background with generous padding. Keep scale, feet/base, lower body, and registration consistent across all four slots.

Do not rotate, skew, or tilt the whole sprite to fake gaze. Do not add replacement eyes, labels, degree text, arrows, boxes, guide marks, shadows, scenery, detached effects, or chroma-key colors inside the pet.

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
