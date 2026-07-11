"""Generates the ilAI launcher icon source PNGs (run with Pillow installed):

  python3 make_icon.py          # writes icon.png, icon_fg.png, icon_bg.png
  dart run flutter_launcher_icons   # then regenerates all Android densities

Design: full-bleed coral radial gradient (#FFB46B highlight -> #FF5D6D),
white Material "eco" leaf centred, white auto_awesome three-star cluster
top-right — the same mark as the auth hero / Create-account button.
"""
from PIL import Image, ImageDraw

GRAD_IN = (255, 180, 107)   # FFB46B
GRAD_OUT = (255, 93, 109)   # FF5D6D
WHITE = (255, 255, 255, 255)

def cubic(p0, c1, c2, p1, n=70):
    pts = []
    for i in range(1, n + 1):
        t = i / n
        mt = 1 - t
        pts.append((
            mt**3 * p0[0] + 3 * mt**2 * t * c1[0] + 3 * mt * t**2 * c2[0] + t**3 * p1[0],
            mt**3 * p0[1] + 3 * mt**2 * t * c1[1] + 3 * mt * t**2 * c2[1] + t**3 * p1[1],
        ))
    return pts

def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

# Material Icons "eco" glyph as absolute cubic segments (24x24 box).
ECO = [
    ((6.05, 8.05), (3.32, 10.78), (3.32, 15.20), (6.03, 17.93)),
    ((6.03, 17.93), (7.50, 14.53), (10.12, 11.69), (13.39, 10.00)),
    ((13.39, 10.00), (10.62, 12.34), (8.68, 15.61), (8.00, 19.32)),
    ((8.00, 19.32), (10.60, 20.55), (13.80, 20.10), (15.95, 17.95)),
    ((15.95, 17.95), (19.43, 14.47), (20.00, 4.00), (20.00, 4.00)),
    ((20.00, 4.00), (20.00, 4.00), (9.53, 4.57), (6.05, 8.05)),
]

def leaf_polygon(cx, cy, size):
    sc = size / 24.0
    pts = [(ECO[0][0][0], ECO[0][0][1])]
    for p0, c1, c2, p1 in ECO:
        pts += cubic(p0, c1, c2, p1)
    return [((x - 11.7) * sc + cx, (y - 12.0) * sc + cy) for x, y in pts]

def star_polygon(cx, cy, r):
    """auto_awesome four-point star: straight edges, waist ratio 0.3125."""
    w = 0.3125 * r
    return [(cx, cy - r), (cx + w, cy - w), (cx + r, cy), (cx + w, cy + w),
            (cx, cy + r), (cx - w, cy + w), (cx - r, cy), (cx - w, cy - w)]

# Content geometry in 1024 design space (offsets from canvas centre + radius).
LEAF_SIZE = 430
LEAF_DY = 12
STARS = [((216, -230), 92), ((324, -316), 40), ((334, -152), 30)]

def draw_gradient(img, S, highlight, span):
    """Full-bleed radial gradient via concentric circles."""
    gd = ImageDraw.Draw(img)
    hx, hy = highlight
    steps = 480
    for i in range(steps, 0, -1):
        t = i / steps
        col = lerp(GRAD_IN, GRAD_OUT, min(1.0, t * 1.15))
        rr = span * t
        gd.ellipse([hx - rr, hy - rr, hx + rr, hy + rr], fill=col + (255,))

def draw_content(img, S, scale):
    d = ImageDraw.Draw(img)
    cx, cy = S / 2, S / 2
    k = scale * (S / 1024)
    d.polygon(leaf_polygon(cx, cy + LEAF_DY * k, LEAF_SIZE * k), fill=WHITE)
    for (ox, oy), r in STARS:
        d.polygon(star_polygon(cx + ox * k, cy + oy * k, r * k), fill=WHITE)

def render_legacy(S=2048):
    img = Image.new("RGBA", (S, S), GRAD_OUT + (255,))
    draw_gradient(img, S, (0.36 * S, 0.30 * S), 0.96 * S)
    draw_content(img, S, 1.0)
    return img.resize((1024, 1024), Image.LANCZOS)

def render_fg(S=2048):
    """Adaptive foreground: content only. flutter_launcher_icons wraps the
    drawable in a 16% inset (x0.68), so 0.94 here lands the outermost star
    tip right at the 66/108 safe-zone edge on device."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_content(img, S, 0.94)
    return img.resize((1024, 1024), Image.LANCZOS)

def render_bg(S=2048):
    """Adaptive background: gradient positioned for the centre 72/108 viewport."""
    img = Image.new("RGBA", (S, S), GRAD_OUT + (255,))
    draw_gradient(img, S, (0.407 * S, 0.366 * S), 0.70 * S)
    return img.resize((1024, 1024), Image.LANCZOS)

if __name__ == "__main__":
    render_legacy().convert("RGB").save("icon.png")
    render_fg().save("icon_fg.png")
    render_bg().convert("RGB").save("icon_bg.png")
    print("wrote icon.png, icon_fg.png, icon_bg.png")
