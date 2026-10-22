#!/usr/bin/env python3
"""Render review media from the exact final OpenAI Pet v2 PNG.

This is a preview adapter, not an atlas compositor or validator. It does not
modify the atlas, fit sprites to bounds, redraw artwork, or clean chroma.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
from types import ModuleType

from PIL import Image, ImageDraw, ImageFont


CELL = (192, 208)
ATLAS_SIZE = (1536, 2288)
STATES = (
    ("idle", 6),
    ("running-right", 8),
    ("running-left", 8),
    ("waving", 4),
    ("jumping", 5),
    ("failed", 8),
    ("waiting", 6),
    ("running", 6),
    ("review", 6),
)
LOOK_DURATIONS = [160] * 16
BACKGROUND = (27, 30, 37, 255)
OFFICIAL_SCRIPTS = (
    Path.home()
    / ".codex/plugins/cache/openai-curated-remote/work-pets"
    / "0.1.6/skills/create-pet/scripts"
)


def official_preview_module(scripts_dir: Path) -> ModuleType:
    """Import the installed official preview implementation without its CLI."""
    path = scripts_dir / "render_animation_previews.py"
    spec = importlib.util.spec_from_file_location("official_pet_previews", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot import official preview script: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for name in ("load_frames", "save_preview", "ROW_DURATIONS"):
        if not hasattr(module, name):
            raise RuntimeError(f"Official preview script is missing {name}")
    return module


def font(size: int = 16) -> ImageFont.ImageFont:
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def crop_final_cells(atlas: Image.Image, frames_root: Path) -> dict[str, list[Path]]:
    """Write exact full-cell RGBA crops; preserve padding and jump displacement."""
    result: dict[str, list[Path]] = {}
    for row, (state, count) in enumerate((*STATES, ("look", 16))):
        state_dir = frames_root / state
        state_dir.mkdir(parents=True, exist_ok=True)
        expected = {f"{index:02d}.png" for index in range(count)}
        unexpected = [
            p.name
            for p in state_dir.iterdir()
            if p.suffix.lower() in {".png", ".webp", ".jpg", ".jpeg"}
            and p.name not in expected
        ]
        if unexpected:
            raise RuntimeError(
                f"Unexpected frame files in {state_dir}; preserve or move them "
                f"before rerunning: {unexpected}"
            )
        paths = []
        for index in range(count):
            source_row = row + index // 8 if state == "look" else row
            column = index % 8
            x, y = column * CELL[0], source_row * CELL[1]
            crop = atlas.crop((x, y, x + CELL[0], y + CELL[1]))
            path = state_dir / f"{index:02d}.png"
            crop.save(path)
            paths.append(path)
        result[state] = paths
    return result


def labeled_frame(
    frame: Image.Image, state: str, index: int, count: int, time_ms: int
) -> Image.Image:
    """Place an unchanged native cell on an explanatory dark preview panel."""
    panel = Image.new("RGBA", (320, 256), BACKGROUND)
    panel.alpha_composite(frame, ((320 - CELL[0]) // 2, 40))
    draw = ImageDraw.Draw(panel)
    draw.text((12, 6), state, font=font(17), fill=(242, 244, 248, 255))
    draw.text(
        (12, 25),
        f"frame {index + 1}/{count}  |  {time_ms / 1000:.2f} s",
        font=font(11),
        fill=(179, 186, 201, 255),
    )
    return panel


def write_evidence(
    frames: dict[str, list[Image.Image]],
    durations: dict[str, list[int]],
    output: Path,
) -> list[dict[str, object]]:
    """Show six labeled final cells without sprite resizing or modification."""
    selections = [
        ("idle", 0),
        ("waiting", 2),
        ("running", 2),
        ("jumping", 2),
        ("failed", 4),
        ("review", 2),
    ]
    sheet = Image.new("RGBA", (320 * 3, 256 * 2), BACKGROUND)
    records = []
    for panel_index, (state, frame_index) in enumerate(selections):
        elapsed = sum(durations[state][:frame_index])
        panel = labeled_frame(
            frames[state][frame_index],
            state,
            frame_index,
            len(frames[state]),
            elapsed,
        )
        sheet.alpha_composite(panel, ((panel_index % 3) * 320, (panel_index // 3) * 256))
        records.append(
            {"state": state, "frame": frame_index, "state_timestamp_ms": elapsed}
        )
    sheet.save(output)
    return records


def main() -> None:
    run_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--atlas", type=Path, default=run_dir / "final/spritesheet-extended.png"
    )
    parser.add_argument("--frames-root", type=Path, default=run_dir / "final-frames")
    parser.add_argument("--output-dir", type=Path, default=run_dir / "preview")
    parser.add_argument("--official-scripts", type=Path, default=OFFICIAL_SCRIPTS)
    parser.add_argument("--ffmpeg", type=Path, default=Path("/opt/homebrew/bin/ffmpeg"))
    parser.add_argument("--mp4-fps", type=int, default=30)
    args = parser.parse_args()
    if not 1 <= args.mp4_fps <= 60:
        parser.error("--mp4-fps must be between 1 and 60")

    atlas_path = args.atlas.expanduser().resolve()
    frames_root = args.frames_root.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    ffmpeg = args.ffmpeg.expanduser().resolve()
    if not ffmpeg.is_file():
        raise SystemExit(f"Required ffmpeg executable is unavailable: {ffmpeg}")
    official = official_preview_module(args.official_scripts.expanduser().resolve())
    encoded = atlas_path.read_bytes()
    atlas_sha = hashlib.sha256(encoded).hexdigest()
    with Image.open(io.BytesIO(encoded)) as opened:
        if opened.format != "PNG" or opened.size != ATLAS_SIZE or opened.mode != "RGBA":
            raise SystemExit(
                f"Expected final RGBA PNG {ATLAS_SIZE}, got "
                f"{opened.format}, {opened.mode}, {opened.size}"
            )
        atlas = opened.copy()
    for state, count in STATES:
        if len(official.ROW_DURATIONS[state]) != count:
            raise SystemExit(f"Official preview duration count changed for {state}")

    paths = crop_final_cells(atlas, frames_root)
    output_dir.mkdir(parents=True, exist_ok=True)
    frames: dict[str, list[Image.Image]] = {}
    durations: dict[str, list[int]] = {}
    outputs: list[dict[str, object]] = []
    for state, count in (*STATES, ("look", 16)):
        frames[state] = official.load_frames(frames_root, state, count)
        durations[state] = (
            list(LOOK_DURATIONS)
            if state == "look"
            else list(official.ROW_DURATIONS[state])
        )
        target = output_dir / ("look-loop.gif" if state == "look" else f"{state}.gif")
        official.save_preview(frames[state], durations[state], target)
        outputs.append(
            {
                "kind": "state-gif",
                "state": state,
                "path": str(target),
                "size": list(CELL),
                "frames": count,
                "durations_ms": durations[state],
                "cycle_duration_ms": sum(durations[state]),
                "loop": "infinite",
                "background": "transparent; GIF uses binary alpha",
            }
        )

    transition_frames = frames["idle"] + frames["jumping"] + frames["idle"]
    transition_durations = (
        durations["idle"] + durations["jumping"] + durations["idle"]
    )
    transition_path = output_dir / "idle-jump-idle.gif"
    official.save_preview(transition_frames, transition_durations, transition_path)
    outputs.append(
        {
            "kind": "transition-gif",
            "path": str(transition_path),
            "size": list(CELL),
            "sequence": ["idle", "jumping", "idle"],
            "frames": len(transition_frames),
            "durations_ms": transition_durations,
            "cycle_duration_ms": sum(transition_durations),
            "loop": "infinite",
            "registration": "native whole-cell crops, no repositioning",
        }
    )

    all_frames = []
    all_durations = []
    timeline = []
    elapsed = 0
    for state, _ in (*STATES, ("look", 16)):
        cycles = 1 if state == "look" else 3
        section_start = elapsed
        for cycle in range(cycles):
            for index, (frame, duration) in enumerate(zip(frames[state], durations[state])):
                all_frames.append(
                    labeled_frame(frame, state, index, len(frames[state]), elapsed)
                )
                all_durations.append(duration)
                elapsed += duration
        timeline.append(
            {
                "state": state,
                "cycles": cycles,
                "start_ms": section_start,
                "end_ms": elapsed,
            }
        )
    all_gif = output_dir / "all-states.gif"
    official.save_preview(all_frames, all_durations, all_gif)
    outputs.append(
        {
            "kind": "all-states-gif",
            "path": str(all_gif),
            "size": [320, 256],
            "frames": len(all_frames),
            "durations_ms": all_durations,
            "cycle_duration_ms": elapsed,
            "timeline": timeline,
            "loop": "infinite",
            "background_rgba": list(BACKGROUND),
        }
    )

    evidence_path = output_dir / "evidence-stills.png"
    selections = write_evidence(frames, durations, evidence_path)
    outputs.append(
        {"kind": "evidence-stills", "path": str(evidence_path), "panels": selections}
    )
    mp4_path = output_dir / "all-states.mp4"
    command = [
        str(ffmpeg), "-hide_banner", "-loglevel", "error", "-y",
        "-ignore_loop", "1", "-i", str(all_gif), "-an",
        "-vf", f"fps={args.mp4_fps}", "-c:v", "libx264",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(mp4_path),
    ]
    subprocess.run(command, check=True)
    outputs.append(
        {
            "kind": "all-states-mp4",
            "path": str(mp4_path),
            "source_gif": str(all_gif),
            "fps": args.mp4_fps,
            "timing": "GIF timeline sampled at the stated constant frame rate",
            "ffmpeg_command": command,
        }
    )

    if hashlib.sha256(atlas_path.read_bytes()).hexdigest() != atlas_sha:
        raise SystemExit("The final atlas changed during rendering; rerun from its final bytes")
    manifest = {
        "schema_version": 1,
        "purpose": "review previews only; not structural or visual acceptance",
        "atlas": {
            "path": str(atlas_path),
            "sha256": atlas_sha,
            "encoded_bytes": len(encoded),
            "size": list(ATLAS_SIZE),
            "mode": "RGBA",
        },
        "cell_size": list(CELL),
        "frame_extraction": "exact decoded RGBA cell crops; no fitting, resizing or despill",
        "frames_root": str(frames_root),
        "frame_counts": {state: len(state_paths) for state, state_paths in paths.items()},
        "frame_paths": {state: [str(p) for p in values] for state, values in paths.items()},
        "look_order_degrees": [index * 22.5 for index in range(16)],
        "official_preview_script": str(
            args.official_scripts.expanduser().resolve() / "render_animation_previews.py"
        ),
        "outputs": outputs,
    }
    manifest_path = output_dir / "preview-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"ok": True, "manifest": str(manifest_path), "atlas_sha256": atlas_sha}, indent=2))


if __name__ == "__main__":
    main()
