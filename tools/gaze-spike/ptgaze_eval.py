"""外觀式注視模型（ptgaze 的 MPIIFaceGaze ResNet）能不能達到粗定位。

    tools/gaze-spike/.venv-cnn/bin/python tools/gaze-spike/ptgaze_eval.py recordings/gaze-<時間>.jsonl [...]

流程：MediaPipe 找臉（沿用 `mediapipe_eval.py` 快取的 478 點，ptgaze 自己的 CPU 模式在 Mac 上會中止）→ 3D 臉模型算頭部姿態 → 正規化成 224×224 的臉部影像 → ResNet 輸出視線的 pitch、yaw。
再用 9 點校準把（視線、頭位置）對應到螢幕，驗證方式同 `mediapipe_eval.py`。輸出快取在
`recordings/gaze-<時間>/ptgaze.npz`（含臉部特徵，只在本機，不進版控）。

相機內參未知：預設焦距 = 影像寬度（ptgaze 的假設）；`GAZE_FOCAL=<像素>` 可改，用來看結果對它敏感不敏感（快取檔名不同）。
權重與快取放在 `tools/gaze-spike/.cache/`，不寫到 `~/`。
"""
import os
import sys
from pathlib import Path

HERE = Path(__file__).parent
os.environ.setdefault("HF_HOME", str(HERE / ".cache" / "hf"))
os.environ.setdefault("TORCH_HOME", str(HERE / ".cache" / "torch"))
sys.path.insert(0, str(HERE))

import cv2  # noqa: E402
import numpy as np  # noqa: E402

import mediapipe_eval as m  # noqa: E402

FOCAL = float(os.environ.get("GAZE_FOCAL", "0")) or None


def estimator(width, height):
    import ptgaze
    from ptgaze.common import Camera
    from ptgaze.gaze_estimator import GazeEstimator
    from ptgaze.head_pose_estimation import HeadPoseNormalizer
    from ptgaze.main import _load_config_file
    from ptgaze.utils import download_mpiifacegaze_model, expanduser_all

    # ptgaze 的臉部偵測用 MediaPipe 的 CPU 模式，在 Mac 上會因缺少 GPU 服務而中止；臉部關鍵點改由快取提供。
    class NoDetector:
        def __init__(self, config):
            pass

        def close(self):
            pass

    ptgaze.gaze_estimator.LandmarkEstimator = NoDetector
    root = Path(ptgaze.__file__).parent
    config = _load_config_file(root / "data/configs/mpiifacegaze.yaml")
    config.PACKAGE_ROOT = root.as_posix()
    config.gaze_estimator.checkpoint = download_mpiifacegaze_model().as_posix()
    # 設定檔預設先載入 ImageNet 的 ResNet18 權重當初始值（會下載），但馬上被上面的檢查點整個覆蓋，不需要。
    config.model.backbone.pretrained = ""
    config.face_detector.mediapipe_model_path = str(m.MODEL)
    config.face_detector.mediapipe_static_image_mode = True
    config.face_detector.mediapipe_max_num_faces = 1
    config.gaze_estimator.use_dummy_camera_params = True
    config.gaze_estimator.dummy_camera_size = [width, height]
    expanduser_all(config)
    est = GazeEstimator(config)
    if FOCAL:
        matrix = np.array([[FOCAL, 0, width // 2], [0, FOCAL, height // 2], [0, 0, 1]], dtype=float)
        est.camera = Camera(width=width, height=height, camera_matrix=matrix, dist_coefficients=np.zeros((5, 1)))
        est._head_pose_normalizer = HeadPoseNormalizer(
            est.camera, est._normalized_camera, config.gaze_estimator.normalized_camera_distance
        )
    return est


def extract(jsonl: Path) -> Path:
    import json

    folder = jsonl.with_suffix("")
    cache = folder / ("ptgaze.npz" if not FOCAL else f"ptgaze-f{int(FOCAL)}.npz")
    if cache.exists():
        return cache
    from ptgaze.common import Face

    frames = [json.loads(line) for line in open(jsonl)]
    est = estimator(frames[0]["width"], frames[0]["height"])
    landmarks = np.load(m.extract(jsonl))
    by_index = {int(i): k for k, i in enumerate(landmarks["index"])}
    index, ok, angles, vector, position = [], [], [], [], []
    for i, frame in enumerate(frames):
        if not frame.get("image"):
            continue
        image = cv2.imread(str(folder / frame["image"]))
        faces = []
        k = by_index[i]
        if landmarks["ok"][k]:
            h, w = image.shape[:2]
            pts = landmarks["landmarks"][k][:468, :2] * [w, h]
            faces = [Face(np.round(np.vstack([pts.min(axis=0), pts.max(axis=0)])).astype(np.int32), pts)]
        index.append(i)
        if not faces:
            ok.append(False)
            angles.append(np.zeros(2))
            vector.append(np.zeros(3))
            position.append(np.zeros(3))
            continue
        est.estimate_gaze(image, faces[0])
        face = faces[0]
        ok.append(True)
        angles.append(face.normalized_gaze_angles)
        vector.append(face.gaze_vector)
        position.append(face.head_position)
    est.close()
    np.savez_compressed(cache, index=index, ok=ok, angles=angles, vector=vector, position=position)
    return cache


def extra_for(jsonl: Path):
    data = np.load(extract(jsonl))
    by_index = {int(i): k for k, i in enumerate(data["index"])}

    def extra(i):
        k = by_index.get(i)
        if k is None or not data["ok"][k]:
            return None
        vx, vy, vz = data["vector"][k]
        hx, hy, hz = data["position"][k]
        return dict(cp=float(data["angles"][k][0]), cyaw=float(data["angles"][k][1]),
                    gvx=float(vx / vz), gvy=float(vy / vz), hx=float(hx), hy=float(hy), hz=float(hz))

    return extra


lin, poly2 = m.lin, m.poly2
MODELS = {
    "CNN 角度 pitch、yaw（一次）": lin("cp", "cyaw"),
    "CNN 視線向量 x/z、y/z（一次）": lin("gvx", "gvy"),
    "CNN 視線向量（二次）": poly2("gvx", "gvy"),
    "CNN 視線向量＋頭位置（一次）": lin("gvx", "gvy", "hx", "hy", "hz"),
    "CNN 角度＋頭位置（一次）": lin("cp", "cyaw", "hx", "hy", "hz"),
    "CNN 視線向量＋虹膜（一次）": lin("gvx", "gvy", "ex", "ey_lid"),
    "CNN 視線向量＋頭位置＋虹膜（一次）": lin("gvx", "gvy", "hx", "hy", "hz", "ex", "ey_lid"),
    "對照：虹膜＋姿態（一次）": m.MODELS["虹膜＋姿態（一次）"],
    "對照：blendshape 2 維（二次）": m.MODELS["眼神 blendshape 2 維（二次）"],
    "對照：只有頭位置（一次）": lin("hx", "hy", "hz"),
}
KEYS = ("cp", "cyaw", "gvx", "gvy", "hx", "hy", "hz", "ex", "ey_lid")

if __name__ == "__main__":
    for path in sys.argv[1:]:
        m.evaluate(Path(path), MODELS, extra_for(Path(path)), KEYS)
