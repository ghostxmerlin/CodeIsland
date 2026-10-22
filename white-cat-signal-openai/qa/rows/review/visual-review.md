# Review row visual QA

- Selected built-in imagegen source: decoded/review.png. All manifest identity references and official six-slot guide attached, plus accepted waiting.png for eye design and scale.
- Exactly six complete cat+signal pairs. All six extracted 192x208 PNGs inspected visually after official components extraction.
- Frame 00 alert forward/down gaze; 01 head lowers and leans toward paws with focused narrow eyes; 02 head/nose turn screen-left; 03 head/nose turn screen-right and down; 04 relaxed closed-eye approving blink; 05 returns to initial attentive pose.
- Distinct reviewing semantics through physical head/nose movement and eyelids. No asking raised paw, no kneading, no foot-running, no new props.
- Body remains plump pure-white lying cat with round face, pink nose/ears, natural small dark feline eyes, long wrapped tail. Signal always screen-right, upright and stable, same geometry, red/green/blue vertical order, GREEN middle lamp illuminated only.
- No clipping, overlap, extra limbs, guide marks, text, magnifier/paper/UI or detached effects observed.
- Official extract_strip_frames.py --states review --method components --chroma-key '#00FFFF': ok:true.
- Official inspect_frames.py --states review --require-components: ok:true, errors:[], warnings:[].
- previews/review.gif produced by unmodified official render_animation_previews.py module's load_frames and save_preview with its own durations.
- Isolated row geometry saved to geometry.json; final atlas-scale/baseline harmonization and one official chroma despill remain parent workflow responsibility.
