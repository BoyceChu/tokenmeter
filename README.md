# TokenMeter

常駐在 macOS 系統列，監控這台 Mac 上 Claude 的 Token 用量與方案額度。

## 安裝

1. 到 [Releases](../../releases/latest) 下載最新的 `TokenMeter-x.x.x.dmg`
2. 打開 DMG，把 **TokenMeter** 拖進 **Applications**
3. 從「應用程式」打開 TokenMeter

第一次打開如果出現「無法驗證開發者」：到「系統設定」→「隱私權與安全性」，往下捲，按「**仍要打開**」。只需要做一次。

第一次查詢額度時，macOS 會問是否允許存取鑰匙圈，請按「**永遠允許**」。

## 功能

- **系統列**：5 小時工作階段使用率；額度到 90% 或脈絡超過 120k 時顯示 ⚠
- **方案額度剩餘**：5 小時工作階段、本週所有模型、本週個別模型
- **完整儀表板**：以「回合」（你送出一則訊息到 Claude 做完回覆）為節點的時間軸
  - 每回合拆成過程（讀取脈絡、寫入快取、新輸入、思考與工具呼叫、子代理）與結果（最後回覆）
  - 異常判定：超過專案回合中位數 3 倍偏高、6 倍異常，並說明原因與改善方式
  - 依專案、時間篩選；每日用量；依模型與專案；可以改善的習慣
- **開機自動啟動**：面板右下角可切換

## 自動監控的位置

| 來源 | 位置 |
|---|---|
| Claude Code（終端機、VS Code、JetBrains、Agent SDK） | `~/.claude/projects` |
| Claude Code（自訂設定） | `$CLAUDE_CONFIG_DIR/projects`、`~/.config/claude/projects` |
| Claude 桌面版的 Code／Cowork | `~/Library/Application Support/Claude` |

claude.ai 網頁、手機與桌面版的一般聊天存在雲端，本機沒有 Token 記錄，只會反映在方案額度裡。

## 方案額度說明

TokenMeter 讀取 Claude Code 存在鑰匙圈的登入資料，向 `api.anthropic.com` 查詢使用率，資料不會送到其他地方。這個查詢端點是 Claude Code 的 `/usage` 指令所使用的，尚未公開文件化，日後可能變動。需要曾在 Claude Code 用訂閱帳號登入過。

## 自己編譯

需要 Xcode（完整版）：

```bash
bash scripts/build.sh
```

產出在 `build/TokenMeter-1.0.0.dmg`。
