"""用 `mirage-spike gaze` 的錄影（JSONL）重現 `GazeAnalysis` 的驗證：9 點校準後估計注視位置，回報誤差 p50 / p90（pt）。
只用標準函式庫，數字與 Swift 一致（p90 的內插方式不同，差幾 pt）。之後的候選（MediaPipe、外觀式模型）沿用這裡的
特徵萃取以外的部分：`samples`、`Ridge`、驗證方式。

    python3 tools/gaze-spike/analyze.py recordings/gaze-<時間>.jsonl

螢幕大小由目標位置反推（目標在 10%–90%），所以要看輸出的「screen」是不是預期的那個螢幕。
Vision 的 yaw 只有 0 與 -45°、pitch 沒有值、roll 只有 0 與 -30°（量化），所以 yaw、pitch 特徵沒有資訊，
「只看頭」等於只看臉在畫面中的位置。
"""
import json, math, statistics, sys
from collections import defaultdict

def pct(v, q):
    v = sorted(v); 
    if not v: return None
    i = q * (len(v) - 1); lo = math.floor(i); hi = math.ceil(i)
    return v[lo] + (v[hi] - v[lo]) * (i - lo)

def features(face, w, h):
    def px(p): return (p["x"] * w, p["y"] * h)
    def offset(contour, pupil):
        if not pupil or len(contour) < 2: return None
        pts = [px(p) for p in contour]
        span, corners = 0, (pts[0], pts[1])
        for i in range(len(pts)):
            for j in range(i + 1, len(pts)):
                d = math.dist(pts[i], pts[j])
                if d > span: span, corners = d, (pts[i], pts[j])
        if span <= 0: return None
        a, b = corners if corners[0][0] <= corners[1][0] else (corners[1], corners[0])
        ux, uy = (b[0] - a[0]) / span, (b[1] - a[1]) / span
        p = px(pupil); dx, dy = p[0] - (a[0] + b[0]) / 2, p[1] - (a[1] + b[1]) / 2
        return ((dx * ux + dy * uy) / span, (dy * ux - dx * uy) / span), span
    l = offset(face["leftEye"], face.get("leftPupil")); r = offset(face["rightEye"], face.get("rightPupil"))
    if not l or not r: return None
    return dict(ex=(l[0][0] + r[0][0]) / 2, ey=(l[0][1] + r[0][1]) / 2, yaw=face.get("yaw") or 0, pitch=face.get("pitch") or 0,
                cx=face["center"]["x"], cy=face["center"]["y"], eyew=(l[1] + r[1]) / 2, facew=face["width"] * w)

def load(path):
    return [json.loads(l) for l in open(path)]

def samples(frames, phase, settle=0.6):
    out, since = [], None
    for f in frames:
        if f["phase"] != phase or not f.get("target"): continue
        t = (f["target"]["x"], f["target"]["y"])
        if since is None or since[0] != t: since = (t, f["t"])
        if f["t"] - since[1] < settle or not f.get("face"): continue
        ft = features(f["face"], f["width"], f["height"])
        if ft: out.append(dict(t=f["t"], target=t, **ft))
    return out

def solve(a, b):
    n = len(b); m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c])); m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c:
                k = m[r][c] / m[c][c]
                for j in range(c, n + 1): m[r][j] -= k * m[c][j]
    return [m[i][n] / m[i][i] for i in range(n)]

class Ridge:
    def __init__(self, rows, targets, lam=1.0):
        n = len(rows); cols = len(rows[0])
        self.mean = [sum(r[c] for r in rows) / n for c in range(cols)]
        self.scale = []
        for c in range(cols):
            v = sum((r[c] - self.mean[c]) ** 2 for r in rows) / n
            self.scale.append(math.sqrt(v) if v > 0 else 1)
        design = [[1] + [(r[c] - self.mean[c]) / self.scale[c] for c in range(cols)] for r in rows]
        size = cols + 1
        normal = [[sum(d[i] * d[j] for d in design) for j in range(size)] for i in range(size)]
        for i in range(1, size): normal[i][i] += lam
        self.wx = solve(normal, [sum(d[i] * t[0] for d, t in zip(design, targets)) for i in range(size)])
        self.wy = solve(normal, [sum(d[i] * t[1] for d, t in zip(design, targets)) for i in range(size)])
    def predict(self, row):
        x = [1] + [(row[c] - self.mean[c]) / self.scale[c] for c in range(len(row))]
        return (sum(a * b for a, b in zip(x, self.wx)), sum(a * b for a, b in zip(x, self.wy)))

