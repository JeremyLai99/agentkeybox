# AgentKeyBox

[English](README.md)

**AgentKeyBox 是給 AI 程式代理用的本機金鑰保管箱。**

把 API 金鑰交給 AgentKeyBox 保管一次，依專案整理好。Claude Code 或 Codex 需要用金鑰時，會先問你，你按「允許」才會用到。

> **AI 開口問，你來決定。**

適合 vibe coder、獨立開發者，以及不想讓 API 金鑰散落在 `.env` 檔、筆記、下載資料夾、終端機紀錄或聊天視窗裡的人。

## 安裝

**需要：** macOS 14（Sonoma）以上、Apple Silicon 晶片的 Mac（M1 以後），以及 Claude Code 或 Codex。Touch ID 不是必要的，沒有的話 macOS 會改問你的登入密碼。

1. 到[最新版本頁面](https://github.com/JeremyLai99/agentkeybox/releases/latest)下載 `AgentKeyBox-<版本>-macOS.zip`。
2. 雙擊 zip 檔解壓縮，再打開 **AgentKeyBox**。macOS 會問「要打開從網際網路下載的 App 嗎？」，請選「**打開**」。這個 App 已經用 Developer ID 簽章，並通過 Apple 公證。
3. 如果視窗上方出現「AgentKeyBox 還沒放進『應用程式』資料夾」，按「**移到『應用程式』**」，它會自己搬過去並重新打開。
4. 把你的專案資料夾拖進視窗（或按「**選擇資料夾…**」）。AgentKeyBox 會列出在 `.env` 檔和金鑰檔（`.p8`、`.pem`、服務帳戶 JSON）裡找到的金鑰，看起來是機密的已經幫你勾好。按「**設定**」後：
   - 金鑰會移進你的鑰匙圈，檔案留在原處。
   - 還沒被 git 忽略的 `.env` 檔，可以順手加進 `.gitignore`。
   - 有安裝 Claude Code 或 Codex 的話，會一起連接好。
5. 在那個專案裡開一個**新的** Claude Code 或 Codex 工作階段。代理需要金鑰時，AgentKeyBox 會跳出視窗問你，按「**允許一次**」再按 Touch ID 就好。

介面語言會跟著 macOS（英文或繁體中文），也可以在「**設定 › 語言**」切換。

想確認下載的檔案沒被竄改，可以執行 `shasum -a 256 AgentKeyBox-<版本>-macOS.zip`，和版本頁面上的 `.sha256` 檔比對。

### 更新

下載新版本、打開它，然後按「**移到『應用程式』**」。舊版會移到垃圾桶。你的專案、金鑰和代理連接都會保留：金鑰存在鑰匙圈裡，代理用的連接程式放在固定位置，每個版本啟動時都會自動更新它。

### 移除

1. 在 AgentKeyBox 裡，對每個專案按右鍵，選「**移除專案…**」，它的金鑰會從鑰匙圈刪除。「**通用金鑰**」也用同樣方式刪除（在金鑰上按右鍵 › 「**刪除…**」）。只刪掉 App 的話，金鑰會留在鑰匙圈裡。
2. 中斷程式代理的連接：

   ```bash
   claude mcp remove --scope user agentkeybox
   codex mcp remove agentkeybox
   ```

3. 結束 AgentKeyBox（選單列圖示 › 「**結束 AgentKeyBox**」），再把它從「應用程式」資料夾丟到垃圾桶。
4. 刪除它在本機的設定和連接程式：

   ```bash
   rm -rf ~/Library/Application\ Support/AgentKeyBox
   defaults delete dev.agentkeybox.app
   ```

## 它怎麼保護你的金鑰

- 金鑰存在 macOS 鑰匙圈裡，每次使用都要你核准，並通過 Touch ID 或登入密碼。
- AI 代理拿不到金鑰本身。AgentKeyBox 會在你核准後代為呼叫 API 或執行指令，回傳的結果會把金鑰遮蔽掉。
- 金鑰可以限定只送到特定網站（例如 Stripe 金鑰只能送到 `api.stripe.com`）。要送到其他網站時，會用醒目的警告問你。
- 不需要帳號，也沒有雲端服務，所有東西都留在你的 Mac 上。

**這不是完整的沙盒**：你核准執行的指令，仍然有可能刻意把金鑰送出去。所以核准視窗會清楚顯示要執行的指令，並標出比較危險的情況。詳細說明請看 [SECURITY.md](SECURITY.md)（英文）。

## 目前狀態

**實驗性 alpha 版。** 已在真實的 Mac 上驗證：Touch ID 保護的鑰匙圈、核准視窗、工作階段內不再詢問、Developer ID 簽章與公證，以及下載安裝流程。還沒做完整驗證的是：實際 Claude Code 與 Codex 工作階段從頭到尾使用這些工具的流程。

開發者文件（從原始碼建置、`akb` 指令、MCP 工具說明）請看[英文 README](README.md)。

## 授權

Apache License 2.0，詳見 [LICENSE](LICENSE)。
