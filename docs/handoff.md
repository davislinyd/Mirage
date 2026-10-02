# Mirage 交接（2026-09-30）

接手時先讀這份文件、`README.md`（手勢、使用方式、各項評估結果）與 `docs/devlog.md`（每個決定的數據依據）。

## 眼動追蹤：已評估，停損（2026-09-29，沒有整合）

- 結果、數字與重現方式在 `README.md` 的 `gaze` 一節，過程在 `docs/devlog.md`。
- 一句話：內建螢幕上，Vision 瞳孔、MediaPipe、CNN（ptgaze MPIIFaceGaze）都沒有達到粗定位的標準（p50 ≤ 250、p90 ≤ 450 pt）；外接螢幕上 CNN 接近標準，但 App 控制的是內建螢幕。
- 更正舊結論：09-28 評估用的 Vision 頭部角度沒有資訊，「只看頭」其實只看臉的位置。
- 可以直接沿用：
  - `mirage-spike gaze --frames --builtin`：注視階段存影像（`recordings/gaze-<時間>/frames/`），並固定在內建螢幕；開始時會印出使用的螢幕。
  - `tools/gaze-spike/`：`analyze.py`（Vision，純標準函式庫）、`mediapipe_eval.py`、`ptgaze_eval.py`；同一套 9 點校準與驗證。
  - `Sources/MirageCore/Gaze.swift` 與 `GazeTests`。
- 想重啟時，還沒試過：
  - 第二份內建螢幕錄影，確認內建的失敗是不是可重現。
  - ETH-XGaze（`hysts/ptgaze-eth-xgaze-resnet18`）與 MPIIGaze 眼睛模型，需要另外下載權重。
  - 更高解析度或更近的相機；用點擊當隱性校準。
- 重啟前先決定用哪個螢幕：錄影與 App 要對到同一個。授權見 README（權重的訓練資料限非商業）。
- 若整合，延遲的做法：臉部偵測不要和手放在同一條推論管線，10 Hz 就夠。App 的管線在 `Sources/Mirage/HandTracker.swift`：`queue` 處理狀態，`workQueue` 做推論，忙碌時只留最新一幀。

## 狀態

- M0–M3 與甩動捲動（`358a7ad`、`d6b9389`）都在 `main`，已 push 到 `origin/main`。
- 目前的手勢：
  - 左鍵（按鍵）：只彎食指指尖兩節往下按。
  - 拖曳：按住約 0.5 秒後移動手。
  - 右鍵（單指扳機）：拇指壓到食指側面，抬起時送出；手在動時不算。
  - 縮放：扳機按住 0.5 秒後，手往上放大、往下縮小，送 ⌘= / ⌘−。
  - 捲動（甩動）：
    - 兩指伸直後，指尖往上或往下快速一甩，就往那個方向捲。
    - 速度看甩得多快，約 2 秒減速停下；連續甩就一直捲。
    - 慢慢收回不捲；甩完 1.2 秒內不接受反方向。
    - 收回中指就結束。
  - ESC：捲動中做一次扳機；同右鍵，手在動時不算。
  - 三指揮動（左右換桌面、⌃↑ 實機確認可用；門檻用第一份 `desktop` 錄影定，**還沒用新錄影驗證**）：食指、中指、無名指伸直、小指收起，游標停住；手往右快速一揮送 ⌃←、往左送 ⌃→、往上送 ⌃↑（Mission Control），同觸控板；往下、慢慢收回不算；換方向要停 0.5 秒。兩份錄影重播：往右 6/10 與 15 下、往左 7/10 與 7/12、往上 5/10 與 7/13，慢慢移動階段誤觸 0 與 3 次，其他階段 0。
  - ⌘M（縮到 Dock）：張手停一下後五指尖捏成一點；參數來自三份 `gather`，第二次實機試用很容易觸發、握拳沒有誤觸。
- 其他功能：
  - 操作者鎖定：只跟著喚醒的那隻手。
  - HUD：控制中在主螢幕右上角顯示目前模式。
- 2.5D 深度、MediaPipe 手部模型與眼動都評估過，不可行；眼動見上一節。結果都在 README。

## 專案結構

- SwiftPM，Swift 6，macOS 26+。
  - `MirageCore`：純邏輯，可測試。
  - `Mirage`：選單列 App。
  - `mirage-spike`：錄影與分析工具。
  - `MirageCoreTests`：Swift Testing。
- 手勢主要在 `Sources/MirageCore/`：
  - `Control.swift`（`CursorController`）
  - `OperatorLock`、`PointerStabilizer`
  - `TapDetector`、`TapClicker`（左鍵與拖曳）
  - `TriggerDetector`（右鍵、ESC、縮放）
  - `Scroller`（甩動捲動）、`ScrollSmoother`（App 端約 120 Hz 平均送出捲動）
  - `DesktopSwiper`（三指揮動，`HandTracker.press(desktop:)` 送 ⌃ 方向鍵）
  - `GatherDetector`（五指捏合 → ⌘M）
