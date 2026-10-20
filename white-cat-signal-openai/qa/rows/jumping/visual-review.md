# Jumping row review

- Built-in imagegen generated decoded/jumping.png from reference-01, canonical-base, official five-slot jumping guide, and accepted idle.png. Exactly five complete cat+signal pairs.
- Visually inspected the generated source plus all five extracted frames. Pure white broad cat, round face, long wrapped tail, warm closed eyes, and slender vintage screen-right signal remain recognizable. Signal's full base follows the jump. Bottom blue lamp stays lit; top red and middle green remain dim.
- Ordered semantics: anticipation lying low; whole pair rises; clear whole-pair apex; descent; settle on starting baseline. Cat remains compact rather than standing upright. Paw pose changes are gentle; the strong vertical displacement supplies the principal hop motion.
- Source pair bottom bounds from official extraction functions: [564,511,476,510,564], peak lift 88 source pixels. Source pair bbox heights [321,313,315,312,321] preserve apparent scale without shrinking the apex.
- Official extract_strip_frames.py returned ok:true using components and cyan '#00FFFF'. Official inspect_frames.py returned ok:true, errors:[], warnings:[].
- Extracted bottoms: [203,178,161,178,203], peak lift 42 pixels, first/last exact match. Full numeric source and extracted bounds are in geometry.json.
- Final-gate risk requiring parent assembly attention: current isolated idle extraction bottoms are 187, so this isolated row's landing is 16 pixels lower than idle. The final gate default maximum is 12. Do not waive it. This is row-wide viewport registration caused by the real apex movement; source frame1/frame5 are aligned. Apex extracted top is 5 pixels, so a simple upward shift would clip; use parent-level shared scale/baseline registration preserving vertical displacement rather than per-frame fitting.
- Same official render_animation_previews.py module's load_frames/save_preview functions generated previews/jumping.gif with its built-in state durations. Full CLI requires all nine states and is reserved for parent assembly. No substitute compositor or invented visuals were used.
- Cyan edge fringe still needs the one final official despill pass.
