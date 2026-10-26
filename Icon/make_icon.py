import math, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 4
N = 1024 * S
M, RAD = 100 * S, 185 * S
variant = sys.argv[1]
SUB = int(sys.argv[2]) if len(sys.argv) > 2 else 2
WIRE = len(sys.argv) > 3 and sys.argv[3] == "wire"

# ---------- icosphere ----------
t = (1 + 5 ** 0.5) / 2
V = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
     (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
F = [(0,11,5),(0,5,1),(0,1,7),(0,7,10),(0,10,11),(1,5,9),(5,11,4),(11,10,2),(10,7,6),(7,1,8),
     (3,9,4),(3,4,2),(3,2,6),(3,6,8),(3,8,9),(4,9,5),(2,4,11),(6,2,10),(8,6,7),(9,8,1)]
V = [np.array(v, float) / np.linalg.norm(v) for v in V]
for _ in range(SUB):
    cache, nf = {}, []
    def mid(a, b):
        k = (min(a, b), max(a, b))
        if k not in cache:
            m = V[a] + V[b]; V.append(m / np.linalg.norm(m)); cache[k] = len(V) - 1
        return cache[k]
    for a, b, c in F:
        ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
        nf += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
    F = nf
V = np.array(V)

def rot(ax, ay):
    ax, ay = math.radians(ax), math.radians(ay)
    Rx = np.array([[1,0,0],[0,math.cos(ax),-math.sin(ax)],[0,math.sin(ax),math.cos(ax)]])
    Ry = np.array([[math.cos(ay),0,math.sin(ay)],[0,1,0],[-math.sin(ay),0,math.cos(ay)]])
    return Rx @ Ry
V = V @ rot(-18, 24).T          # y up, z toward viewer

# ---------- tile ----------
def vgrad(c1, c2):
    a = np.linspace(0, 1, N)[:, None, None]
    c1, c2 = np.array(c1, float), np.array(c2, float)
    rgb = c1 * (1 - a) + c2 * a
    rgb = np.broadcast_to(rgb, (N, N, 3))
    return Image.fromarray(np.dstack([rgb, np.full((N, N, 1), 255.)]).astype(np.uint8), "RGBA")

img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
tile = Image.new("L", (N, N), 0)
ImageDraw.Draw(tile).rounded_rectangle([M, M, N - M, N - M], RAD, fill=255)
sh = Image.new("RGBA", (N, N), (0, 0, 0, 0)); sh.putalpha(tile.filter(ImageFilter.GaussianBlur(16 * S)).point(lambda v: int(v * .32)))
img.alpha_composite(sh, (0, 10 * S))
colA = colB = None
if variant == "midnight":
    bg = vgrad((30, 44, 78), (8, 12, 28)); base = np.array([1., 1., 1.]); edge = (190, 230, 255)
    colA, colB = np.array([0.62, 0.90, 1.00]), np.array([0.22, 0.38, 0.95])
elif variant == "frost":
    bg = vgrad((250, 251, 254), (220, 228, 240)); base = np.array([1., 1., 1.]); edge = (20, 40, 90)
    colA, colB = np.array([0.55, 0.88, 0.98]), np.array([0.20, 0.32, 0.82])
elif variant == "dark":
    bg = vgrad((58, 58, 62), (22, 22, 24)); base = np.array([0.80, 0.81, 0.83]); edge = (255, 255, 255)
else:
    bg = vgrad((252, 252, 253), (226, 227, 231)); base = np.array([0.80, 0.81, 0.83]); edge = (30, 30, 34)
img.paste(bg, (0, 0), tile)

# ---------- contact shadow ----------
cx, cy, R = N / 2, N / 2 - 6 * S, 250 * S
cs = Image.new("L", (N, N), 0)
ImageDraw.Draw(cs).ellipse([cx - R * .78, cy + R * .93, cx + R * .78, cy + R * 1.07], fill=255)
cs = cs.filter(ImageFilter.GaussianBlur(22 * S)).point(lambda v: int(v * (.55 if variant in ("dark", "midnight") else .28)))
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0)); shadow.putalpha(cs)
img.alpha_composite(shadow)

# ---------- shade facets ----------
L1 = np.array([-0.55, 0.65, 0.52]); L1 /= np.linalg.norm(L1)      # key, upper left
L2 = np.array([0.8, -0.1, -0.2]);   L2 /= np.linalg.norm(L2)      # rim, right
H1 = L1 + np.array([0, 0, 1.]); H1 /= np.linalg.norm(H1)
obj = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(obj)
faces = []
for a, b, c in F:
    p = V[[a, b, c]]
    n = np.cross(p[1] - p[0], p[2] - p[0]); n /= np.linalg.norm(n)
    if n @ p.mean(0) < 0: n = -n
    if n[2] <= 0: continue
    diff = max(0, n @ L1)
    spec = max(0, n @ H1) ** 14
    rim = max(0, n @ L2) ** 2 * 0.35
    sky = 0.5 + 0.5 * n[1]                              # studio: lighter from above
    v = 0.30 + 0.48 * diff + 0.20 * sky + rim
    if colA is not None:
        m = np.clip(0.5 + 0.5 * (n @ np.array([-0.6, 0.7, 0.2])), 0, 1)   # teal top-left -> indigo bottom-right
        tint = colB * (1 - m) + colA * m
        col = np.clip(tint * v + spec * 0.40, 0, 1)
    else:
        col = np.clip(base * v + spec * 0.32, 0, 1)
    pts = [(cx + q[0] * R, cy - q[1] * R) for q in p]
    faces.append((p[:, 2].mean(), pts, tuple(int(x * 255) for x in col), p[:, 0].mean()))
faces.sort(key=lambda f: f[0])
for _, pts, col, _ in faces:
    d.polygon(pts, fill=col + (255,), outline=col + (255,))
img.alpha_composite(obj)

# ---------- mesh edges fading in toward the right: photo -> mesh ----------
lines = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ld = ImageDraw.Draw(lines)
for _, pts, _, x in faces:
    k = np.clip((x - 0.0) / 0.75, 0, 1) ** 1.6
    if not WIRE or k <= 0.02: continue
    a = int(k * (150 if variant in ("dark", "midnight") else 130))
    ld.line(pts + [pts[0]], fill=edge + (a,), width=int(1.6 * S), joint="curve")
img.alpha_composite(lines)

img.resize((1024, 1024), Image.LANCZOS).save(f"simple_{variant}_{SUB}.png")
