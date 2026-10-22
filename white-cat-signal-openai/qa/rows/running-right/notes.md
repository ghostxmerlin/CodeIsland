# Running-right source and QA observations

- Generator: built-in OpenAI image_gen, `transparent_background: false`.
- Original output: `/Users/ghostxmerlin/.codex/generated_images/01a1578b-fcb9-74e0-95a2-562ce45aef0a/exec-1427aaeb-edc6-4df2-bd68-89106df0a981.png`.
- Selected exact copy: `decoded/running-right.png`, 2172×724.
- Actual prompt: `qa/rows/running-right/prompt-used.md`.
- Official extraction: `extract_strip_frames.py --method components --chroma-key '#00FFFF'`, succeeded.
- Official inspection: `inspect_frames.py --require-components`, `ok: true`, no errors or warnings; eight 192×208 frames. All frames have zero edge pixels. See `review.json`.

Visual observations: eight complete cat+signal pairs, all cats facing screen right, all signals on their own cat's screen right, blue bottom lens lit with red top/green middle unlit. Paw extension and gathered-leg poses alternate, though several frames are similar. Standing cats appear slimmer than the sleeping reference.

Unresolved quality caveat: extracted edges show cyan fringe; official `chroma_adjacent_pixels` ranges from 278 to 382 per frame. The generated backdrop is near-cyan rather than exact constant RGB(0,255,255): sampled top-left RGB(4,249,252), most common RGB(1,252,254). Source and frames are preserved without manual retouching. Mechanical inspection passing does not certify visual acceptance; parent was notified for final QA.
