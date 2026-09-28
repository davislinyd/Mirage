#!/usr/bin/env python3
"""MediaPipe HandLandmarker 的深度可行性錄影。

照 mirage-spike 的 depth 腳本依序錄：移動、懸停、按鍵、往前戳、快速移動、日常。每個階段先顯示說明
READING 秒，再倒數 3、2、1，這段期間記錄為 warmup。每幀記錄 2D 關節、相對深度 z、world landmarks（公尺）
與推論耗時。不存影像；準備階段在視窗顯示調暗的相機畫面，方便確認鏡頭與光線，開始後只畫骨架。

用法：.venv/bin/python record.py [--camera 編號] [--size 1552x1552]
"""
import argparse
import datetime
import json
import pathlib
import subprocess
import time

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks import python as mpp
from mediapipe.tasks.python import vision
from PIL import Image, ImageDraw, ImageFont

import analyze

HERE = pathlib.Path(__file__).resolve().parent
READING, COUNTDOWN = 5.0, 3.0
# 同 Sources/MirageCore/Recording.swift 的 Script.depth。
PHASES = [
    ("move", "移動", 10, "先慢後快，在舒適範圍內移動食指"),
    ("hover", "懸停", 10, "伸出食指，讓白圈對準十字、盡量不動；十字會換 3 個位置"),
    ("tap", "按鍵點擊", 15, "食指伸直，只彎指尖兩節往下按再伸直（像按按鈕），指根與手掌不動，10 次"),
    ("push", "往前戳", 15, "食指伸直，整根食指往螢幕方向戳一下再收回（像按電梯按鈕），10 次"),
    ("sweep", "快速移動", 8, "大範圍快速移動食指，偶爾停下"),
    ("daily", "日常", 15, "自然動作：放下手、抓頭、喝水、打字"),
]
# 懸停的十字：鏡像後的畫面比例，原點左下（同 SkeletonView）。
SPOTS = [(0.42, 0.5), (0.58, 0.55), (0.5, 0.42)]
BONES = [
    (0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8), (9, 10), (10, 11), (11, 12),
    (13, 14), (14, 15), (15, 16), (0, 17), (17, 18), (18, 19), (19, 20), (5, 9), (9, 13), (13, 17),
]
FONT = "/System/Library/Fonts/STHeiti Medium.ttc"
VIEW = 900


def builtin_camera():
    """MacBook 內建鏡頭在 OpenCV 的編號；接續互通相機（iPhone）常排在它前面。找不到時為 None。"""
    helper = HERE / "list-cameras"
    if not helper.exists():
        # devicesWithMediaType: 已標為過時，但這正是 OpenCV 用的順序；編譯警告不顯示。
        subprocess.run(["swiftc", "-O", str(HERE / "list-cameras.swift"), "-o", str(helper)], check=True, capture_output=True)
    for line in subprocess.run([str(helper)], capture_output=True, text=True, check=True).stdout.splitlines():
        index, kind, name = line.split("\t", 2)
        print(f"鏡頭 {index}：{name}")
        if kind == "AVCaptureDeviceTypeBuiltInWideAngleCamera":
            return int(index)
    return None


def schedule(elapsed):
    """回傳（記錄的階段, 顯示的階段序號, 剩餘秒數, 距離開始秒數）；流程結束回傳 None。"""
    end = 0.0
    for i, (_, _, duration, _) in enumerate(PHASES):
        start = end + READING + COUNTDOWN
        end = start + duration
        if elapsed < start:
            return "warmup", i, None, start - elapsed
        if elapsed < end:
            return PHASES[i][0], i, end - elapsed, None
    return None


def hands_from(result):
    hands = []
    for i, landmarks in enumerate(result.hand_landmarks):
        category = result.handedness[i][0]
        hands.append({
            "handed": category.category_name,
            "score": round(category.score, 3),
            "lm": [[round(p.x, 5), round(p.y, 5), round(p.z, 5)] for p in landmarks],
            "world": [[round(p.x, 5), round(p.y, 5), round(p.z, 5)] for p in result.hand_world_landmarks[i]],
        })
    return hands


