#!/usr/bin/env python3
"""Bake Kero's Rex Oklab wash into small, renderer-independent PNGs.

Source: egoist/kero theme.go, revision 4f6b7e04fb96b928441ca78d1eb35638b3af58ab.
Copyright (c) 2026 EGOIST, MIT (assets/licenses/kero-MIT.txt).
No runtime gradients, generated UI mockups, or platform-specific materials.
"""
from pathlib import Path
import math
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]


def lab(rgb):
    r, g, b = [((v / 255 + .055) / 1.055) ** 2.4 if v > 10.31475 else v / 3294.6 for v in rgb]
    l, m, s = [(a*r+b_*g+c*b) ** (1/3) for a, b_, c in
               ((.4122214708, .5363325363, .0514459929),
                (.2119034982, .6806995451, .1073969566),
                (.0883024619, .2817188376, .6299787005))]
    return (.2104542553*l+.793617785*m-.0040720468*s,
            1.9779984951*l-2.428592205*m+.4505937099*s,
            .0259040371*l+.7827717662*m-.808675766*s)


def rgb(lab_value):
    l, a, b = lab_value
    x, y, z = (l+.3963377774*a+.2158037573*b)**3, (l-.1055613458*a-.0638541728*b)**3, (l-.0894841775*a-1.291485548*b)**3
    linear = (4.0767416621*x-3.3077115913*y+.2309699292*z,
              -1.2684380046*x+2.6097574011*y-.3413193965*z,
              -.0041960863*x-.7034186147*y+1.707614701*z)
    return [round(max(0, min(1, 12.92*v if v <= .0031308 else 1.055*v**(1/2.4)-.055))*255) for v in linear]


def mix(a, b, t):
    return tuple(x+(y-x)*t for x, y in zip(a, b))


def chunk(kind, data):
    return struct.pack('>I', len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data))


def generate(name, stops, glow, alpha):
    colors = [lab(bytes.fromhex(s)) for s in stops]
    tint = lab(bytes.fromhex(glow))
    side = 256
    pixels = bytearray()
    for y in range(side):
        pixels.append(0)  # PNG filter
        t = y/(side-1)*(len(colors)-1)
        at = min(len(colors)-2, math.floor(t))
        base = mix(colors[at], colors[at+1], t-at)
        for x in range(side):
            strength = max(0, 1-((1-x/(side-1))+y/(side-1)))*alpha
            pixels.extend(rgb(mix(base, tint, strength)))
    output = ROOT/'src/ui_assets'/f'rex-{name}.png'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>2I5B', side, side, 8, 2, 0, 0, 0))+
                       chunk(b'IDAT', zlib.compress(pixels, 9))+chunk(b'IEND', b''))


if __name__ == '__main__':
    generate('light', ['ebe0f3', 'f3e7f1', 'f7eee4', 'f6efcf'], 'f7dcf1', .75)
    generate('dark', ['17141f', '191620', '1b1916'], '784678', .22)

    for name, light, light_glow, dark, dark_glow, alpha in [
        ('mist', ['e3e9f4','ebeff6','f1f2f3','f2f1ec'], 'd2e1f8', ['12151b','14171d','17181b'], '466496', .22),
        ('meadow', ['e2eee5','ebf2e7','f3f2e2','f5f0d6'], 'd6f0de', ['111814','141a16','181a14'], '46825f', .2),
        ('dusk', ['e4dbf3','efdeee','f6e3dc','f7e6cf'], 'f6cede', ['191321','1e161e','221a17'], '96506e', .25),
        ('plain', ['eceef4','eceef4'], 'eceef4', ['141418','141418'], '141418', 0),
    ]:
        generate(name+'-light', light, light_glow, .8 if name=='dusk' else .75)
        generate(name+'-dark', dark, dark_glow, alpha)
