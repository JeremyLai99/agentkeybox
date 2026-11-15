# 復原碼搭配登入：實作與驗證紀錄

驗證日期：2026-11-15。分支：`feat/recovery-linked-login`；基底：`9e12f5f`。

## 提交與完整改動檔案

功能 1、2、3 各自提交並附測試；另有一個固定錯誤傳遞／驗收 client 相容性修正提交。文件在最後提交，沒有 amend、reset、stash 或 push。

### 1b1f06e feat: link recovery codes to website logins

```text
Sources/AgentKeyBoxApp/AgentKeyBoxApp.swift
Sources/AgentKeyBoxApp/MainWindow.swift
Sources/AgentKeyBoxApp/SensitiveItemView.swift
Sources/AgentKeyBoxCore/BrokerProtocol.swift
Sources/AgentKeyBoxCore/BrowserRecovery.swift
Sources/AgentKeyBoxCore/ControlledBrowser.swift
Sources/AgentKeyBoxCore/DevelopmentRecoveryFixture.swift
Sources/AgentKeyBoxCore/MetadataStore.swift
Sources/AgentKeyBoxCore/Models.swift
Sources/AgentKeyBoxCore/SensitivePayload.swift
Sources/AgentKeyBoxCore/SensitiveSubmission.swift
Sources/AgentKeyBoxCore/Translations.swift
Sources/AgentKeyBoxMCP/main.swift
Tests/AgentKeyBoxCoreTests/BackupArchiveTests.swift
Tests/AgentKeyBoxCoreTests/BrowserRecoveryTests.swift
Tests/AgentKeyBoxCoreTests/BrowserTests.swift
Tests/AgentKeyBoxCoreTests/CredentialUsePolicyTests.swift
```

### 6f1b402 feat: cache conservative recovery code counts in metadata

```text
Sources/AgentKeyBoxApp/AgentKeyBoxApp.swift
Sources/AgentKeyBoxApp/MainWindow.swift
Sources/AgentKeyBoxApp/SensitiveItemView.swift
Sources/AgentKeyBoxCore/BrokerProtocol.swift
Sources/AgentKeyBoxCore/BrowserPolicy.swift
Sources/AgentKeyBoxCore/BrowserRecovery.swift
Sources/AgentKeyBoxCore/ControlledBrowser.swift
Sources/AgentKeyBoxCore/DevelopmentRecoveryFixture.swift
Sources/AgentKeyBoxCore/DevelopmentSubmissionFixture.swift
Sources/AgentKeyBoxCore/Models.swift
Sources/AgentKeyBoxCore/RecoveryCodeMetadata.swift
Sources/AgentKeyBoxCore/SensitiveSubmission.swift
Sources/AgentKeyBoxCore/Translations.swift
Tests/AgentKeyBoxCoreTests/BackupArchiveTests.swift
Tests/AgentKeyBoxCoreTests/BrowserRecoveryTests.swift
Tests/AgentKeyBoxCoreTests/BrowserTests.swift
Tests/AgentKeyBoxCoreTests/RecoveryCodeMetadataTests.swift
```

### 61e656d fix: show recovery reservation guidance only for recovery submissions

```text
Sources/AgentKeyBoxCore/SensitiveSubmission.swift
Sources/AgentKeyBoxCore/Translations.swift
Sources/AgentKeyBoxMCP/main.swift
Tests/AgentKeyBoxCoreTests/SensitiveItemTests.swift
```

### f160baf fix: preserve browser-only diagnostics and update recovery acceptance checks

```text
Scripts/recovery-acceptance-client.py
Scripts/submission-acceptance-client.py
Scripts/test-browser-acceptance-client.py
Sources/AgentKeyBoxCore/SensitiveSubmission.swift
Sources/AgentKeyBoxCore/Translations.swift
Sources/AgentKeyBoxMCP/main.swift
Tests/AgentKeyBoxCoreTests/SensitiveItemTests.swift
```

最後文件提交（hash 見交付訊息）包含：

- `CHANGELOG.md`：Unreleased 三行。
- `README.md`、`README.zh-TW.md`：搭配網站登入後不用填網址。
- `docs/MACOS_TEST.md`：原生驗收步驟與預期結果。
- `docs/RECOVERY_LINKED_LOGIN_VERIFICATION.md`：本紀錄。

