Create one horizontal animation strip for Codex pet `aemeath`, state `idle`.

Use the attached canonical base for identity. Use the attached layout guide only for slot count, spacing, centering, and padding; do not draw the guide.

Output exactly 6 full-body frames in one left-to-right row on flat pure magenta #FF00FF. Treat the row as 6 invisible equal-width slots: one centered complete pose per slot, Scale every pose down so it fills only about 60 to 70 percent of its slot width and about 80 percent of the row height, leaving a continuous vertical band of empty pure magenta at least 15 percent of the slot width on BOTH sides of each pose. Neighboring poses must never touch, overlap, share any pixel, or let hair, clothing, or props cross into the next slot; keep a full-height empty magenta gap between every pair of poses. No clipping, empty slots, labels, or borders.

Identity: same pet in every frame: Wuthering Waves Aemeath-inspired humanoid mascot: super-deformed Q-version chibi female hero (oversized head about 40 percent of the full figure height, roughly 2.5 heads tall, short stubby arms and legs, small torso), long pastel-pink hair with soft side locks, small compact translucent cyan crystal hair clips sitting flat against the hair (tiny clip-sized ornaments only, never large wings, never oversized headpieces), warm amber-gold eyes, fair skin, white-and-navy hero dress with gold trim, white gloves, navy chest bow with a small gem, white thigh-high stockings, calm friendly face, soft cyan glow accents but no detached effects. Keep feet grounded, silhouette readable, no weapons, no text, no logos.. Preserve silhouette, face, proportions, markings, palette, material, style, and props.
Style: Pet-safe sprite: compact full-body mascot, readable in a 192x208 cell, clear silhouette, simple face, stable palette/materials, and crisp edges for chroma-key extraction. Style `sticker`: Polished sticker mascot with bold clean shapes, crisp outline, flat colors, and minimal highlight detail. User style notes: Clean 2D anime chibi illustration, bold uniform dark outline, flat cel shading with only two or three tone steps, large expressive amber eyes with star-shaped highlights, soft pink blush marks, crisp flat color fills, no 3D render, no glossy plastic highlight, no soft gradient, no photorealism..
Animation continuity: keep apparent pet scale and baseline stable within the row unless the state itself intentionally changes vertical position, such as `jumping`. Move the pose within the slot instead of redrawing the pet larger or smaller frame to frame.

State action: Calm low-distraction resting loop: subtle breathing, tiny blink, slight head/body bob, and only quiet persona-preserving motion.

State requirements:
- CRITICAL: idle is the low-distraction baseline state and the first frame is also used as the reduced-motion static pet.
- Use only subtle idle motion: gentle breathing, a tiny blink, a slight head or body bob, a very small material sway, or another quiet motion that fits the pet persona.
- Keep the pet essentially in the same pose, facing direction, silhouette, markings, palette, and prop state across all 6 frames.
- Idle variation must stay calm but still read as animation; do not repeat effectively identical copies across the loop.
- Do not show waving, walking, running, jumping, talking, working, reviewing, emotional reactions, large gestures, item interactions, or new props.
- Feet, base, body, or object anchor should remain planted or nearly planted.
- The first and last frames should be very close visually so the loop feels calm and does not pop.

Clean extraction: crisp opaque edges, safe padding, no scenery, text, guide marks, checkerboard, shadows, glows, motion blur, speed lines, dust, detached effects, stray pixels, or chroma-key colors inside the pet.