def draw(frame, hands, index, remaining, starts_in, fps, ms, fonts):
    if index is None:
        canvas = (cv2.resize(cv2.flip(frame, 1), (VIEW, VIEW)) * 0.4).astype(np.uint8)
    else:
        canvas = np.zeros((VIEW, VIEW, 3), dtype=np.uint8)
    if index is not None and PHASES[index][0] == "hover":
        duration = PHASES[index][2]
        elapsed = duration - (remaining if remaining is not None else duration)
        x, y = SPOTS[min(2, int(elapsed / (duration / 3)))]
        cx, cy = int(x * VIEW), int((1 - y) * VIEW)
        cv2.line(canvas, (cx - 10, cy), (cx + 10, cy), (0, 215, 255), 2)
        cv2.line(canvas, (cx, cy - 10), (cx, cy + 10), (0, 215, 255), 2)
    for hand in hands:
        points = [(int((1 - p[0]) * VIEW), int(p[1] * VIEW)) for p in hand["lm"]]
        for a, b in BONES:
            cv2.line(canvas, points[a], points[b], (255, 191, 0), 2)
        cv2.circle(canvas, points[8], 12, (255, 255, 255), 2)

    if index is None:
        title = "準備"
        instruction = "把右手舉到鏡頭前；入鏡 1 秒後開始\n畫面不是你、或看不到骨架：按 q 結束，用 --camera 指定鏡頭"
    else:
        title, instruction = PHASES[index][1], PHASES[index][3]
    if starts_in is not None:
        reading = starts_in - COUNTDOWN
        title += f"｜{int(np.ceil(reading))} 秒後倒數" if reading > 0 else "｜即將開始"
    elif remaining is not None:
        title += f"｜剩 {int(np.ceil(remaining))} 秒"
    image = Image.fromarray(canvas[:, :, ::-1])
    pen = ImageDraw.Draw(image)
    pen.multiline_text((20, 20), f"{title}\n{instruction}\n{fps:.0f} fps｜推論 {ms:.1f} ms", font=fonts[0], fill="white", spacing=8)
    if starts_in is not None and starts_in <= COUNTDOWN:
        number = str(int(np.ceil(starts_in)))
        box = pen.textbbox((0, 0), number, font=fonts[1])
        pen.text(((VIEW - box[2]) / 2, (VIEW - box[3]) / 2), number, font=fonts[1], fill="white")
    return np.array(image)[:, :, ::-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--camera", type=int, help="OpenCV 相機編號；預設用 MacBook 內建鏡頭")
    parser.add_argument("--size", default="1552x1552", help="要求的相機格式，同 App 預設")
    args = parser.parse_args()
    width, height = map(int, args.size.split("x"))
    if args.camera is None:
        args.camera = builtin_camera()
        if args.camera is None:
            raise SystemExit("找不到 MacBook 內建鏡頭，請用 --camera 指定編號")

    capture = cv2.VideoCapture(args.camera, cv2.CAP_AVFOUNDATION)
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    capture.set(cv2.CAP_PROP_FPS, 30)
    ok, frame = capture.read()
    if not ok:
        raise SystemExit(f"相機 {args.camera} 無法讀取：確認沒有其他程式（例如 Mirage）正在使用相機")
    height, width = frame.shape[:2]
    # Mac 上 CPU 模式建立時會因缺少 GPU 服務而中止；GPU 模式需要 4 通道輸入。轉成 GPU 影像時紅藍可能對調，
    # 所以準備階段兩種順序輪流試，先偵測到手的那種用到最後。VIDEO 模式的時間戳要遞增，每種順序各用一個實例。
    def create():
        return vision.HandLandmarker.create_from_options(vision.HandLandmarkerOptions(
            base_options=mpp.BaseOptions(model_asset_path=str(HERE / "hand_landmarker.task"), delegate=mpp.BaseOptions.Delegate.GPU),
            running_mode=vision.RunningMode.VIDEO,
            num_hands=1,
        ))
    orders = {"RGBA": (cv2.COLOR_BGR2RGBA, create()), "BGRA": (cv2.COLOR_BGR2BGRA, create())}
    order, found = None, {"RGBA": 0, "BGRA": 0}
    fonts = (ImageFont.truetype(FONT, 24), ImageFont.truetype(FONT, 160))
    total = sum(p[2] + READING + COUNTDOWN for p in PHASES)
    print(f"相機 {args.camera}：{width}×{height}、{capture.get(cv2.CAP_PROP_FPS):.0f} fps。接下來依序有 {len(PHASES)} 個階段，共約 {total:.0f} 秒；按 q 或 Esc 提前結束。")
    print("\n▶ 準備：把右手舉到鏡頭前；入鏡 1 秒後開始")

    records, recent = [], []
    begin = time.monotonic()
    start = seen_since = shown = None
    count = 0
    while True:
        ok, frame = capture.read()
        if not ok:
            break
        t = time.monotonic()
        name = order or ("RGBA", "BGRA")[count % 2]
        count += 1
        conversion, landmarker = orders[name]
        tick = time.perf_counter()
        image = mp.Image(image_format=mp.ImageFormat.SRGBA, data=cv2.cvtColor(frame, conversion))
        result = landmarker.detect_for_video(image, int((t - begin) * 1000))
        ms = (time.perf_counter() - tick) * 1000
        hands = hands_from(result)
        if order is None and hands:
            found[name] += 1
            if found[name] >= 5:
                order = name
                print(f"色彩順序：{order}")

        # 手連續入鏡 1 秒後才開始計時。
        if start is None:
            seen_since = (seen_since or t) if hands else None
            if seen_since is not None and t - seen_since >= 1:
                start = t
        state = schedule(t - start) if start is not None else ("warmup", None, None, None)
        if state is None:
            break
        phase, index, remaining, starts_in = state
        if index is not None and index != shown:
            shown = index
            print(f"\n▶ {PHASES[index][1]}（{PHASES[index][2]} 秒）：{PHASES[index][3]}")
        records.append({"t": round(t, 4), "phase": phase, "w": width, "h": height, "ms": round(ms, 2), "hands": hands})

        recent = [x for x in recent if t - x < 1] + [t]
        fps = (len(recent) - 1) / (recent[-1] - recent[0]) if len(recent) > 1 else 0
        cv2.imshow("Mirage MediaPipe depth", draw(frame, hands, index, remaining, starts_in, fps, ms, fonts))
        if cv2.waitKey(1) in (27, ord("q")):
            break

    capture.release()
    cv2.destroyAllWindows()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    path = HERE.parent.parent / "recordings" / f"mediapipe-depth-{stamp}.jsonl"
    path.parent.mkdir(exist_ok=True)
    path.write_text("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in records))
    print(analyze.report(records))
    print(f"\n紀錄已存到 {path}")


if __name__ == "__main__":
    main()