## 資料與安全邊界

`CredentialMetadata` 新增選填的 `linkedLoginID`、`recoveryCodeCounts`、`recoveryCodePendingRevision`；舊資料缺少欄位仍可解碼。摘要只含 available、used、needsReview 數量；issued 合併到 needsReview，因為其遠端結果尚未確認。format 2 的 metadata 往返保留搭配 ID 與摘要；真正匯入時依還原後 payload 重算摘要，Used 維持 Used，其他狀態需要確認，可用數歸零。

搭配模式要求 recovery item 與 session login 的 ID、專案相符，並使用 `BrowserPolicy.permits` 檢查同源（HTTPS、host、port）。表單路徑不需等於登入頁路徑；目標來自私密瀏覽器偵測的表單，不能由 agent 指定。未搭配項目仍需要目的網址完全相等。`submit_sensitive_fields` 一律需要原生設定的完整網址；只有搭配、未填網址的項目透過固定白名單錯誤告知只能使用 `browser_recover`。核准窗繼續顯示完整實際目標。

原生編輯器只列同專案、網址有效的登入；新增時只有一個選項便預選，多個時預設不搭配。儲存搭配後會清掉舊 submissionURL，解除搭配不會復活舊網址。刪除登入時，解除引用與刪除 metadata 在同一次提交完成，復原碼本身保留；移除專案也使用相同解除引用邏輯。MCP 沒有新增任何 metadata 修改入口。

`ownedBrowser` 在要求前、驗證後及非同步頁面操作後比較 session 的完整 login metadata 快照與目前資料，並重查專案可見性。原生登入編輯、刪除或移除專案也透過既有 `invalidateProtectedAccess` 關閉相關瀏覽器。復原碼另有完整快照、核准版本及 payload revision 檢查；修改搭配或刪除項目不能沿用舊核准。登入換專案、改 URL 或被刪除後，舊 session 無法繼續使用其復原碼。

## 計數提交與修復

清單與主視窗只讀 metadata；不為計數讀鑰匙圈。舊項目沒有摘要時回傳 `codes=unknown`，不猜測可用數。已知可用數為零時，`prepareRecovery` 在切換至等待核准之前回固定錯誤，不開核准窗。

- **保留（browser 與獨立提交共用）**：先保存已減少可用數的 metadata 及待提交 revision，再呼叫 SecretStore，最後提交新 payload revision 並清除待提交標記。只有三步成功才放行送出。`RecoverableSecretReplacement` 的 pending slot 是機密提交點；其後 promotion 失敗仍視為已儲存，絕不回滾為舊碼。secret 寫入前失敗可嘗試還原 metadata；還原也失敗時保留較低的可用數。secret 已提交、最後 metadata 失敗時保留待確認標記，拒絕再使用。
- **原生編輯／貼上／匯入碼檔**：沿用 metadata-first 的 `CredentialEditCommit` 與版本綁定；新摘要先取新舊可用數較小值，多出的數量先算待確認。機密提交成功後才保存準確摘要。相同碼的歷史狀態不被匯入重設。
- **新項目、受保護 JSON 匯入、備份匯入**：先成功保存 payload，再新增含重算摘要的 metadata；JSON／備份還原先套用 needsReview 規則。既有 ID 的備份項目依原規則跳過。
- **自行校正**：使用者通過原生編輯器驗證後，讀取目前權威 payload，接受 metadata 目前 revision 或明確記錄的待提交 reservation revision，重算摘要並清除標記；舊的 unknown 摘要也在此補上。這不會把 issued 改成 available。清單不做這項讀取。任意不相符 revision 仍拒絕；一般 metadata-first 編輯若中斷在新機密提交之前，保留原有的 revision mismatch 拒絕行為，不擅自將舊機密配到新設定。

## 實際檢查結果

