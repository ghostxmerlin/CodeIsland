# Waving row review

- Selected source: decoded/waving.png; generated using built-in imagegen with all three manifest input images attached (reference-01, canonical-base, four-slot waving layout).
- Exactly four complete cat+signal poses, with stable pair scale and baseline. Cat remains lying; no standing/bipedal pose or extra limbs observed.
- Frames: 00 both paws down, small dark awake eyes; 01 one connected forepaw lifted beside face; 02 same paw tilts outward showing pink pads; 03 paw down and content closed eyes.
- Identity retained: broad fluffy white cat, round face, pink nose/ears, long wrapped tail; vintage tall slender signal always screen-right, red/green/blue vertical order, blue bottom lamp illuminated.
- No clipped body parts, extra props, guide marks, text, motion arcs or detached decorative effects observed.
- Official extraction: extract_strip_frames.py --states waving --method components --chroma-key '#00FFFF' returned ok:true.
- Official inspection: inspect_frames.py --states waving --require-components returned ok:true, errors:[], warnings:[]. Review report: review.json.
- All four extracted 192x208 PNGs were visually inspected. Blue lamp and connected paw gesture remain readable. Some chroma-colored edge fringe remains at this stage; parent final official despill pass is still required.
- Full render_animation_previews.py CLI requires all nine state folders and failed with 'idle preview needs 6 frames, found 0'. No missing states were fabricated. Single-state GIF was made using the same unmodified script's load_frames and save_preview functions and its own waving durations [140,140,140,280].
- make_contact_sheet.py requires an atlas; parent full-row assembly owns that artifact.
