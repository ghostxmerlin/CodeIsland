"""Package imagegen artwork by extraction, fitting and alpha compositing only.

No cat, signal, lens or lighting pixels are drawn procedurally.
Requires Pillow and numpy. Paths are relative to this script.
"""
from pathlib import Path
import hashlib
import json

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent
CANVAS = (1600, 1120)
OFFSET = (32, 48)
LENSES = {
    "red": (1266, 114, 1413, 267),
    "green": (1268, 329, 1410, 477),
    "blue": (1267, 540, 1409, 691),
}


def cleared(image):
    pixels = np.array(image.convert("RGBA"))
    pixels[pixels[:, :, 3] == 0] = 0
    return Image.fromarray(pixels)


def save(image, path):
    path = ROOT / path
    path.parent.mkdir(parents=True, exist_ok=True)
    cleared(image).save(path, optimize=True)


def padded(image):
    result = Image.new("RGBA", CANVAS)
    result.alpha_composite(image, OFFSET)
    return result


def runs(values):
    edges = np.diff(np.r_[False, values, False].astype(int))
    return list(zip(np.where(edges == 1)[0], np.where(edges == -1)[0]))


base = cleared(Image.open(ROOT / "source/base-tall.png"))
assert base.size == (1536, 1024), "Recheck registration after a source revision"
pixels = np.array(base)
cat = pixels.copy()
signal = pixels.copy()
for y in range(base.height):
    gaps = runs(pixels[y, 1080:1260, 3] == 0)
    start, end = max(gaps, key=lambda pair: pair[1] - pair[0])
    assert end - start >= 5, f"No clean cat/signal separation at row {y}"
    seam = 1080 + (start + end) // 2
    cat[y, seam:] = 0
    signal[y, :seam] = 0
cat = padded(Image.fromarray(cat))
signal = padded(Image.fromarray(signal))
assert np.array_equal(
    np.array(Image.alpha_composite(cat, signal)),
    np.array(padded(base)),
), "Layer split must preserve every visible source pixel"

crop_metadata = {}


def extract_lenses(filename):
    strip = cleared(Image.open(ROOT / "source" / filename))
    alpha = np.array(strip)[:, :, 3]
    occupied = (alpha > 2).any(axis=0)
    groups = [(a, b) for a, b in runs(occupied) if b - a > 100]
    assert len(groups) == 3, f"Expected three separated lenses in {filename}"
    result = {}
    boxes = {}
    for color, (left, right) in zip(LENSES, groups):
        selected = strip.crop((left, 0, right, strip.height))
        bbox = selected.getchannel("A").point(lambda value: 255 if value > 2 else 0).getbbox()
        box = (left + bbox[0], bbox[1], left + bbox[2], bbox[3])
        lens = strip.crop(box)
        x0, y0, x1, y1 = LENSES[color]
        lens = lens.resize((x1 - x0, y1 - y0), Image.Resampling.LANCZOS)
        full = Image.new("RGBA", CANVAS)
        full.alpha_composite(lens, (x0 + OFFSET[0], y0 + OFFSET[1]))
        result[color] = full
        boxes[color] = [int(value) for value in box]
    crop_metadata[filename] = boxes
    return result


off = extract_lenses("lamp-lenses-off.png")
on = extract_lenses("lamp-lenses.png")
for overlay in off.values():
    signal = Image.alpha_composite(signal, overlay)
master = Image.alpha_composite(signal, cat)
save(cat, "layers/cat.png")
save(signal, "layers/signal-off.png")
save(master, "master.png")
save(master, "states/offline.png")
state_names = {"blue": "idle-blue", "green": "working-green", "red": "attention-red"}
for color, overlay in on.items():
    save(overlay, f"layers/light-{color}.png")
    save(Image.alpha_composite(master, overlay), f"states/{state_names[color]}.png")

manifest = {
    "name": "White Cat Signal",
    "format": "codeisland-layered-png-v1",
    "canvas": {"width": CANVAS[0], "height": CANVAS[1], "mode": "RGBA", "origin": "top-left"},
    "recommendedDisplay": {"widthPoints": 400, "heightPoints": 280, "fit": "contain"},
    "master": "master.png",
    "layers": {
        "cat": "layers/cat.png",
        "signal": "layers/signal-off.png",
        "lights": {color: f"layers/light-{color}.png" for color in LENSES},
        "drawOrder": ["signal", "cat", "one active light, if connected"],
    },
    "anchors": {
        "catBottomCenter": [640, 1068],
        "signalBottomCenter": [1348, 1052],
    },
    "visibleBounds": {
        "cat": list(cat.getchannel("A").point(lambda value: 255 if value > 16 else 0).getbbox()),
        "signal": list(signal.getchannel("A").point(lambda value: 255 if value > 16 else 0).getbbox()),
    },
    "visibleBoundsAlphaThreshold": 16,
    "lampOrderTopToBottom": ["red", "green", "blue"],
    "lampOverlayRects": {
        color: [x0 + OFFSET[0], y0 + OFFSET[1], x1 - x0, y1 - y0]
        for color, (x0, y0, x1, y1) in LENSES.items()
    },
    "states": {
        "idle": {"image": "states/idle-blue.png", "light": "blue"},
        "processing": {"image": "states/working-green.png", "light": "green"},
        "running": {"image": "states/working-green.png", "light": "green"},
        "waitingApproval": {"image": "states/attention-red.png", "light": "red"},
        "waitingQuestion": {"image": "states/attention-red.png", "light": "red"},
    },
    "noSessionOrDisconnected": {"image": "states/offline.png", "light": None},
    "animation": {
        "bakedCatFrames": False,
        "previewGif": "preview/states.gif",
        "previewMeaning": "Static-art status switching only; not a cat animation.",
    },
    "generation": {"engine": "OpenAI built-in image_gen", "applicationIntegrated": False},
    "sourceRegistration": {"offset": list(OFFSET), "lensCrops": crop_metadata},
}

