"""MediaPipe Face Landmarker 能不能比 Vision 的瞳孔點更準地估計注視位置。

    tools/gaze-spike/.venv/bin/python tools/gaze-spike/mediapipe_eval.py recordings/gaze-<時間>.jsonl [...]

錄影要用 `mirage-spike gaze --frames --builtin` 錄（JSONL 的 `image` 欄位指到影像）。第一次會對每張影像跑
Face Landmarker，結果快取在 `recordings/gaze-<時間>/mediapipe.npz`（含臉部特徵，只在本機，不進版控）。

特徵：
- 虹膜中心相對眼角與眼瞼的位置（478 點模型的虹膜點）；
- 眼神方向的 blendshape（eyeLookIn/Out/Up/Down 左右各一）；
- 臉部姿態矩陣的朝向與位移（Vision 的頭部角度是量化的，沒有資訊）。
驗證方式同 `analyze.py`：9 點校準後估計換順序驗證與轉頭注視，另加留一（每次留一個目標）。
"""
import json
import math
import os
import statistics
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from analyze import Ridge, load, pct  # noqa: E402

MODEL = Path(__file__).parent / "face_landmarker.task"
SETTLE = 0.6
# 轉成 GPU 影像時紅藍可能對調；環境變數 GAZE_ORDER=BGRA 可改順序（快取檔名不同，不會互相覆蓋）。
ORDER_NAME = os.environ.get("GAZE_ORDER", "RGBA")

# 478 點：右眼（畫面左側）與左眼的眼角、上下眼瞼、虹膜中心。
EYES = {
    "R": dict(outer=33, inner=133, up=159, low=145, iris=468),
    "L": dict(outer=263, inner=362, up=386, low=374, iris=473),
}


ORDER = None  # 在 extract 內依 ORDER_NAME 取得 cv2 的轉換代碼


def extract(jsonl: Path) -> Path:
    """對錄影裡每張影像跑 Face Landmarker，存成 npz；已有快取就直接用。"""
    folder = jsonl.with_suffix("")
    cache = folder / ("mediapipe.npz" if ORDER_NAME == "RGBA" else f"mediapipe-{ORDER_NAME}.npz")
    if cache.exists():
        return cache
    import cv2
    global ORDER
    ORDER = {"RGBA": cv2.COLOR_BGR2RGBA, "BGRA": cv2.COLOR_BGR2BGRA}[ORDER_NAME]
    import mediapipe as mp
    from mediapipe.tasks import python as mpt
    from mediapipe.tasks.python import vision

    # Mac 上 CPU 模式建立時會因缺少 GPU 服務而中止（同 tools/mediapipe-spike），要用 GPU 模式，輸入需 4 通道。
    options = vision.FaceLandmarkerOptions(
        base_options=mpt.BaseOptions(model_asset_path=str(MODEL), delegate=mpt.BaseOptions.Delegate.GPU),
        running_mode=vision.RunningMode.IMAGE,
        num_faces=1,
        output_face_blendshapes=True,
        output_facial_transformation_matrixes=True,
    )
    frames = [json.loads(line) for line in open(jsonl)]
    indexes, times, landmarks, blends, matrices, ok = [], [], [], [], [], []
    names = None
    with vision.FaceLandmarker.create_from_options(options) as landmarker:
        for i, frame in enumerate(frames):
            if not frame.get("image"):
                continue
            bgr = cv2.imread(str(folder / frame["image"]))
            result = landmarker.detect(mp.Image(image_format=mp.ImageFormat.SRGBA, data=cv2.cvtColor(bgr, ORDER)))
            indexes.append(i)
            times.append(frame["t"])
            if not result.face_landmarks:
                ok.append(False)
                landmarks.append(np.zeros((478, 3)))
                blends.append(np.zeros(52))
                matrices.append(np.eye(4))
                continue
            ok.append(True)
            landmarks.append(np.array([[p.x, p.y, p.z] for p in result.face_landmarks[0]]))
            names = names or [c.category_name for c in result.face_blendshapes[0]]
            blends.append(np.array([c.score for c in result.face_blendshapes[0]]))
            matrices.append(np.array(result.facial_transformation_matrixes[0]))
    np.savez_compressed(
        cache, index=indexes, t=times, landmarks=np.array(landmarks), blends=np.array(blends), matrices=np.array(matrices),
        ok=ok, names=names or [],
    )
    return cache