MODELS = {
    "eyes2": lambda f: [f["ex"], f["ey"], f["ex"] * f["ey"], f["ex"] ** 2, f["ey"] ** 2],
    "eyes+head": lambda f: [f["ex"], f["ey"], f["yaw"], f["pitch"], f["cx"], f["cy"]],
    "head": lambda f: [f["yaw"], f["pitch"], f["cx"], f["cy"]],
}

if __name__ == "__main__":
    frames = load(sys.argv[1])
    cal, chk, head = (samples(frames, p) for p in ("gazeCalibrate", "gazeCheck", "gazeHead"))
    print("samples", len(cal), len(chk), len(head))
    W = max(f["target"]["x"] for f in frames if f.get("target")) / 0.9
    H = max(f["target"]["y"] for f in frames if f.get("target")) / 0.9
    print(f"screen ≈ {W:.0f}x{H:.0f} pt")
    center = (W / 2, H / 2)
    d = [math.dist(center, s["target"]) for s in chk]
    print(f"always-center: check p50/p90 {pct(d,.5):.0f}/{pct(d,.9):.0f}")
    for name, row in MODELS.items():
        fit = Ridge([row(s) for s in cal], [s["target"] for s in cal])
        for label, ss in (("check", chk), ("head", head)):
            e = [math.dist(fit.predict(row(s)), s["target"]) for s in ss]
            print(f"{name:10s} {label:5s} p50/p90 {pct(e,.5):.0f}/{pct(e,.9):.0f}")
        if name == "eyes2":
            per = defaultdict(list)
            for s in chk: per[s["target"]].append(math.dist(fit.predict(row(s)), s["target"]))
            print("  per-target median error, check phase (x%, y% of screen):")
            for t, v in sorted(per.items(), key=lambda kv: (-kv[0][1], kv[0][0])):
                print(f"    ({t[0]/W*100:3.0f},{t[1]/H*100:3.0f}) n={len(v):2d} median {statistics.median(v):5.0f}")
    # signal vs noise of raw eye feature: between-target spread vs within-target std (calibration phase)
    by = defaultdict(list)
    for s in cal: by[s["target"]].append(s)
    for key, label in (("ex", "eye x (eye-width units)"), ("ey", "eye y")):
        means = {t: statistics.mean(s[key] for s in v) for t, v in by.items()}
        within = statistics.mean(statistics.pstdev([s[key] for s in v]) for v in by.values() if len(v) > 2)
        col = {}
        for t, m in means.items(): col.setdefault(t[0] if key == "ex" else t[1], []).append(m)
        left, right = statistics.mean(col[min(col)]), statistics.mean(col[max(col)])
        print(f"{label}: 10%→90% of screen moves {right-left:+.4f}, within-target std {within:.4f} → step/std {abs(right-left)/within:.1f}")
    eyew = statistics.median(s["eyew"] for s in cal); facew = statistics.median(s["facew"] for s in cal)
    print(f"eye width ≈ {eyew:.0f} px, face width ≈ {facew:.0f} px (frame 1552)")

    # 各階段的臉位置與大小，以及同一個目標在校準與驗證階段的眼睛特徵差：校準之後頭有沒有移動
    phases = {p: samples(frames, p) for p in ("gazeCalibrate", "gazeCheck", "gazeHead")}
    for p, s in phases.items():
        print(f"{p:14s} n={len(s):3d} face center ({statistics.mean(x['cx'] for x in s):.3f}, {statistics.mean(x['cy'] for x in s):.3f}) width {statistics.mean(x['facew'] for x in s):.0f} px")
    def by_target(ss):
        d = defaultdict(list)
        for x in ss: d[x["target"]].append(x)
        return d
    c, k = by_target(phases["gazeCalibrate"]), by_target(phases["gazeCheck"])
    for key in ("ex", "ey"):
        shift = [statistics.mean(v[key] for v in k[t]) - statistics.mean(v[key] for v in c[t]) for t in c if t in k]
        print(f"校準→驗證，同一目標的眼睛特徵 {key} 差：平均絕對值 {statistics.mean(map(abs, shift)):.4f}")
    row = MODELS["eyes2"]
    fit = Ridge([row(s) for s in cal], [s["target"] for s in cal])
    e = [math.dist(fit.predict(row(s)), s["target"]) for s in cal]
    print(f"eyes2 校準本身（in-sample）: p50/p90 {pct(e,.5):.0f}/{pct(e,.9):.0f}")