font_path = "/System/Library/Fonts/Supplemental/Arial.ttf"
font = ImageFont.truetype(font_path, 22)
small_font = ImageFont.truetype(font_path, 17)
labels = [
    ("idle-blue", "IDLE / BLUE"),
    ("working-green", "WORKING / GREEN"),
    ("attention-red", "NEEDS YOU / RED"),
    ("offline", "DISCONNECTED / OFF"),
]
preview = Image.new("RGB", (1600, 640), "#e9e7e1")
draw = ImageDraw.Draw(preview)
draw.text((26, 15), "WHITE CAT + TALL RAILWAY SIGNAL", font=font, fill="#23252c")
for index, (state, label) in enumerate(labels):
    artwork = Image.open(ROOT / f"states/{state}.png").convert("RGBA").resize((400, 280), Image.Resampling.LANCZOS)
    for row, background in enumerate(["#e9e7e1", "#30343c"]):
        tile = Image.new("RGBA", (400, 280), background)
        tile.alpha_composite(artwork)
        preview.paste(tile.convert("RGB"), (index * 400, 72 + row * 280))
    draw.text((index * 400 + 20, 46), label, font=small_font, fill="#333740")
preview.save(ROOT / "preview/states.png", optimize=True)

gif_frames = []
for state, label in labels:
    frame = Image.new("RGBA", (600, 460), "#30343c")
    art = Image.open(ROOT / f"states/{state}.png").convert("RGBA").resize((600, 420), Image.Resampling.LANCZOS)
    frame.alpha_composite(art, (0, 36))
    ImageDraw.Draw(frame).text((24, 12), label, font=font, fill="#f5f6f8")
    gif_frames.append(frame.convert("RGB"))
gif_frames[0].save(
    ROOT / "preview/states.gif", save_all=True, append_images=gif_frames[1:],
    duration=1600, loop=0, disposal=2,
)

assets = ["master.png", "states/offline.png", *[f"states/{name}.png" for name in state_names.values()],
          "layers/cat.png", "layers/signal-off.png", *[f"layers/light-{color}.png" for color in LENSES]]
checks = []
base_array = np.array(master)
for name in assets:
    image = Image.open(ROOT / name)
    arr = np.array(image)
    assert image.mode == "RGBA" and image.size == CANVAS
    assert not arr[:24, :, 3].any() and not arr[-24:, :, 3].any()
    assert not arr[:, :24, 3].any() and not arr[:, -24:, 3].any()
    assert not arr[arr[:, :, 3] == 0, :3].any()
    checks.append({
        "file": name, "sha256": hashlib.sha256((ROOT / name).read_bytes()).hexdigest(),
        "sizeBytes": (ROOT / name).stat().st_size,
        "transparentPixelFraction": float((arr[:, :, 3] == 0).mean()),
    })
for color, state in state_names.items():
    image = np.array(Image.open(ROOT / f"states/{state}.png"))
    mask = np.array(on[color])[:, :, 3] > 0
    assert np.array_equal(image[~mask], base_array[~mask]), f"{color}: unexpected off-lamp changes"
    assert np.array_equal(np.array(Image.alpha_composite(master, on[color])), image)

(ROOT / "pet-manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
(ROOT / "validation.json").write_text(json.dumps({
    "format": manifest["format"],
    "structuralChecksPassed": True,
    "checks": [
        "RGBA and common 1600x1120 canvas",
        "24px outer transparent safety border",
        "zero hidden RGB under fully transparent pixels",
        "source cat/signal split exactly reconstructs original visible pixels",
        "each lit state changes only its corresponding generated lamp overlay",
        "saved state images equal documented layer composition",
    ],
    "scope": "Local asset checks, not ChatGPT Pets v2 validation or application integration testing",
    "assets": checks,
}, indent=2) + "\n")
print(json.dumps({"canvas": CANVAS, "assets": len(assets), "checksPassed": True, "bounds": manifest["visibleBounds"]}))