- 評估：`Gaze.swift`（眼動）、`DepthAnalysis.swift`（2.5D）；`tools/mediapipe-spike/`（手）與 `tools/gaze-spike/`（眼動）（虛擬環境、模型與快取不進版控）。

## 常用指令

- `swift build`、`swift test`
- `scripts/build-app.sh`：產生 `build/Mirage.app`。
- `open build/Mirage.app`：舊版在執行時，要先從選單列結束 Mirage。
- 錄影：`swift run -c release mirage-spike <m0|gestures|precision|controls|gaze|depth|swipe|desktop|gather>`，存到 `recordings/`；`gaze` 可加 `--frames`（存影像）與 `--builtin`（固定內建螢幕）。
  - 錄影前先結束 Mirage，否則相機被占用。
  - 錄影時不要同時編譯，否則會掉幀。
- 動作紀錄：`/usr/bin/log stream --predicate 'subsystem == "io.github.davislinyd.Mirage"' --level info --style compact`
  - zsh 有同名的內建指令，所以要寫完整路徑。
  - 實機試用時在背景存到檔案，試完再分析；捲動中每幀記錄食指高度與捲動量。

## 做法

- 參數由錄影決定：
  1. 錄影。
  2. 在 `RecordingReplayTests` 重播，量出分布。
  3. 先寫會失敗的測試，再調參數。
  4. 用沒參與調整的新錄影驗證。
- 錄影只在本機，CI 上沒有錄影，重播測試會自動略過。
- 不要 commit `recordings/`、`.ai/`、`build/`。
- repo 是公開的：commit 與文件不放內部資訊（公司網址、email 等）。
- 回覆用繁體中文，簡潔。commit、push、開 PR、刪除分支前都先問 Davis。

## 已知問題與待辦（手勢）

1. 實機試用 M3：Safari 縮放、右鍵在拇指抬起時出現、HUD 切換、另一隻手出現在畫面時。
2. 日常使用 1 小時，用動作紀錄確認 0 誤觸。
3. 按得很輕（13–17°）的按鍵會漏，常出現在右上角的目標；門檻 20° 先不動。
4. 甩動捲動：三份 `swipe` 錄影反向捲動都是 0，第三次實機試用感覺良好。重播時，部分錄影的「日常」階段意外進入捲動後會誤捲幾百 pt，改動前就有，還沒處理。
5. 甩動的已知限制：
   - 換方向要等上一次甩動開始後 1.2 秒；比預備動作（1.07 秒）只晚 0.13 秒。
   - 往上滑得太慢、沒算成一甩時，它的回程若快（約 6 掌寬/秒），仍可能被當成往下甩。
   - 捲動中握拳再伸直：握拳就是往下甩，伸直得快也會往上捲。
6. 三指揮動（依序做）：
   - 再錄第三份 `swift run -c release mirage-spike desktop` 當驗證：前兩份都用來調過參數了（見 devlog），`DesktopReplayTests` 的 `Replay.desktop` 加進新檔名。
   - 刻意的一揮和快一點的移動用速度分不開（第二份「慢慢移動」峰值到 5.9，一揮 3.5–9.8）：`sideSpeed` 4.5 → 誤觸 6 次，6.0 → 0 次但少抓 2–4 下。現在取 5.0、誤觸 3 次；要更少誤觸就得換特徵，不是再調門檻。
   - 往上揮抓到 5/10、7/13：抬手峰值 3.1–6.5，是抬手途中才伸出三指，姿勢只比峰值早 0.03–0.07 秒。往左揮三指只在動作開頭出現 1–2 幀。
   - `refractory` 0.5 秒（換方向要停多久）是實機後的暫定值；回程最快 4.4，低於左右揮的門檻 5.0。
   - 實機看：新參數、⌃↑ 開了 Mission Control 之後再揮一次能不能關；日常使用 1 小時 0 誤觸。
   - 已知風險：無名指要獨立伸直，有些人不好做；三指只要連續兩幀就啟動，擋誤觸靠速度門檻。
6b. 耗電：待命時手部偵測降到約 10 fps（`FrameThrottle`），實測待命 CPU 18–28% → 11–14%（見 devlog）。實機看：待命時喚醒手勢（張手 → 握拳）有沒有比以前難喚醒。想再降：待命時降相機本身的幀率，或一段時間沒看到手就自動暫停。
7. M4 延後：Developer ID、公證、dmg、Sparkle。
8. 五指捏合（⌘M）：實機試用通過；握拳的指尖高度與拇指距離各自都有接近門檻的時候（見 `GatherDetector`）。還要：既有錄影（在主 checkout 的 `recordings/`）重播 `otherRecordingsDoNotMinimize` 確認 0 誤觸；日常使用時用動作紀錄看 `minimize` 有沒有誤觸。
