# Failed source and QA observations

- Generator: built-in OpenAI image_gen, `transparent_background: false`.
- Original output: `/Users/ghostxmerlin/.codex/generated_images/01a1578b-fcb9-74e0-95a2-562ce45aef0a/exec-ca3cafe1-d5e6-4d90-afce-c410a18bbb24.png`.
- Selected exact copy: `decoded/failed.png`, 2172×724.
- Actual prompt: `qa/rows/failed/prompt-used.md`.
- References: `reference-01.png`, `canonical-base.png`, `layout-guides/failed.png`, approved `decoded/waiting.png`.
- Official extraction: `extract_strip_frames.py --method components --chroma-key '#00FFFF'`, succeeded.
- Official inspection: `inspect_frames.py --require-components`, `ok: true`, no errors or warnings; eight 192×208 frames. All frames have zero edge pixels. See `review.json`.

Visual observations: eight complete lying white cat+signal pairs. Cat progresses from awake to outward-folded ears, drooping brows/eyelids, lowered chin on forepaws, brief closed-eye slump, and slight recovery. The downturned expression and flattened ears distinguish it from contented idle sleep. Signal remains fixed at screen right; red top lens glows and green middle/blue bottom lenses stay dark. No tears, punctuation, smoke, stars or added props. Tail/body changes are subtle; the clear motion is in ears, brows, eyelids and head height.

Cyan fringe remains for the parent's planned final one-time despill. Official `chroma_adjacent_pixels` ranges from 192 to 300 per frame; source top-left RGB is 4,250,252. No manual retouching or final visual acceptance was applied by this agent.
