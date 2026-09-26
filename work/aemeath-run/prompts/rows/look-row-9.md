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

- The canvas holds 8 slots of 192 pixels each. Each pose — including all hair — must be at most 120 pixels wide (about 60 percent of its slot), with at least 36 pixels of empty magenta on each side inside its own slot and at least 40 pixels of pure magenta between neighbouring poses.
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