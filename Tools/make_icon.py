"""Couchport icon v4: bigger ring, bigger sofa + controller.
Geometry in 'units' where 1000 units = the shorter canvas side."""
from PIL import Image, ImageDraw, ImageFilter
import math

SS = 4  # supersampling

C1 = (8, 38, 120)    # top-left deep blue
C2 = (0, 112, 210)   # bottom-right blue
RING_A = (40, 200, 255)
RING_B = (110, 150, 255)
GLYPH = (255, 255, 255)
CUT = (8, 72, 170)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def background(W, H):
    g = Image.new('RGB', (W, H))
    px = g.load()
    for y in range(H):
        for x in range(W):
            t = (x / W * 0.45 + y / H * 0.55)
            px[x, y] = lerp(C1, C2, t)
    # soft centre bloom
    bloom = Image.new('L', (W, H), 0)
    d = ImageDraw.Draw(bloom)
    r = min(W, H) * 0.42
    d.ellipse((W/2-r, H/2-r, W/2+r, H/2+r), fill=90)
    bloom = bloom.filter(ImageFilter.GaussianBlur(min(W, H) * 0.12))
    light = Image.new('RGB', (W, H), (40, 150, 255))
    return Image.composite(light, g, bloom)

def ring_layer(W, H, R, stroke):
    """Gradient ring with glow, RGBA."""
    S = SS
    w, h = W*S, H*S
    cx, cy = w/2, h/2
    Rs, st = R*S, stroke*S
    mask = Image.new('L', (w, h), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse((cx-Rs, cy-Rs, cx+Rs, cy+Rs), fill=255)
    d.ellipse((cx-Rs+st, cy-Rs+st, cx+Rs-st, cy+Rs-st), fill=0)
    mask = mask.resize((W, H), Image.LANCZOS)
    # diagonal gradient colour
    grad = Image.new('RGB', (W, H))
    gp = grad.load()
    for y in range(H):
        for x in range(W):
            t = max(0, min(1, ((x - (W/2-R)) + (y - (H/2-R))) / (4*R)))
            gp[x, y] = lerp(RING_A, RING_B, t)
    ring = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    ring.paste(grad, (0, 0), mask)
    glow_mask = mask.filter(ImageFilter.GaussianBlur(stroke * 0.55)).point(lambda v: int(v * 0.75))
    glow = Image.new('RGBA', (W, H), (90, 200, 255, 0))
    glow.putalpha(glow_mask)
    out = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    out.alpha_composite(glow)
    out.alpha_composite(ring)
    return out

def glyph_layer(W, H, scale, dy=0.0):
    """Controller above a sofa. Base design ~380x335 units, centred."""
    S = SS
    w, h = W*S, H*S
    u = min(W, H) / 1000 * scale * S  # px per unit
    cx, cy = w/2, h/2 + dy*u
    img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    def R(x0, y0, x1, y1, r, fill):
        d.rounded_rectangle((cx+x0*u, cy+y0*u, cx+x1*u, cy+y1*u), radius=r*u, fill=fill)
    # base design coordinates centred at (0,0); bbox x -190..190, y -170..168
    # controller pill
    R(-122, -170, 122, -66, 52, GLYPH)
    # d-pad
    R(-86, -126, -40, -110, 4, CUT)
    R(-71, -141, -55, -95, 4, CUT)
    # face buttons
    for (bx, by) in ((44, -128), (70, -106)):
        d.ellipse((cx+(bx-12)*u, cy+(by-12)*u, cx+(bx+12)*u, cy+(by+12)*u), fill=CUT)
    # sofa back
    R(-160, -24, 160, 70, 24, GLYPH)
    # arms
    R(-192, 36, -132, 146, 28, GLYPH)
    R(132, 36, 192, 146, 28, GLYPH)
    # seat
    R(-170, 60, 170, 146, 18, GLYPH)
    # legs
    R(-168, 138, -150, 168, 6, GLYPH)
    R(150, 138, 168, 168, 6, GLYPH)
    # cushion seams
    R(-132, 64, 132, 74, 3, CUT)
    R(-5, -8, 5, 68, 3, CUT)
    img = img.resize((W, H), Image.LANCZOS)
    # subtle drop shadow for depth
    sh = img.split()[3].filter(ImageFilter.GaussianBlur(min(W, H)*0.012)).point(lambda v: int(v*0.35))
    shadow = Image.new('RGBA', (W, H), (0, 20, 70, 0)); shadow.putalpha(sh)
    out = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    off = int(min(W, H)*0.008)
    out.alpha_composite(shadow, (0, off))
    out.alpha_composite(img)
    return out

def render(W, H, ring_frac, stroke_frac, glyph_scale):
    m = min(W, H)
    bg = background(W, H)
    ring = ring_layer(W, H, m*ring_frac, m*stroke_frac)
    glyph = glyph_layer(W, H, glyph_scale, dy=-2)
    return bg, ring, glyph

if __name__ == '__main__':
    import sys
    W, H = int(sys.argv[1]), int(sys.argv[2])
    bg, ring, glyph = render(W, H, 0.455, 0.05, 1.38)
    comp = bg.convert('RGBA'); comp.alpha_composite(ring); comp.alpha_composite(glyph)
    comp.convert('RGB').save(sys.argv[3])
