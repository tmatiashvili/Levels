#!/usr/bin/env python3
"""Generate the Levels app icon (Icon Composer `.icon` bundle) from code.

The icon is a thick green ring gauge, about 75% full, around three rising
level bars, on a deep indigo background. It matches the ring gauges the app
and widgets draw (BatteryGauge, WidgetDeviceViews).

Output: one `AppIcon.icon` bundle per app target, written into the target's
synchronized folder so Xcode picks it up with no project change:

    Levels-Mac/AppIcon.icon
    Levels-iOS/AppIcon.icon

Each bundle holds `icon.json` plus flat SVG layers in `Assets/`. The system
applies the shape mask (squircle on macOS and iOS), Liquid Glass, and the
dark, clear and tinted appearances. Shapes are filled paths, not strokes, so
actool renders them the same way Icon Composer does.

Run from the repo root:  python3 design/icon/make_icon.py
Preview (needs Xcode):   design/icon/preview.sh <out.png>
"""

from __future__ import annotations

import json
import math
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ["Levels-Mac", "Levels-iOS"]

CANVAS = 1024
CX = CY = CANVAS / 2

# Ring geometry (canvas points). Thick so it survives 16 px.
RING_RADIUS = 318        # centre line of the ring
RING_WIDTH = 128
LEVEL = 0.75             # fraction of the ring that is filled

# Level bars in the middle: three rounded bars rising left to right.
BAR_WIDTH = 64
BAR_GAP = 34
BAR_HEIGHTS = [118, 196, 274]
BAR_BASELINE = CY + BAR_HEIGHTS[-1] / 2   # bars share a baseline, block centred

GREEN = "#34E37E"
WHITE = "#FFFFFF"

# Background: deep indigo gradient (light) and near-black indigo (dark).
BG_LIGHT = ("srgb:0.20784,0.23137,0.62745,1.00000",   # #353BA0 top
            "srgb:0.05490,0.06275,0.23137,1.00000")   # #0E103B bottom
BG_DARK = ("srgb:0.10196,0.10980,0.27451,1.00000",    # #1A1C46
           "srgb:0.01961,0.02353,0.07843,1.00000")    # #050614


def f(x: float) -> str:
    return f"{x:.2f}".rstrip("0").rstrip(".")


def pt(angle_deg: float, r: float) -> tuple[float, float]:
    """Point on a circle; 0 deg is 12 o'clock, angles grow clockwise."""
    a = math.radians(angle_deg - 90)
    return CX + r * math.cos(a), CY + r * math.sin(a)


def annulus_path() -> str:
    ro, ri = RING_RADIUS + RING_WIDTH / 2, RING_RADIUS - RING_WIDTH / 2

    def circle(r: float, sweep: int) -> str:
        return (f"M {f(CX)} {f(CY - r)} "
                f"A {f(r)} {f(r)} 0 1 {sweep} {f(CX)} {f(CY + r)} "
                f"A {f(r)} {f(r)} 0 1 {sweep} {f(CX)} {f(CY - r)} Z")

    return f"{circle(ro, 1)} {circle(ri, 0)}"


def arc_path(fraction: float) -> str:
    """Filled outline of a stroked arc with round caps, from 12 o'clock clockwise."""
    ro, ri, cap = RING_RADIUS + RING_WIDTH / 2, RING_RADIUS - RING_WIDTH / 2, RING_WIDTH / 2
    end = 360 * fraction
    large = 1 if end > 180 else 0
    os_, oe = pt(0, ro), pt(end, ro)
    ie, is_ = pt(end, ri), pt(0, ri)
    return (f"M {f(os_[0])} {f(os_[1])} "
            f"A {f(ro)} {f(ro)} 0 {large} 1 {f(oe[0])} {f(oe[1])} "
            f"A {f(cap)} {f(cap)} 0 0 1 {f(ie[0])} {f(ie[1])} "
            f"A {f(ri)} {f(ri)} 0 {large} 0 {f(is_[0])} {f(is_[1])} "
            f"A {f(cap)} {f(cap)} 0 0 1 {f(os_[0])} {f(os_[1])} Z")


