# Running-right generation prompt

Built-in OpenAI image_gen; transparent_background=false.
Reference order: reference-01.png (approved character appearance); canonical-base.png (canonical identity); layout-guides/running-right.png (8-slot spacing only).

Create one horizontal animation strip for ChatGPT pet `white-cat-signal`, state `running-right`.

Input image 1 is the approved pet appearance reference. Image 2 is the canonical identity. Image 3 is the 8-slot layout guide for spacing only; do not draw guide marks.

Output exactly 8 full-body frames in one left-to-right row on flat pure cyan #00FFFF. Treat the row as 8 invisible equal-width slots: one centered complete pose per slot, evenly spaced, with no overlap, clipping, empty slots, labels, or borders.

Identity: same pet in every frame: Default is a plump sleeping white cat lying to the left of a tall railway signal. Signal stays on SCREEN RIGHT in every animation and look pose, height about 1.6 times resting cat height, exactly red top green middle blue bottom. The pair is one compact pet identity; no cushion or extra props. Blue light idle and look directions, green working and review, red failed and waiting. Keep entire cat and signal within every frame with generous padding. Eyes when awake are natural small dark feline eyes, not googly. Cardinal gaze changes head/nose/ears naturally while the lying body and signal stay anchored. Jumping must visibly lift the entire pair above baseline then land, with cat doing a small cheerful hop and signal accompanying the mascot as a floating magical prop for that short action; no detached effects. Running-left must not mirror the signal placement. Preserve silhouette, face, proportions, markings, palette, material, style, and props.

Style: Pet-safe sprite: compact full-body mascot, readable in a 192x208 cell, clear silhouette, simple face, stable palette/materials, and crisp edges for chroma-key extraction. Style `painterly`: Painterly mascot with simplified brush texture, readable forms, stable palette, and enough edge clarity for clean extraction. User style notes: Approved softly hand-painted fluffy pure-white cat, delicate charcoal pencil contours and gentle Japanese fantasy-animation charm. Keep the exact face, ears, long wrapped tail, white fur, and tall vintage charcoal railway signal from the reference.

Animation continuity: keep apparent pet scale and baseline stable within the row unless the state itself intentionally changes vertical position, such as `jumping`. Move the pose within the slot instead of redrawing the pet larger or smaller frame to frame.

State action: Dragging-right loop: show directional movement to the right through body and limb poses only.

State requirements:
- Show directional drag movement to the right through body, limb, and prop movement only.
- The row must unmistakably face and travel right.
- The movement cadence must alternate visibly across the 8 frames instead of repeating one nearly static stride.
- Do not draw speed lines, dust clouds, floor shadows, motion trails, or detached motion effects.

Clean extraction: crisp opaque edges, safe padding, no scenery, text, guide marks, checkerboard, shadows, glows, motion blur, speed lines, dust, detached effects, stray pixels, or chroma-key colors inside the pet.

Production clarifications for this row: This is exactly EIGHT complete CAT-PLUS-SIGNAL PAIRS, never eight individual objects. Each group contains exactly one cat on the LEFT and one tall signal immediately to the cat's SCREEN RIGHT, with a narrow internal gap; leave a WIDE empty cyan gap between adjacent complete pairs. All eight cats face SCREEN RIGHT and keep their plump fluffy body, recognizable approved small pink nose, small natural eyes, triangular pink inner ears, soft white fur and long fluffy tail. In this movement row the cat rises into a small four-legged walking/trotting gait. Show eight successive distinct phases: right-front paw forward / weight shift / paw pass / left-front paw forward / opposing weight shift / rear paw pass / recovery / loop-ready contact. The four legs alternate, keeping a low round-bodied silhouette. Cat and signal bases share a stable ground baseline. The signal remains tall and the SAME rigid geometry in every frame, always on the cat's SCREEN RIGHT, never duplicated, never shifted to the left. Blue bottom lamp is lit in all eight frames; top red and middle green lenses are unlit. No cyan inside the cat or signal. Background is truly solid RGB(0,255,255) throughout, including the generous safe outer padding. The output is a wide single row, not a grid and not two rows. Do not include reference image backgrounds or guide marks. Preserve the original warm hand-painted detail and full-body readability.