def features(landmarks, blends, names, matrix, size):
    """一幀的特徵（dict）。座標換成像素；眼睛的量以眼寬為單位。"""
    pts = landmarks[:, :2] * size
    out = {}
    per_eye = []
    for eye in EYES.values():
        a, b, up, low, iris = (pts[eye[k]] for k in ("outer", "inner", "up", "low", "iris"))
        span = np.linalg.norm(b - a)
        u = (b - a) / span
        # 兩眼的軸方向不同（外眼角在左或右），統一成「朝畫面右」為正。
        if u[0] < 0:
            u = -u
        n = np.array([-u[1], u[0]])  # 垂直軸，y 向下的影像座標中，朝下為正
        mid = (a + b) / 2
        lid = (up + low) / 2
        per_eye.append((
            float((iris - mid) @ u / span),  # 沿眼角連線
            float((iris - mid) @ n / span),  # 垂直於眼角連線，相對眼角連線中點
            float((iris - lid) @ n / span),  # 垂直，相對兩眼瞼中點
            float(np.linalg.norm(up - low) / span),  # 眼睛張開程度
            float(span),
        ))
    out["ex"] = float(np.mean([e[0] for e in per_eye]))
    out["ey"] = float(np.mean([e[1] for e in per_eye]))
    out["ey_lid"] = float(np.mean([e[2] for e in per_eye]))
    out["open"] = float(np.mean([e[3] for e in per_eye]))
    out["eyew"] = float(np.mean([e[4] for e in per_eye]))
    b = dict(zip(names, blends))
    for key in ("eyeLookInLeft", "eyeLookOutLeft", "eyeLookUpLeft", "eyeLookDownLeft",
                "eyeLookInRight", "eyeLookOutRight", "eyeLookUpRight", "eyeLookDownRight"):
        out[key] = float(b[key])
    out["bx"] = (b["eyeLookOutLeft"] - b["eyeLookInLeft"] + b["eyeLookInRight"] - b["eyeLookOutRight"]) / 2
    out["by"] = (b["eyeLookUpLeft"] + b["eyeLookUpRight"] - b["eyeLookDownLeft"] - b["eyeLookDownRight"]) / 2
    r = matrix[:3, :3] / np.linalg.norm(matrix[:3, :3], axis=0)
    # 朝向的方向餘弦與滾動，沒有歐拉角的折返問題。
    out["fx"], out["fy"], out["roll"] = float(r[0, 2]), float(r[1, 2]), float(r[0, 1])
    out["tx"], out["ty"], out["tz"] = (float(v) for v in matrix[:3, 3])
    nose = pts[1]
    out["nx"], out["ny"] = float(nose[0]), float(nose[1])
    return out


def samples(jsonl: Path, extra=None):
    """各注視階段中，目標停穩後、有偵測到臉、有影像的幀：{phase: [dict]}。
    `extra(frame 序號)` 回傳要併進特徵的 dict；回傳 None 的幀略過（例如另一個模型沒偵測到）。"""
    frames = [json.loads(line) for line in open(jsonl)]
    cache = np.load(extract(jsonl))
    names = [str(n) for n in cache["names"]]
    by_index = {int(i): k for k, i in enumerate(cache["index"])}
    size = frames[0]["width"]
    out = defaultdict(list)
    since = None
    for i, f in enumerate(frames):
        if f["phase"] not in ("gazeCalibrate", "gazeCheck", "gazeHead") or not f.get("target"):
            continue
        target = (f["target"]["x"], f["target"]["y"])
        if since is None or since[0] != target:
            since = (target, f["t"])
        k = by_index.get(i)
        if k is None or f["t"] - since[1] < SETTLE or not cache["ok"][k]:
            continue
        feats = features(cache["landmarks"][k], cache["blends"][k], names, cache["matrices"][k], size)
        if extra is not None:
            more = extra(i)
            if more is None:
                continue
            feats.update(more)
        out[f["phase"]].append(dict(t=f["t"], target=target, **feats))
    total = sum(1 for f in frames if f.get("image") and f["phase"] in ("gazeCalibrate", "gazeCheck", "gazeHead"))
    detected = int(np.sum(cache["ok"]))
    return out, total, detected, frames


def poly2(a, b):
    return lambda f: [f[a], f[b], f[a] * f[b], f[a] ** 2, f[b] ** 2]


BLEND8 = ["eyeLookInLeft", "eyeLookOutLeft", "eyeLookUpLeft", "eyeLookDownLeft",
          "eyeLookInRight", "eyeLookOutRight", "eyeLookUpRight", "eyeLookDownRight"]
POSE = ["fx", "fy", "tx", "ty", "tz"]