| 檢查 | 結果 |
| --- | --- |
| `swift test --scratch-path .build-test -Xswiftc -warnings-as-errors` | 通過；245 tests，2 skipped，0 failures；32.156 秒 |
| `swift test --scratch-path .build-rtest -c release -Xswiftc -warnings-as-errors` | 通過；234 tests，2 skipped，0 failures；28.452 秒 |
| `swift build --disable-sandbox --scratch-path .build-release -c release -Xswiftc -warnings-as-errors` | 通過 |
| `AGENTKEYBOX_BIN_DIR=$PWD/.build-release/release Scripts/mcp-smoke-test.sh` | 通過；初始化／工具清單與 9 個無效輸入拒絕，未聯絡 App |
| `Scripts/check-release-qa-strings.sh .build-release/release` | 三個產物皆通過；各掃描 10 markers × 3 encodings |
| `python3 -B Scripts/test-browser-acceptance-client.py` | 28 tests，全部通過；只跑離線合成測試 |
| `Scripts/security-static-check.sh` | 通過 |
| `xcrun swift-format lint --strict`，限本次 22 個改動 Swift 檔 | 通過；新增問題 0，改動檔中的既有問題 0 |
| `git diff --check 9e12f5f..HEAD` | 通過；文件提交後再次確認 |

Debug／Release 各跳過兩個未啟用的公開網站 opt-in 測試。加密磁碟備份與合成 WebKit 測試已在原始指令完整執行通過；不需要排除它們才能通過。

過程中先使用了含輸出重導向的 shell 指令，該執行環境限制 SwiftPM sandbox、hdiutil 與 WebKit；加入 `--disable-sandbox` 只能完成部分檢查。基底對照也重現同類失敗。最後改為直接執行使用者給定的原始指令，兩套完整測試均通過。先前受限執行與排除測試的結果不作為最後驗收結論。

本機保留的證據：

- `/tmp/akb-recovery-debug-final-output.log`、`/tmp/akb-recovery-release-final-output.log`：最後原始指令的捕捉輸出；早期輸出有工具截斷，最終完整測試摘要保留。
- `/tmp/akb-recovery-release-build.log`、`/tmp/akb-recovery-mcp-smoke.log`、`/tmp/akb-recovery-release-qa-strings.log`。
- `/tmp/akb-recovery-acceptance-client-tests.log`、`/tmp/akb-recovery-security-static.log`、`/tmp/akb-recovery-swift-format.log`（lint 無診斷，因此檔案為空）。

## Claude 與使用者後續原生驗收

完整操作及預期結果見 [MACOS_TEST.md 的 linked recovery 章節](MACOS_TEST.md#linked-recovery-codes-and-counts--native-acceptance-pending)。至少要驗證：

1. 新增復原碼並搭配登入、不填網址；登入到復原碼頁，核准窗顯示完整實際網址，核准後只有一次 POST 並成功到測試頁。
2. 同網站另一登入的 session 使用此組碼被拒絕；不同 origin、舊 session、改 URL／換專案／刪除登入亦拒絕。刪除登入只解除搭配。
3. `list_credentials` 顯示正確 `for_login`、automatic 與 `codes=`；卡片顯示搭配名稱與可用數；清單不跳驗證。使用一次後可用減一、待確認加一，零組時核准前拒絕。
4. 信用卡送出沒有復原碼提醒；復原碼送出仍有。搭配項目交給 `submit_sensitive_fields` 時回固定 browser_recover-only 錯誤。
5. 驗證備份還原、匯入歷史保留與簽署版 pending-slot 中斷後的保守摘要／原生校正。

本次未啟動或安裝 AgentKeyBox App，未操作真實鑰匙圈／正式 Application Support，未執行簽署、原生驗收腳本或 AgentKeyBox MCP 服務操作。MCP smoke 僅使用指定腳本中的初始化及本地無效輸入。

## 留給 Claude 清理的產物

依本次明確指示保留建置目錄，未加入版本控制；未建立 Xcode DerivedData 或 `.xcresult`，未清理共用目錄。本次釋放大小為 0。收尾時由 Claude 刪除以下本次建立的路徑（大小為 `du -sh` 約值）：

| 路徑 | 大小 |
| --- | --- |
| worktree 根目錄 `.build-test` | 275 MiB |
| worktree 根目錄 `.build-rtest` | 252 MiB |
| worktree 根目錄 `.build-release` | 121 MiB |
| worktree 根目錄 `.build-baseline` | 263 MiB |
| `/tmp/akb-recovery-baseline-9e12f5f`（基底對照原始碼） | 5.9 MiB |

四個建置目錄合計約 911 MiB。測試證據記錄於本文件後，可另行清理本次 `/tmp/akb-recovery-*` 日誌及暫存翻譯 JSON；不要碰其他 session 的產物。
