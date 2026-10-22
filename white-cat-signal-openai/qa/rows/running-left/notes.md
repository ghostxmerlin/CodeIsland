# Running-left source and QA observations

- Generator: built-in OpenAI image_gen, `transparent_background: false`.
- Original output: `/Users/ghostxmerlin/.codex/generated_images/01a1578b-fcb9-74e0-95a2-562ce45aef0a/exec-447b4e9f-041e-46cd-ade8-db90e481024f.png`.
- Selected exact copy: `decoded/running-left.png`, 2172×724.
- Actual prompt: `qa/rows/running-left/prompt-used.md`.
- References: `reference-01.png`, `canonical-base.png`, `layout-guides/running-left.png`, accepted `decoded/running-right.png`.
- Official extraction: `extract_strip_frames.py --method components --chroma-key '#00FFFF'`, succeeded.
- Official inspection: `inspect_frames.py --require-components`, `ok: true`, no errors or warnings; eight 192×208 frames. All frames have zero edge pixels. See `review.json`.

Visual observations: all eight frames contain one complete cat and one complete signal. Cats face screen left through head, torso, hips, paw reach and hind-leg placement, with visibly extended and gathered gait poses. Signal stays on screen right, retaining its rigid orientation, red top/green middle/blue bottom lamp order and illuminated blue bottom lens. Cat appearance and eye design follow the accepted rightward strip. No whole-scene mirroring was used.

Cyan fringe remains for the parent's planned final one-time despill. Official `chroma_adjacent_pixels` ranges from 312 to 373 per frame; generated backdrop is near-cyan (top-left RGB 4,250,252), not exact constant #00FFFF. No manual retouching or final visual acceptance was applied by this agent.