def bars_path() -> str:
    total = len(BAR_HEIGHTS) * BAR_WIDTH + (len(BAR_HEIGHTS) - 1) * BAR_GAP
    x = CX - total / 2
    r = BAR_WIDTH / 2
    parts = []
    for h in BAR_HEIGHTS:
        top = BAR_BASELINE - h
        parts.append(
            f"M {f(x)} {f(top + r)} "
            f"A {f(r)} {f(r)} 0 0 1 {f(x + BAR_WIDTH)} {f(top + r)} "
            f"L {f(x + BAR_WIDTH)} {f(BAR_BASELINE - r)} "
            f"A {f(r)} {f(r)} 0 0 1 {f(x)} {f(BAR_BASELINE - r)} Z")
        x += BAR_WIDTH + BAR_GAP
    return " ".join(parts)


def svg(path: str, color: str, evenodd: bool = False) -> str:
    rule = ' fill-rule="evenodd"' if evenodd else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
            f'viewBox="0 0 {CANVAS} {CANVAS}">\n'
            f'  <path d="{path}" fill="{color}"{rule}/>\n</svg>\n')


def gradient(stops: tuple[str, str]) -> dict:
    return {"linear-gradient": list(stops),
            "orientation": {"start": {"x": 0.5, "y": 0.0}, "stop": {"x": 0.5, "y": 1.0}}}


ICON_JSON = {
    "fill-specializations": [
        {"value": gradient(BG_LIGHT)},
        {"appearance": "dark", "value": gradient(BG_DARK)},
    ],
    "groups": [
        {
            # Foreground: bars over the filled arc, glass on, soft shadow.
            "layers": [
                {"name": "bars", "image-name": "bars.svg", "glass": True,
                 # Keep the bars white in dark mode; without this the
                 # system recolours white glyphs to the background colour.
                 "fill-specializations": [
                     {"value": {"solid": "srgb:1.00000,1.00000,1.00000,1.00000"}},
                     {"appearance": "dark",
                      "value": {"solid": "srgb:1.00000,1.00000,1.00000,1.00000"}},
                 ]},
                {"name": "level", "image-name": "level.svg", "glass": True},
            ],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.5},
            "specular": True,
        },
        {
            # Track: the empty part of the ring, faint.
            "layers": [
                {"name": "track", "image-name": "track.svg", "glass": False,
                 "opacity": 0.22},
            ],
            "shadow": {"kind": "none", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.5},
            "specular": False,
        },
    ],
    "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
}

LAYERS = {
    "track.svg": svg(annulus_path(), WHITE, evenodd=True),
    "level.svg": svg(arc_path(LEVEL), GREEN),
    "bars.svg": svg(bars_path(), WHITE),
}


def main() -> None:
    master = Path(__file__).resolve().parent / "master.svg"
    master.write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
        f'viewBox="0 0 {CANVAS} {CANVAS}">\n'
        '  <!-- Flat reference of the layers; the real icon is the .icon bundle. -->\n'
        '  <defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#353BA0"/><stop offset="1" stop-color="#0E103B"/>'
        '</linearGradient></defs>\n'
        f'  <rect width="{CANVAS}" height="{CANVAS}" fill="url(#bg)"/>\n'
        f'  <path d="{annulus_path()}" fill="{WHITE}" fill-opacity="0.22" fill-rule="evenodd"/>\n'
        f'  <path d="{arc_path(LEVEL)}" fill="{GREEN}"/>\n'
        f'  <path d="{bars_path()}" fill="{WHITE}"/>\n'
        '</svg>\n')
    for target in TARGETS:
        bundle = ROOT / target / "AppIcon.icon"
        if bundle.exists():
            shutil.rmtree(bundle)
        (bundle / "Assets").mkdir(parents=True)
        (bundle / "icon.json").write_text(json.dumps(ICON_JSON, indent=2) + "\n")
        for name, content in LAYERS.items():
            (bundle / "Assets" / name).write_text(content)
        print(f"wrote {bundle.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
