# AgentKeyBox

[English](README.md)

**AgentKeyBox 是給 AI 程式代理用的本機金鑰保管箱。**

把 API 金鑰交給 AgentKeyBox 保管一次，依專案整理好。Claude Code 或 Codex 需要用金鑰時，會先問你，你按「允許」才會用到。

> **AI 開口問，你來決定。**

適合 vibe coder、獨立開發者，以及不想讓 API 金鑰散落在 `.env` 檔、筆記、下載資料夾、終端機紀錄或聊天視窗裡的人。

## 安裝

**需要：** macOS 14（Sonoma）以上的 Mac（Apple 晶片或 Intel 晶片都可以），以及 Claude Code 或 Codex。Touch ID 不是必要的，沒有的話 macOS 會改問你的登入密碼。

1. 到[最新版本頁面](https://github.com/JeremyLai99/agentkeybox/releases/latest)下載 `AgentKeyBox-<版本>-macOS.zip`。
2. 雙擊 zip 檔解壓縮，再打開 **AgentKeyBox**。macOS 會問「要打開從網際網路下載的 App 嗎？」，請選「**打開**」。這個 App 已經用 Developer ID 簽章，並通過 Apple 公證。
3. 如果視窗上方出現「AgentKeyBox 還沒放進『應用程式』資料夾」，按「**移到『應用程式』**」，它會自己搬過去並重新打開。
4. 把你的專案資料夾拖進視窗（或按「**選擇資料夾…**」）。AgentKeyBox 會列出在 `.env` 檔和金鑰檔（`.p8`、`.pem`、服務帳戶 JSON）裡找到的金鑰，看起來是機密的已經幫你勾好。按「**設定**」後：
   - 金鑰會移進你的鑰匙圈，檔案留在原處。
   - 還沒被 git 忽略的 `.env` 檔，可以順手加進 `.gitignore`。
   - 有安裝 Claude Code 或 Codex 的話，會一起連接好。
5. 在那個專案裡開一個**新的** Claude Code 或 Codex 工作階段。代理需要金鑰時，AgentKeyBox 會跳出視窗問你，按「**允許一次**」再按 Touch ID 就好。

介面語言會跟著 macOS（英文或繁體中文），也可以在「**設定 › 語言**」切換。

不需要一直開著 AgentKeyBox：它會在你登入時自動開啟；就算關掉了，Claude Code、Codex 和 `akb` 需要金鑰時也會自動在選單列打開它。這兩項預設都是開啟，可以在「**設定 › 啟動**」關掉。

**請保留金鑰的備份。** AgentKeyBox 的那份金鑰只存在這台 Mac 的鑰匙圈裡：不會同步到 iCloud，換電腦時「遷移輔助程式」也不會帶過去。所以設定時不會刪掉你的 `.env` 和金鑰檔。為了不讓程式代理去讀這些檔案，設定時（預設開啟）會在專案的 `AGENTS.md`、`CLAUDE.md` 加入說明，並在 `.claude/settings.local.json` 加入 Claude Code 的禁止讀取規則。Claude Code 會對它的讀檔工具和常見的 shell 指令強制執行這些規則；對其他代理來說，則是寫給它們看的說明。說明只在代理從專案資料夾啟動時才會被讀到，而且使用者直接要求時，代理仍可能去讀檔案。要徹底移除明文，請先匯出加密備份（設定 › 備份），再到專案選單選「從檔案移除金鑰…」。

### 備份，以及把金鑰從檔案移除

- **設定 › 備份 › 匯出備份…** 會把你所有的專案和金鑰寫進一個有密碼保護的 `.dmg` 檔（AES-256 加密的 macOS 磁碟映像檔）。請把檔案和密碼存在安全的地方；在另一台 Mac 上用 **匯入…** 就能還原。
- 不用 AgentKeyBox 也能打開備份：點兩下 `.dmg`、輸入密碼，就會看到每個專案一個資料夾，裡面有它的 `.env` 和金鑰檔（`.p8`、`.pem`、`.json`），另附一份 README 列出內容。詳見 [docs/BACKUP_FORMAT.md](docs/BACKUP_FORMAT.md)。
- 做過備份後，在專案上按右鍵 › **從檔案移除金鑰…**，會清空該專案 `.env` 檔裡的這些金鑰，並把金鑰檔移到垃圾桶，讓程式代理完全讀不到。只有和 AgentKeyBox 存的內容完全相同的值才會被移除。之後你的 App 要從 AgentKeyBox 取得金鑰：請用 `akb run -- npm run dev`（或你自己的指令）啟動。

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

## 接入其他 AI 代理

AgentKeyBox 提供的是標準的 [MCP](https://modelcontextprotocol.io)（stdio）接口。Claude Code 和 Codex 可以一鍵連接；其他**在你 Mac 上執行**、而且支援本機（stdio）MCP 伺服器的代理，可以在它的 MCP 設定裡手動加入：

- **指令：** `~/Library/Application Support/AgentKeyBox/bin/agentkeybox-mcp`（如果代理不認得 `~`，請寫出完整路徑）
- **環境變數：**
  - `AGENTKEYBOX_AGENT_ID`：簡短的代號，例如 `gemini-cli`
  - `AGENTKEYBOX_AGENT_NAME`：核准視窗上顯示的名稱，例如 `Gemini CLI`。沒設定這兩個的話，視窗會顯示「Coding Agent」。
  - `AGENTKEYBOX_PROJECT_PATH`：專案資料夾。如果代理不是從專案資料夾啟動 MCP，就用這個指定；不設定時，AgentKeyBox 會用連接程式啟動時所在的資料夾判斷，不在任何專案裡的話，代理只看得到「通用金鑰」。

很多代理的設定長得像下面這樣，但確切的檔案位置和欄位名稱請以該代理的官方文件為準：

```json
{
  "mcpServers": {
    "agentkeybox": {
      "command": "/Users/你的帳號/Library/Application Support/AgentKeyBox/bin/agentkeybox-mcp",
      "env": {
        "AGENTKEYBOX_AGENT_ID": "my-agent",
        "AGENTKEYBOX_AGENT_NAME": "My Agent"
      }
    }
  }
}
```

Gemini CLI、VS Code 裡的 GitHub Copilot、Cursor、Windsurf、Cline，以及 Meta 的 Muse Code 都支援本機 MCP 伺服器，照這個方式應該可以接上，但 AgentKeyBox **還沒有實際測試過**。

在雲端執行的代理，例如 OpenAI 的 Dots、Meta 的 Muse App、Codex 的雲端任務，沒辦法使用 AgentKeyBox。連接程式只會和同一台 Mac 上的 AgentKeyBox 溝通，你的金鑰永遠不會離開你的電腦。這是刻意的設計。

## 它怎麼保護你的金鑰

- 金鑰存在 macOS 鑰匙圈裡，每次使用都要你核准，並通過 Touch ID 或登入密碼。
- AI 代理拿不到金鑰本身。AgentKeyBox 會在你核准後代為呼叫 API 或執行指令，回傳的結果會把金鑰遮蔽掉。
- 金鑰可以限定只送到特定網站（例如 Stripe 金鑰只能送到 `api.stripe.com`）。要送到其他網站時，會用醒目的警告問你。
- 不需要帳號，也沒有雲端服務，所有東西都留在你的 Mac 上。

**這不是完整的沙盒**：你核准執行的指令，仍然有可能刻意把金鑰送出去。所以核准視窗會清楚顯示要執行的指令，並標出比較危險的情況。詳細說明請看 [SECURITY.md](SECURITY.md)（英文）。

## 目前狀態

**實驗性 alpha 版。** 已在真實的 Mac 上驗證：Touch ID 保護的鑰匙圈、核准視窗、工作階段內不再詢問、Developer ID 簽章與公證，以及下載安裝流程。也已經用真正的 Claude Code 和 Codex 工作階段從頭到尾驗證過。

開發者文件（從原始碼建置、`akb` 指令、MCP 工具說明）請看[英文 README](README.md)。

## 授權

Apache License 2.0，詳見 [LICENSE](LICENSE)。
