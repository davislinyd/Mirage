#!/usr/bin/env python3
"""分析 record.py 的錄影：同一個 MediaPipe 模型，只用 2D 特徵與加上 3D 特徵，哪個比較能分辨按鍵與往前戳。

訊號與雜訊的算法同 Sources/MirageCore/DepthAnalysis.swift：姿勢正確（食指尖仍高於指根、其他三指收起）的每一幀，
特徵比最近 WINDOW 秒內的最小值高出多少；懸停的 p99 是雜訊，按鍵、往前戳各取上升最多的 10 下（相隔至少 0.5 秒）的
中位數是訊號，快速移動、日常的 p99 是可能的誤觸。

用法：.venv/bin/python analyze.py ../../recordings/mediapipe-depth-<時間>.jsonl
"""
import json
import sys

import numpy as np

WINDOW = 0.3
FEATURES = [
    ("flex2d", "2D 彎曲（度）", False),
    ("flex3d", "3D 彎曲（度，world landmarks）", True),
    ("toward", "指尖往鏡頭（mm，world z）", True),
    ("toward_norm", "指尖往鏡頭（掌寬，相對 z）", True),
]


def bend(a, b, c):
    """b 關節的彎曲角度（度），伸直為 0。"""
    u, v = a - b, c - b
    cosine = np.dot(u, v) / (np.linalg.norm(u) * np.linalg.norm(v))
    return 180 - np.degrees(np.arccos(np.clip(cosine, -1, 1)))


def features(frame):
    """回傳（姿勢正確, 特徵）；沒有手時為 None。MediaPipe 影像座標原點在左上。"""
    if not frame["hands"]:
        return None
    hand = frame["hands"][0]
    lm, world = np.array(hand["lm"]), np.array(hand["world"])
    px = lm[:, :2] * [frame["w"], frame["h"]]
    palm = np.linalg.norm(px[5] - px[17])
    if palm <= 0:
        return None

    def rise(tip, mcp):
        return (px[mcp][1] - px[tip][1]) / palm

    posed = rise(8, 5) >= 0.2 and all(rise(t, m) <= 0.2 for t, m in ((12, 9), (16, 13), (20, 17)))
    return posed, {
        "flex2d": bend(px[5], px[6], px[7]) + bend(px[6], px[7], px[8]),
        "flex3d": bend(world[5], world[6], world[7]) + bend(world[6], world[7], world[8]),
        # z 越小越靠近鏡頭。
        "toward": -(world[8][2] - world[5][2]) * 1000,
        "toward_norm": -(lm[8][2] - lm[5][2]) * frame["w"] / palm,
    }


def rises(records, phase):
    history, out = [], []
    for frame in records:
        if frame["phase"] != phase:
            continue
        measured = features(frame)
        if measured is None or not measured[0]:
            continue
        values = measured[1]
        history = [h for h in history if frame["t"] - h[0] <= WINDOW] + [(frame["t"], values)]
        out.append((frame["t"], {k: values[k] - min(h[1][k] for h in history) for k in values}))
    return out


def peaks(series, count=10, gap=0.5):
    picked = []
    for t, value in sorted(series, key=lambda x: -x[1]):
        if len(picked) == count:
            break
        if all(abs(t - p[0]) >= gap for p in picked):
            picked.append((t, value))
    return [v for _, v in picked]


def pct(values, p):
    return float(np.percentile(values, p)) if len(values) else None


def number(value, digits=1):
    return "—" if value is None else f"{value:.{digits}f}"


def report(records):
    lines = ["", "===== MediaPipe 深度評估 ====="]
    with_hand = [r for r in records if r["phase"] != "warmup" and r["hands"]]
    ms = [r["ms"] for r in with_hand]
    lines.append(f"[延遲] 推論 p50/p95：{number(pct(ms, 50))} / {number(pct(ms, 95))} ms（有手的幀）")
    fps_all = []
    for phase in ["move", "hover", "tap", "push", "sweep", "daily"]:
        frames = [r for r in records if r["phase"] == phase]
        if len(frames) < 2:
            continue
        fps = (len(frames) - 1) / (frames[-1]["t"] - frames[0]["t"])
        fps_all.append(fps)
        rate = sum(1 for r in frames if r["hands"]) / len(frames)
        lines.append(f"  {phase}：{len(frames)} 幀・{fps:.1f} fps・偵測率 {rate:.0%}")

    series = {phase: rises(records, phase) for phase in ["hover", "tap", "push", "sweep", "daily"]}
    lines.append("")
    lines.append("[分辨力] 0.3 秒內的上升量：懸停 p99｜按鍵、往前戳取上升最多的 10 下中位數（÷ 懸停 p99）｜快速移動、日常 p99（÷ 按鍵訊號）")
    table = {}
    for key, title, _ in FEATURES:
        def values(phase):
            return [(t, r[key]) for t, r in series[phase]]
        noise = pct([v for _, v in values("hover")], 99)
        tap = pct(peaks(values("tap")), 50)
        push = pct(peaks(values("push")), 50)
        sweep = pct([v for _, v in values("sweep")], 99)
        daily = pct([v for _, v in values("daily")], 99)
        table[key] = (noise, tap, push, sweep, daily)

        def ratio(value, base):
            return f"（{value / base:.1f}×）" if value is not None and base else ""
        lines.append(
            f"  {title}：{number(noise)}｜{number(tap)}{ratio(tap, noise)}、{number(push)}{ratio(push, noise)}"
            f"｜{number(sweep)}{ratio(sweep, tap)}、{number(daily)}{ratio(daily, tap)}"
        )

    # 通過標準（見計劃）：3D 特徵的訊雜比 ≥ 3 且至少是 2D 的 1.5 倍；快速移動、日常不比 2D 更容易誤觸；延遲夠低。
    def snr(key, column):
        noise, value = table[key][0], table[key][column]
        if value is None:
            return 0
        return value / noise if noise else float("inf") if value > 0 else 0

    def spill(key):
        noise, tap, _, sweep, daily = table[key]
        return max(sweep or 0, daily or 0) / tap if tap else float("inf")

    lines.append("")
    lines.append("[判定]")
    for column, name in ((1, "按鍵"), (2, "往前戳")):
        if table["flex2d"][0] is None or table["flex2d"][column] is None:
            lines.append(f"  {name}：懸停或{name}階段沒有姿勢正確的幀，資料不足，無法判定")
            continue
        base = snr("flex2d", column)
        best = max((k for k, _, is3d in FEATURES if is3d), key=lambda k: snr(k, column))
        passed = snr(best, column) >= 3 and snr(best, column) >= 1.5 * base and spill(best) <= spill("flex2d")
        title = next(t for k, t, _ in FEATURES if k == best)
        lines.append(
            f"  {name}：最好的 3D 特徵是「{title}」，訊雜比 {snr(best, column):.1f}×（2D {base:.1f}×），"
            f"誤觸比 {spill(best):.2f}（2D {spill('flex2d'):.2f}）→ {'通過' if passed else '不通過'}"
        )
    if len(fps_all) < 6:
        lines.append("  延遲：沒有錄完全部階段，只供參考")
    fast = pct(ms, 95) is not None and pct(ms, 95) <= 50 and fps_all and min(fps_all) >= 25
    lines.append(f"  延遲：推論 p95 ≤ 50 ms、fps ≥ 25 → {'通過' if fast else '不通過'}")
    return "\n".join(lines)


if __name__ == "__main__":
    path = sys.argv[1]
    with open(path) as f:
        print(report([json.loads(line) for line in f]))
