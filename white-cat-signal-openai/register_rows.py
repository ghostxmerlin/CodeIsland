"""Register officially extracted rows, keeping one transform per whole row.

This only fits existing generated pixels. Official extraction, inspection and
atlas composition remain authoritative. Original frames stay untouched.
"""
from pathlib import Path
from statistics import median
import json
from PIL import Image

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "frames-extracted"
DEST = ROOT / "frames"
BASELINE = 190
manifest = json.loads((SOURCE / "frames-manifest.json").read_text())


def bbox(image):
    return image.getchannel("A").point(lambda value: 255 if value > 16 else 0).getbbox()


rows = []
target_height = 138.0
for row in manifest["rows"]:
    files = sorted((SOURCE / row["state"]).glob("*.png"))
    images = [Image.open(path).convert("RGBA") for path in files]
    bounds = [bbox(image) for image in images]
    ground = max(b[3] for b in bounds) if row["state"] == "jumping" else round(median(b[3] for b in bounds))
    reference_height = bounds[0][3] - bounds[0][1]
    max_width = max(b[2] - b[0] for b in bounds)
    total_rise = ground - min(b[1] for b in bounds)
    target_height = min(target_height, reference_height * 180 / max_width, reference_height * 184 / total_rise)
    rows.append((row, files, images, bounds, ground, reference_height))

report = {"baseline": BASELINE, "referenceSignalHeight": target_height, "rows": []}
for row, files, images, bounds, ground, reference_height in rows:
    scale = target_height / reference_height
    size = (round(192 * scale), round(208 * scale))
    # The signal is the rightmost fixed prop. Register that prop rather than
    # the changing overall cat silhouette, using the same offset for the row.
    x = 184 - round(max(bound[2] for bound in bounds) * scale)
    y = round(BASELINE - ground * scale)
    destination = DEST / row["state"]
    destination.mkdir(parents=True, exist_ok=True)
    outputs = []
    registered_bounds = []
    for image, path in zip(images, files):
        fitted = Image.new("RGBA", (192, 208))
        fitted.alpha_composite(image.resize(size, Image.Resampling.LANCZOS), (x, y))
        bound = bbox(fitted)
        assert bound and bound[0] >= 3 and bound[1] >= 3 and bound[2] <= 189 and bound[3] <= 205, (row["state"], bound)
        output = destination / path.name
        fitted.save(output)
        outputs.append(str(output))
        registered_bounds.append(list(bound))
    row["frames"] = outputs
    row["registration"] = {"scale": scale, "translation": [x, y], "sameTransformForEveryFrame": True}
    report["rows"].append({
        "state": row["state"], "sourceBaseline": ground,
        "sourceReferenceHeight": reference_height, **row["registration"],
        "bounds": registered_bounds,
    })
DEST.mkdir(parents=True, exist_ok=True)
(DEST / "frames-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
(ROOT / "qa/row-registration.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
