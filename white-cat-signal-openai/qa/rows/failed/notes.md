# Failed source and QA observations — selected revision 04

- Generator: built-in OpenAI image_gen, `transparent_background: false`.
- Selected generated output: `/Users/ghostxmerlin/.codex/generated_images/01a1578b-fcb9-74e0-95a2-562ce45aef0a/exec-520f0fb8-e03f-45b2-b49d-46f3ca9fc65f.png`.
- Exact copies: `decoded/failed.png` and `qa/rows/failed/revision-04.png`, 2172×724.
- Current exact prompt: `qa/rows/failed/prompt-revision-04.md`.
- References: original failed strip, approved `decoded/idle.png`, approved `decoded/waiting.png`, canonical base, eight-slot failed guide.
- Revision 01 source, notes and inspection were preserved. Revisions 02 and 03 were kept as unselected candidates with exact prompt records.
- Official extraction: `extract_strip_frames.py --method components --chroma-key '#00FFFF'`, succeeded.
- Official inspection: `inspect_frames.py --require-components`, `ok: true`, no errors or warnings; eight 192×208 frames. All frames have zero edge pixels. See `review.json`.

The correction reduces the whole source group scale to leave enough horizontal space for the full plump cat. It preserves the eight-step awake → outward-folded ears → drooping brow/eyelids → chin on forepaws → closed-eye slump → slight recovery sequence. Signals stay at screen right with the red top lens lit and green/blue lenses dark. No tears, punctuation, smoke, stars or props were added.

Read-only first-frame measurement proxy: largest bright neutral connected component represents the cat; the active-lamp center column provides signal cap-to-base height. This is not a semantic segmentation. Revision 04 cat width/signal height is 0.880, versus idle 0.841 and waiting 0.824; full pair width/signal height is 1.083, versus idle 1.087 and waiting 1.066. Thus cat width after signal normalization is about 4.6% above idle and 6.8% above waiting, with matched whole-pair width. The cat-height proxy remains higher at 0.585 versus idle 0.502, so this candidate is rounder/taller rather than a perfect geometric match. See `scale-review.json`.

All eight newly extracted frames were visually inspected as ordered stills. No playback claim is made. Parent was asked to assess this selected source before final gate approval; the shared registered frames/atlas were not updated by this agent.

Cyan fringe remains for the parent's planned final one-time despill. Official `chroma_adjacent_pixels` ranges from 222 to 317 per frame. No manual retouching was performed.