def lin(*keys):
    return lambda f: [f[k] for k in keys]


MODELS = {
    "Vision 式：虹膜相對眼角中線（二次）": poly2("ex", "ey"),
    "虹膜相對眼瞼（二次）": poly2("ex", "ey_lid"),
    "眼神 blendshape 2 維（二次）": poly2("bx", "by"),
    "眼神 blendshape 8 維（一次）": lin(*BLEND8),
    "虹膜＋姿態（一次）": lin("ex", "ey_lid", *POSE),
    "blendshape＋姿態（一次）": lin(*BLEND8, *POSE),
    "虹膜＋blendshape＋姿態（一次）": lin("ex", "ey_lid", *BLEND8, *POSE),
    "只有姿態（對照，一次）": lin(*POSE),
}


def errors(fit, row, ss):
    return [math.dist(fit.predict(row(s)), s["target"]) for s in ss]


def fmt(e):
    return f"{pct(e, .5):4.0f} / {pct(e, .9):4.0f}" if e else "  —  "


SNR_KEYS = ("ex", "ey", "ey_lid", "bx", "by", "fx", "fy", "tx", "ty", "tz", "open")


def snr(cal, keys=SNR_KEYS):
    """單一特徵：螢幕左右（10%→90%）或上下的平均變化 ÷ 同一目標內的標準差。"""
    xs = sorted({s["target"][0] for s in cal})
    ys = sorted({s["target"][1] for s in cal})
    rows = []
    for key in keys:
        within = statistics.mean(
            statistics.pstdev([s[key] for s in cal if s["target"] == t])
            for t in {s["target"] for s in cal} if sum(1 for s in cal if s["target"] == t) > 2
        )
        def col(value, axis):
            return statistics.mean(s[key] for s in cal if s["target"][axis] == value)
        stepx = col(xs[-1], 0) - col(xs[0], 0)
        stepy = col(ys[-1], 1) - col(ys[0], 1)  # y 為 90%（上）減 10%（下）
        rows.append((key, stepx, stepy, within))
    return rows


def evaluate(jsonl: Path, models=None, extra=None, keys=SNR_KEYS):
    models = models or MODELS
    phases, total, detected, frames = samples(jsonl, extra)
    cal, chk, head = phases["gazeCalibrate"], phases["gazeCheck"], phases["gazeHead"]
    width = max(f["target"]["x"] for f in frames if f.get("target")) / 0.9
    height = max(f["target"]["y"] for f in frames if f.get("target")) / 0.9
    print(f"\n===== {jsonl.name}  螢幕 ≈ {width:.0f}×{height:.0f} pt =====")
    print(f"影像 {total} 張中偵測到臉 {detected} 張；樣本 校準 {len(cal)}・驗證 {len(chk)}・轉頭 {len(head)}")
    center = (width / 2, height / 2)
    print(f"永遠猜中央：驗證 {fmt([math.dist(center, s['target']) for s in chk])}")
    print("\n誤差 p50 / p90（pt）")
    print(f"{'模型':34s} {'驗證':>11s} {'轉頭':>11s} {'留一':>11s} {'校準本身':>11s}")
    for name, row in models.items():
        fit = Ridge([row(s) for s in cal], [s["target"] for s in cal])
        loo = []
        for t in {s["target"] for s in cal}:
            rest = [s for s in cal if s["target"] != t]
            held = [s for s in cal if s["target"] == t]
            f2 = Ridge([row(s) for s in rest], [s["target"] for s in rest])
            loo += errors(f2, row, held)
        print(f"{name:32s} {fmt(errors(fit, row, chk)):>11s} {fmt(errors(fit, row, head)):>11s} {fmt(loo):>11s} {fmt(errors(fit, row, cal)):>11s}")
    print("\n單一特徵的訊號：10%→90% 的變化 ÷ 同一目標內的標準差（校準階段）")
    print(f"{'特徵':8s} {'左→右變化':>10s} {'下→上變化':>10s} {'逐幀晃動':>9s} {'水平比':>7s} {'垂直比':>7s}")
    for key, sx, sy, within in snr(cal, keys):
        print(f"{key:8s} {sx:+10.4f} {sy:+10.4f} {within:9.4f} {abs(sx) / within:7.1f} {abs(sy) / within:7.1f}")
    eyew = statistics.median(s["eyew"] for s in cal)
    print(f"眼寬中位數 {eyew:.0f} px")


if __name__ == "__main__":
    for path in sys.argv[1:]:
        evaluate(Path(path))
