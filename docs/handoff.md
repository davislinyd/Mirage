# Mirage 交接（2026-09-29）

接手時先讀這份文件、`README.md`（手勢、使用方式、各項評估結果）與 `docs/devlog.md`（每個決定的數據依據）。

## 狀態

- M0–M3 完成，合併在 `main`。
- M3 有單元測試與重播測試，App 已建置，但還沒在實機長時間試用。
- 目前的手勢：
  - 左鍵（按鍵）：只彎食指指尖兩節往下按。
  - 拖曳：按住約 0.5 秒後移動手。
  - 右鍵（單指扳機）：拇指壓到食指側面，抬起時送出。
  - 縮放：扳機按住 0.5 秒後，手往上放大、往下縮小，送 ⌘= / ⌘−。
  - 捲動：兩指彎曲時內容往下，三指彎曲時內容往上；收回中指就結束。
  - ESC：捲動中做一次扳機。
- 其他功能：
  - 操作者鎖定：只跟著喚醒的那隻手。
  - HUD：控制中在主螢幕右上角顯示目前模式。
- 眼動、2.5D 深度、MediaPipe 都評估過，不可行，結果見 README。

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
  - `Scroller`
- `tools/mediapipe-spike/`：評估紀錄。虛擬環境與模型不進版控，重建方式見 README。

## 常用指令

- `swift build`、`swift test`
- `scripts/build-app.sh`：產生 `build/Mirage.app`。
- `open build/Mirage.app`：舊版在執行時，要先從選單列結束 Mirage。
- 錄影：`swift run -c release mirage-spike <m0|gestures|precision|controls|gaze|depth>`，存到 `recordings/`。
  - 錄影前先結束 Mirage，否則相機被占用。
  - 錄影時不要同時編譯，否則會掉幀。
- 動作紀錄：`/usr/bin/log stream --predicate 'subsystem == "io.github.davislinyd.Mirage"' --level info --style compact`
  - zsh 有同名的內建指令，所以要寫完整路徑。

## 做法

- 參數由錄影決定：
  1. 錄影。
  2. 在 `RecordingReplayTests` 重播，量出分布。
  3. 先寫會失敗的測試，再調參數。
  4. 用沒參與調整的新錄影驗證。
- 錄影只在本機，CI 上沒有錄影，重播測試會自動略過。
- 不要 commit `recordings/`、`.ai/`、`build/`。
- 回覆用繁體中文，簡潔。commit、push、開 PR、刪除分支前都先問 Davis。

## 已知問題與待辦

1. 實機試用 M3：Safari 縮放、右鍵在拇指抬起時出現、HUD 切換、另一隻手出現在畫面時。
2. 日常使用 1 小時，用動作紀錄確認 0 誤觸。
3. 按得很輕（13–17°）的按鍵會漏，常出現在右上角的目標；門檻 20° 先不動。
4. 重播時，部分錄影的「日常」階段會捲動幾百 pt。這是改動前就有的，還沒處理。
5. 堆疊的 PR #1–#5 已合併或關閉，舊分支已刪除，只剩 `main`。
6. M4 延後：Developer ID、公證、dmg、Sparkle。
