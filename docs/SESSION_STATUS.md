# AgentKeyBox implementation status

## Native check: approval panel closes before the approved work finishes — 2026-11-15

Ad-hoc QA build of `01b20e1`, isolated profile, synthetic `QA_SLOW_COMMAND_KEY`; the user approved with Touch ID.

- `run_with_secret` with `/bin/sleep 30`: the decision was recorded at 00:01:51 and the approval panel was gone by 00:01:55 while `sleep 30` was still running and the agent was still waiting.
- The main window showed `正在執行：Local Agent 使用 QA_SLOW_COMMAND_KEY…` during execution and `已完成核准的請求。` afterwards.
- A second `run_with_secret` sent during execution returned `Another AgentKeyBox approval is already pending.` in 0.0 s; no second panel appeared.
- The first request returned `exit_code=0` once, at 00:02:21 (30 s after approval).
- Not run natively: denial, Touch ID cancellation, approval timeout, 65-second execution timeout, and edit/delete/revoke during execution (MACOS_TEST §8a steps 7–8 and the revocation list). The QA runner removed its profile afterwards.

## 第二輪 code review 修復 — 2026-11-13（unreleased）

本次基底為 `9b98eb7`，分支 `fix/helper-updated-message`。三項修復各自與回歸測試同筆提交，文件最後獨立提交。下方歷史完整保留。本次僅使用合成資料及測試建立的暫存環境，未啟動／安裝 App、未存取正式機密或正式 broker token、未執行原生驗收、簽署、公證或發布。

### 修復、競態理由與測試

| 項目 | Commit | 實際修改與理由 | 回歸測試 |
| --- | --- | --- | --- |
| 1. 撤銷後不能重建 session grant | `b2fbe03` | `ApprovalEngine` 持有全域及逐 credential generation；驗證 token 與建立 grant 在同一 actor 方法內完成，兩者間無 await。撤銷先發生則拒建；建立先發生則後續撤銷移除並 invalidate authentication。回傳 Bool，拒建不記 `allowSession`。App 以撤銷任務鏈銜接同步 UI 回呼，核准／查詢先等待已排入的撤銷，再配合 metadata／accessGeneration 重驗。編輯（含換值、改專案、改 hosts）、記住新 host、刪除及移除專案都撤銷涉及金鑰；指令／HTTP 讀後重驗失敗也撤銷。 | `SessionRevocationTests` 5 個新增測試，連同既有 scope／expiry 與 protected-item 測試共 23 個通過。 |
| 2. 已開始執行的失敗保留執行語意 | `3c7771d` | 在呼叫 HTTP executor 前標記 executionStarted，之後 catch 僅回固定 executor error（未知錯誤歸為 transport），不再以金鑰異動改寫成重新核准。Core 純函式測試前後邊界。另發現瀏覽器關閉回呼可能在執行後提示重新登入，登入／導覽／復原開始後的 catch 與同步關閉回呼均改用既有固定失敗診斷。 | `CredentialUsePolicyTests` 新增 4 個測試；完整套件中該類別 9 個通過。相關選測 20 個：18 通過、2 live 跳過、0 失敗。 |
| 3. release 測試不進 CLI main | `4989b45` | test target 僅依賴 Core。`TestProducts` 由 bundle 推導 products，允許 `AGENTKEYBOX_TEST_BIN_DIR` 覆寫；缺檔預設明確 XCTSkip，CI 的 `AGENTKEYBOX_REQUIRE_PROCESS_TESTS=1` 則使其失敗。另修正既有翻譯測試：release 掃描排除 DEBUG-only 分支，避免要求 release 保留 QA 字串；加入巢狀條件回歸測試。 | `TestProductsTests` 4 個；`LocalizationTests` 6 個；debug 的 `HelperUpdateProcessTests` 3 個均實際通過，沒有 skip。debug／release 完整測試及其 Swift Testing 階段皆 exit 0。 |

新增的 session 測試名稱：

- `testRevocationDuringAuthenticationPreventsGrantAndFreshApprovalSucceeds`
- `testCredentialRevocationRemovesEveryScopeAndRejectsPendingGrantOnlyForThatKey`
- `testGenerationCannotBeUsedForAnotherCredentialOrAfterGlobalReset`
- `testCredentialAndGlobalRevocationInvalidateSavedAuthentications`
- `testExpiryStillUsesEightHourBoundaryAndInvalidatesAuthentication`

Authentication 失效測試使用未 evaluate 的 LAContext 替身，不呼叫鑰匙圈。Core 的逐 credential 撤銷保留其他金鑰既有 grant 及其尚待核准的 generation。

新增的執行階段測試名稱：

- `testBeforeExecutionChangedCredentialRequiresApprovalAgain`
- `testExecutionFailureAfterCredentialChangeNeverSuggestsReapproval`
- `testPreparationFailureWithUnchangedCredentialKeepsItsOwnError`
- `testBrowserClosureAfterExecutionNeverSuggestsAnotherSignIn`

第三項新增 `testFindsProductsBesideMacOSTestBundle`、`testFindsProductsWhenLinuxBundleIsProductsDirectory`、`testExplicitProductsOverrideWins`、`testMissingProductSkipsLocallyButFailsWhenRequiredByCI`，及 `testReleaseLocalizationScanExcludesOnlyDebugBranchesIncludingNestedCode`。程序測試實際執行 `testAllMCPBrokerErrorPathsPreserveUpdateMessage`、`testBrowserCLIPreservesOnlyTypedUpdateGuidance`、`testUnchangedHelperKeepsRejectionAndControlledToolsHideRawDiagnostics`，僅連接拋棄式合成 broker。

本次沒有新增使用者可見字串；沿用既有 `L()` 訊息及繁中翻譯，故未修改 `Translations.swift`。翻譯與 placeholder 檢查在兩種配置皆通過。

### 完成前的實際驗證

| 指令／檢查 | 最終實際結果 |
| --- | --- |
| `swift build --disable-sandbox --scratch-path .build-debug -Xswiftc -warnings-as-errors` | 通過，3 個 executables；10.94 秒。 |
| `swift test --scratch-path .build-test -Xswiftc -warnings-as-errors` | 通過，221 個 XCTest：219 通過、2 live 跳過、0 失敗；測試 37.550 秒，建置 2.25 秒。HelperUpdateProcessTests 3／3 通過、0 skip（2.034 秒）。Swift Testing 0 tests，正常 exit 0。 |
| `swift test --scratch-path .build-rtest -c release -Xswiftc -warnings-as-errors` | 通過，210 個 XCTest：208 通過、2 live 跳過、0 失敗；測試 34.464 秒，建置 12.74 秒。Swift Testing 0 tests，正常 exit 0；沒有 CLI 的 `--test-bundle-path` 錯誤。 |
| `swift build --disable-sandbox --scratch-path .build-release -c release -Xswiftc -warnings-as-errors` | 通過，3 個 executables；45.95 秒。 |
| `AGENTKEYBOX_BIN_DIR=$PWD/.build-release/release Scripts/mcp-smoke-test.sh` | 通過，11 個 JSON-RPC 回應、9 個預期輸入驗證錯誤；不連接正式 broker。 |
| `Scripts/check-release-qa-strings.sh .build-release/release` | 通過，3 個 executables × 10 markers × 3 encodings（UTF-8／UTF-16LE／UTF-16BE），0 命中。 |
| `python3 -B Scripts/test-browser-acceptance-client.py` | 25 個測試，0 失敗，0.024 秒。 |
| `python3 -B Scripts/test-release-qa-strings.py` | 4 個測試，0 失敗，1.598 秒。 |
| `Scripts/security-static-check.sh` | 通過，exit 0。 |
| `bash -n Scripts/check-all.sh` | 通過，exit 0；本次唯一修改的 shell 檔。未執行含禁止驗收指令的整支 check-all。 |
| `xcrun swift-format lint --strict`（僅 13 個改過的 Swift 檔） | exit 1：新增問題 **0**，既有問題 **45**（去除工具重複診斷後）；逐筆以 `9b98eb7` 原始碼、行號對應、column 及規則比對。不能宣稱 lint 全部通過；明細如下。 |
| `git diff --check 9b98eb7..HEAD` | 通過，文件提交後再檢查。 |

SwiftPM 沙盒內 build 會顯示 user-level configuration/security cache 不可寫的兩則環境警告；Swift 編譯仍以 warnings-as-errors 成功。兩個跳過項目都是未啟用的 LiveBrowserTests；未連接公開登入站點。release 比 debug 少的測試來自既有 DEBUG 條件編譯，不是漏找程序產物而 skip。

開發中先修正一次漏更新 generation 參數的測試呼叫；第一次完整測試發現新增測試不應依賴 XCTSkip 的 debug description，及 release 翻譯掃描與 DEBUG 編譯條件不符，均已修正後完整重跑。上表只列最終結果。選測數字與完整套件重疊，不可相加。

### 格式檢查：新增與既有分列

- **新增：0。** 本次新增／修改行沒有新格式診斷。
- **既有：45。** `AgentKeyBoxCoreTests.swift` 42 個、`LocalizationTests.swift` 3 個。保留無關既有程式；下表列最終行號與 column，同一位置同一規則的重複輸出只算一次。

| 檔案 | 規則 | 位置（line:column） |
| --- | --- | --- |
| `AgentKeyBoxCoreTests.swift` | `[AddLines]` | 909:106, 1006:16, 1448:22, 1448:60, 1458:22, 1458:61, 1468:22, 1468:60, 1469:20, 1469:60, 1478:22, 1478:60 |
| `AgentKeyBoxCoreTests.swift` | `[DoNotUseSemicolons]` | 1448:47, 1458:47, 1468:47, 1469:43, 1478:47 |
| `AgentKeyBoxCoreTests.swift` | `[Indentation]` | 1162:1, 1163:1, 1164:1, 1165:1, 1166:1 |
| `AgentKeyBoxCoreTests.swift` | `[LineLength]` | 590:1, 612:1, 724:1, 852:1, 882:1, 899:1, 905:1, 926:1, 941:1, 974:1, 1030:1, 1039:1, 1057:1, 1200:1, 1235:1, 1267:1, 1503:1, 1559:1 |
| `AgentKeyBoxCoreTests.swift` | `[RemoveLine]` | 724:102 |
| `AgentKeyBoxCoreTests.swift` | `[TrailingComma]` | 727:86 |
| `LocalizationTests.swift` | `[LineLength]` | 124:1, 125:1, 134:1 |

### 第二項：其他執行路徑逐一判斷

| 路徑 | 判斷及處理 |
| --- | --- |
| 指令執行 | 沒有同類改寫。readSecret 的 do/catch 與 `ApprovedCommandRunner.run` 的 do/catch 分開；changed 僅在開始執行前回報，執行後保留 runner 錯誤。 |
| 環境變數 | 沒有同類改寫。此方法只準備完整 environment；每次讀取後重驗整組，尚未回傳給 CLI，沒有已開始的外部指令。失敗不回傳部分 environment；最終回傳前沒有額外 await。 |
| `submit_sensitive_fields` | 沒有同類改寫。metadata／reservation 的可拋錯步驟全在送出前；transport 的 send 為非 throwing、固定 outcome（含 unknown），外層 catch 不會接到已送出後的網路錯誤。既有 executingSubmissionID 讓編輯不會把已開始提交改報為 changed；issued reservation 保留。相關 reservation／revocation 測試通過。 |
| 瀏覽器 login／follow／recover | 有類似風險：原本執行後的 ownedBrowser 重驗與本機 close 回呼可能回 `unavailable`／`expired` 並提示重新登入。新增開始執行標記，catch 與 close、單筆撤銷、全域關閉的回覆共用固定 operation-failure 語意。讀取前仍保留原本診斷。 |
| 瀏覽器 read／close | 本身不送登入／復原表單；read 的回傳前重驗保護已關閉的私人內容。close 若中止另一筆已開始的操作，該操作的關閉回呼現在回固定失敗；close 自身照常回覆。 |

### 第三項：CI 的程序測試不會被靜默跳過

- macOS job 原本就先 `swift build` 再 `swift test`；本次增加 `AGENTKEYBOX_REQUIRE_PROCESS_TESTS=1`。找不到 helper 或 akb 會直接失敗，不能以 XCTSkip 過關。本機完整 debug 已實際跑完 3 個程序測試。本次另增 macOS release build/test 步驟，持續檢查 runner 的 exit code。
- Linux job 原本也先 build 再 test，並保留 MCP／CLI smoke。HelperUpdateProcessTests 依既有 `#if os(macOS) && DEBUG` 不在 Linux 或 release 編譯，因為替換執行檔的程序案例依賴 macOS DEBUG QA profile；這些案例由 macOS debug job 負責。TestProducts 的目錄推導與缺檔行為測試不受此條件限制。
- `Scripts/check-all.sh` 原本先 build；現在在 test 前 export 同一個 require flag。使用不同建置目錄時可明確設定 `AGENTKEYBOX_TEST_BIN_DIR`，不依賴 PATH、已安裝 App 或正式 helper。
- 以上 CI 判斷來自已更新的 workflow／腳本及本機測試；本次未啟動遠端 CI 或 Linux runner，遠端實跑狀態標為**未驗證**。

### 原生驗收與收尾交接（未驗證）

請 Claude 與使用者之後在隔離 profile、合成金鑰、loopback 端點進行以下驗收。必須以精確 credential ID／label／kind 選取測試資料，不以模糊搜尋挑選真實金鑰；機密值不得輸出至 agent。

1. Touch ID 尚未完成時選「每次都詢問」，再完成原驗證：不能留下 session grant；下一次同請求仍須核准。核對原生 UI 與歷史不將拒建標為 allowSession。
2. 已有 session grant 時，分別換值、改專案、改 allowed hosts、刪除金鑰、移除專案；涉及金鑰須重新詢問或不可用，其他金鑰既有 grant 不受影響。另驗證讀取等待期間編輯後不會留下 grant。真正 LAContext／Touch ID 失效仍需簽署的原生流程確認。
3. loopback 接收一次 POST 後暫停回應，在期間編輯金鑰再斷線／逾時：回覆固定執行失敗而非重新核准；確認只有一次 POST，勿自動重送。瀏覽器登入／復原開始後關閉或撤銷，也應回固定操作失敗，復原碼維持 issued。

自動化驗證已完成；未解限制是原生競態／Touch ID 驗收、遠端 CI／Linux 實跑，以及上述 45 個既有格式問題。未產生自訂 Xcode DerivedData 或 `.xcresult`，未清除共用目錄。依本次指示，四個 SwiftPM 建置目錄留給 Claude 清理：`.build-debug` 約 162 MiB、`.build-test` 約 273 MiB、`.build-rtest` 約 249 MiB、`.build-release` 約 119 MiB；未 add、未刪除，釋放建置空間 0。

## Final pre-merge checks — 2026-11-13

Run on `6c504ca` before merging to `main`.

- **Automated:** debug and release builds with warnings as errors; 197 Swift tests (195 passed, 2 opt-in live tests skipped, 0 failures); MCP and CLI smoke against release binaries; release QA-string scan; offline acceptance-driver tests; security static check; shell syntax; `git diff --check`.
- **QA `akb connect` refusal (native):** with `AGENTKEYBOX_QA_ID` set, `connect all`, `connect claude --helper …` and `connect codex` each exited 1 with the localized refusal. No helper was installed in the QA profile. The real Claude Code and Codex registrations and the fixed-path helper were unchanged.
- **QA guard isolation (native):** setting up a synthetic project with agent guard on wrote `guard-rules.json` inside the QA profile only. No production `guard-rules.json` was created.
- **`card-form` on a fresh three-fixture profile:** passed with one native approval and one exact-fields POST. A first attempt was correctly refused by the driver's allowlist because an extra synthetic project had been added in the same profile.
- **Add Project picker:** the New Folder button appears in both the QA build and the installed Developer ID signed build.

## Signed retest of the seven review fixes — 2026-11-13 (unreleased)

Developer ID signed arm64 build of `725d6ff` installed in `/Applications`; the user completed every Touch ID prompt.

- **Keychain pending replacement, normal path: passed.** Adding a six-code synthetic recovery item needed no Touch ID. Unlock took one Touch ID and read back all codes. Saving a rename took one Touch ID; a second unlock showed the new name and all six codes. The item was deleted afterwards.
- **HTTP after-read recheck, normal path: passed.** An approved `http_request` through the newly installed signed helper returned `status=200` and `content_type=application/json` (MIME type only).
- **Test-procedure incident.** The driver for that HTTP check chose its credential with a loose pattern over `list_credentials` text and selected a real global App Store Connect key instead of the synthetic one. After approval, the real key was sent to a public echo service. The user revoked and rotated it. For live tests, select the credential by exact label and kind from structured output, verify it before sending, tell the user exactly what the native prompt will show, and prefer a loopback endpoint.
- **MCP processes started before an install are rejected** (`Requests must come from the AgentKeyBox helper or akb.`) once the fixed-path helper is replaced. Reconnect them after every install.
- Not covered natively: fault injection between the pending and primary writes (unit tests only), and a reflected secret in `Content-Type` against a live server (loopback unit test only).


## 七項 code review 修復 — 2026-11-13（unreleased）

本次以 `30eef5d` 為基底，於 `feat/protected-items-browser` worktree 完成修復。只執行合成資料的建置、自動化測試與靜態檢查；未啟動或安裝 AgentKeyBox、未存取正式資料／鑰匙圈／broker token、未執行原生驗收、簽署、公證或發布。下方歷史紀錄原樣保留，不能當作這次 binary 的驗收。

### 修復與同筆提交的回歸測試

| 項目 | Commit | 做法與理由 | 測試證據 |
| --- | --- | --- | --- |
| 1. POST 重送 | `795507f` | 在 WebKit 放行第一個 POST 前消耗許可；後續 POST 一律固定失敗並關閉工作階段，保留 issued。 | `testSameURLPostRedirectsNeverResubmitLoginOrRecovery`：登入／復原碼 × 307／308，真實 WebKit 四種情況各僅 1 次 POST，固定錯誤且不含合成值與編碼。另有 `4081966` 純換行格式修正。 |
| 2. pending 提交點 | `cbf10d7` | pending 寫入成功即回報成功；promotion 失敗由 load 修復，避免新機密配舊設定。既有 pending 仍不能覆寫或刪除騰位。 | `testEditCommitRetainsMetadataAfterCommitAndRollsBackBeforeCommit` 使用落盤 metadata 與會拒絕 primary 新增的假儲存層；`testSubmissionReservationKeepsNewRevisionWhenPromotionFails`、`testRecoveredReservationCannotResurrectIssuedCodeAndOldRevisionIsRejected` 涵蓋兩種 reservation 路徑。Replacement 10 + EditCommit 4，共 14 測試通過。 |
| 3. fixture 白名單 | `0e9902e` | submission／backup 共用白名單：必需 1、2，僅可另有 fixture 3 信用卡，且必屬 fixture 4 專案、目的地為 `/submit/card`。拒絕未知／重複 ID、錯誤種類／專案／目的地。 | `test_submission_allowlist_and_backup_with_optional_project_card` 驗證第三筆存在及已移除，並驗證備份卡片 envelope 數量；離線套件 25 測試通過。 |
| 4. HTTP 回應洩漏 | `9f08b82` | MIME 轉小寫，只允許 type/subtype token、最多 127 bytes、移除參數，再以 SecretRedactor 候選值檢查。另將 URLSession 原始錯誤替換為固定診斷。 | `HTTPResponseSafetyTests` 三個測試：MIME 語法／長度、loopback 參數與 subtype 反射、斷線錯誤；驗證實際 MCP 共用 formatter 與 BrokerResponse 編碼。加既有 HTTP 重導向測試，共 4 通過。 |
| 5. 讀取後重驗 | `e2b736c` | 指令／HTTP／環境變數保留核准快照；每次 await readSecret 後比對完整 metadata、專案可見性與撤銷 generation。多機密環境每次讀完重驗整組；清理明文檔案前也重驗快照與備份。 | `CredentialUsePolicyTests` 5 測試涵蓋 timestamp、hosts、移動、刪除、設定、專案失效、撤銷與前一筆環境機密被改；另 10 個 BackupArchiveTests 通過。App UI 競態仍待原生驗收。 |
| 6. QA 寫入隔離 | `7506191` | GuardRuleLedger 預設選 profile 檔案並保留顯式注入；App 偏好設定統一使用所選 domain，登入預設註冊再加 QA guard。正式模式維持原路徑。 | `testGuardRulesStayInSelectedProfileAndExplicitOverrideWins`、`testAppPreferencesUseIsolatedProfileEvenOutsideQABundle`；Profile 6 + Guard 10 + Localization 5，共 21 通過。 |
| 7. release QA 字串 | `687a169` | QA directory／service／domain 實作、視窗標題與隔離診斷僅 DEBUG 編譯；release current 恆 nil 且不能建立 profile。新增三執行檔掃描器與用法。 | `ReleaseQAScannerTests` 4 測試，包含每個執行檔各 10 種標記、缺檔、UTF-16 與乾淨檔；實際 arm64 release 的 3 個執行檔均通過。 |

第 1 項提交後才補正一行 lint 換行，因此有一筆額外的純格式 commit；未 amend 或重寫歷史。其餘每項修復及回歸測試各在同一 commit，最後另交文件 commit。

### 完成前的實際驗證

| 檢查 | 實際結果 |
| --- | --- |
| `swift build --disable-sandbox --scratch-path .build-debug -Xswiftc -warnings-as-errors` | 通過，3 executables；最後一次 8.55 秒。SwiftPM 對沙盒內不可寫的 user-level configuration/security cache 顯示 2 則環境警告，Swift 編譯成功。 |
| `swift test --scratch-path .build-test -Xswiftc -warnings-as-errors` | 通過，197 個 XCTest，2 個 LiveBrowserTests 跳過，0 失敗（195 通過）；測試 36.594 秒。Live opt-in 未啟用。 |
| `swift build --disable-sandbox --scratch-path .build-release -c release -Xswiftc -warnings-as-errors` | 通過，arm64 的 3 executables，40.80 秒；同樣有 2 則 SwiftPM cache 環境警告。 |
| `AGENTKEYBOX_BIN_DIR=$PWD/.build-release/release Scripts/mcp-smoke-test.sh` | 通過，11 個 JSON-RPC 回應，9 個預期的輸入驗證錯誤；沒有呼叫正式 broker。 |
| `Scripts/check-release-qa-strings.sh .build-release/release` | 通過，3 executables × 10 標記 × 3 編碼（UTF-8／UTF-16LE／UTF-16BE），0 命中。 |
| `python3 -B Scripts/test-browser-acceptance-client.py` | 25 測試，0 失敗。 |
| `python3 -B Scripts/test-release-qa-strings.py` | 4 測試，0 失敗。 |
| `Scripts/security-static-check.sh` | 通過，exit 0。 |
| `bash -n Scripts/check-release-qa-strings.sh` | 通過；本次唯一新增／修改的 shell 檔。 |
| 修改過的 Swift 檔 `xcrun swift-format lint --strict` | 檢查 17 檔，exit 1：新增問題 **0**，既有問題 **3**。與 `30eef5d` 相同原文／規則逐筆比對：AgentGuard.swift:97 的 LineLength，以及 Localization.swift 的兩個 `L` 函式命名（目前 111、120 行）。未把既有問題宣稱為通過，也未重排無關程式。 |
| `git diff --check 30eef5d..HEAD` | 通過；文件提交後再檢查。 |

完整測試第一次加上 shell 輸出重新導向時，manifest 的 sandbox_apply 回報 Operation not permitted；改用上列原樣、已放行的 swift test 指令後完整通過。之前開發中的測試編譯／新增 lint 問題均已修正；上表是修正後結果。測試群組的數量可能重疊，不可加總成另一個完整測試數字。

### 第 4、5、6 項延伸檢查

**BrokerResponse / HTTP：** `http.statusCode` 與 `bodyTruncated` 是數值／布林；`body` 原有先遮罩再截斷保護；`contentType` 已修。`error` 的 URLSession transport 分支原會輸出原始錯誤文字，這次已改固定訊息。HTTP 不回傳任意 headers、Location、Set-Cookie 或最終 URL。Policy 驗證錯誤來自 agent 原本輸入；其他 HTTP 錯誤為固定訊息。`credentials` 是 metadata，`execution` 是既有遮罩的指令輸出，`submissionOutcome` 是固定 enum，`browserPage` 經既有受控頁面政策，均非 HTTP 原始標頭轉送。`environment` 是已存在、限獲准 CLI 的明文交付模式，MCP HTTP formatter 不讀取它；本次沒有擴大其存取範圍。

**所有 await readSecret（行號依任務原始碼）：**

- 約 570，備份：原本已在所有讀取後、寫出前以 `BackupArchive.snapshotIsCurrent` 比對完整 credential／project 快照；沒有先寫出新值配舊 metadata，沿用且跑既有測試。
- 約 682，清理專案明文：補上使用前完整 credential／project 快照與 backup coverage 重驗；失效就停止，讀完到刪改檔案間沒有 await。
- 約 1469，原生 protected editor：讀取後已有完整 metadata contains 與 payload revision 檢查；這是使用者原生編輯，沒有 agent request project，沿用。
- 約 1597，standalone protected submission：已有完整 metadata/index 與 payload revision 檢查；再補 project visibility、revocation generation。
- 約 1820，browser login：補 project visibility 與 `ownedBrowser` 檢查；metadata／payload revision 與 lease 原本已檢查。
- 約 1831，browser recovery：讀後重取 visibleCredential 並與快照相等，再重驗 ownedBrowser；既有 reservation/lease/revision 檢查保留。
- 約 2162，指令：改傳核准時完整 metadata，讀後重驗；設定也取自同一快照。
- 約 2218，HTTP：保留讀前檢查，新增讀後完整重驗，才執行送出。
- 約 2247，環境變數：核准時捕捉整組 selection，每讀完一筆重新比較整組與撤銷狀態，任何失效不回傳已讀部分。

**QA 正式路徑：**

- Application Support：App 的 metadata、access log 與 Keychain service 已注入 profile；broker socket、broker token 原已有 profile 路由。GuardRuleLedger 是漏網項目，這次修正。只讀程式碼與使用合成暫存測試，未開啟正式儲存檔。
- 偏好設定：Localization 原本選 QA domain，但 App 的 AppleLanguages、backup 日期、login 設定、helper 註冊紀錄直接用 standard；這次全部改走同一 profile-aware defaults。全域 AppleLanguages 僅讀取系統語言，沒有修改。
- Helper：固定安裝位置由 profile-aware broker 目錄推導；App 的 keepAgentsConnected／connect 已禁止 QA，CLI connect 在安裝前拒絕 QA，沿用。
- Agent 註冊：自動與手動 App 路徑、CLI connect 已有 QA guard；沒有增加 adapter 寫入。
- Login item：init 的自動路徑與 setOpensAtLogin 已阻擋 QA；這次在 openAtLoginByDefault 入口再確認。SMAppService status 讀取及開啟系統設定沒有註冊副作用。
- App 搬移：QA 已禁止 moveToApplications 並隱藏提議，沿用。原生備份與專案設定寫入使用者選擇的位置，沒有另一條硬編碼正式 vault 路徑。

**第 2 項呼叫端：** 原生 protected editor 與一般 key editor 的 `CredentialEditCommit` 現在都會保留已提交 pending 對應的新 metadata。兩條復原碼 reservation closure 都在 save 成功後更新 payloadRevision 與 updatedAt，再持久化 metadata；promotion 失敗不再中止這些步驟。Metadata 本身寫入失敗／程序中斷仍可能留下 revision 不一致，既有拒絕使用規則維持，沒有宣稱跨 Keychain 與 JSON 的原子交易。

### 人工交接與限制

**簽署版鑰匙圈編輯流程必須重新驗收，目前未驗證。** 請 Claude 與使用者依 [MACOS_TEST.md 的 signed replacement 步驟與 native review-fix 步驟](MACOS_TEST.md) 使用專用合成項目：

1. Team-signed、具 entitlement 的測試版確認 data-protection Keychain；一般 key 從舊專案／hosts／值編輯為新設定與新值。分別注入 pending-add 失敗及 pending 成功後 primary-add 失敗。前者必須回報失敗並還原舊設定／舊值；後者必須回報成功，保持新設定，下一次 authenticated load 讀到新值並修復。再測 pending 已存在時拒絕覆寫、各操作點中斷／重啟，以及正常編輯與兩種 recovery reservation。
2. 使用者自行完成每次 Touch ID／登入密碼驗證；replacement／repair 不得增加額外驗證視窗，兩個 slot 的 user-presence 與 device-only 保護保持不變。已送出的復原碼重啟後仍 issued，無自動重送。
3. 原生 read-race 測試分別暫停 HTTP／指令／環境變數的 Keychain worker，編輯／移動／刪除／改 hosts／撤銷後繼續；應回固定 changed 錯誤且零送出、零執行、零環境回傳，另做不變更的成功對照。
4. 新 QA submission profile 內設置測試專案、語言與備份，驗證 ledger/preferences 留在 profile；第三筆移除前後各執行 card-form 與備份檢查，預期精確白名單與卡片數都通過，正式設定不變。

未驗證：本次 binary 的原生 UI/Touch ID、簽署版 Keychain、真實服務 TLS／登入相容性、Intel/universal 產物。QA 或 unit tests 不取代以上驗收。嚴格 lint 的 3 個基底既有問題仍保留。

未建立 DerivedData 或 xcresult，未清除共用 Xcode 產物。依使用者指示保留 `.build-debug`（164,272 KiB）、`.build-test`（275,164 KiB）、`.build-release`（121,220 KiB）供 Claude 收尾；合計 560,656 KiB（約 547.5 MiB），未加入 Git。本次主動清除的 build 路徑：無，釋放 0 bytes。個別合成 fixture 暫存檔由測試自行清理。

## Agent scope decision — 2026-11-05

dots / ChatGPT Work, Meta Muse (including Muse Code), Grok Bot and Claude Duet cannot be tested here, so they were removed from user-facing documentation and `docs/AGENT_COMPATIBILITY.md` was deleted. The `akb browser` command reference moved to [INTEGRATION.md](INTEGRATION.md). Later sections mentioning these products are historical records, not support claims.

## Native and signed acceptance of the merge-blocker fixes — 2026-11-13 (unreleased)

Branch `feat/protected-items-browser` at `991c831`. The user completed every Touch ID prompt; only synthetic data was used.

| Check | Environment | Result |
| --- | --- | --- |
| `remove-project-pending` | Ad-hoc QA `--submission`, profile `C5DF69D5-42DD-4AA1-9E74-65BB45B332D6` | **Passed.** Removing **QA — 可移除測試專案** while its card request waited closed the prompt; exact result/history, zero POST or reservation change, responsive broker. |
| `code-received` | Same profile | **Passed** on the second run: one `allowOnce`, one exact-fields POST, durable reservation before POST, rotated payload revision and matching metadata, no reflected secrets or cookies. The first run's transport also passed, but the driver failed its history match because the app records `/tmp/...` while the driver compared `Path.cwd().resolve()` (`/private/tmp/...`). Run the drivers from a directory without a symlinked prefix. |
| Browser recovery, MCP allowed | Ad-hoc QA `--recovery`, profile `5BA46A7E-1508-402B-AD5F-D2063556D300` | **Passed.** Approved login returned only the fixed challenge; the separate approval made one durable reservation before one POST; no synthetic secret in output/history; session closed. |
| Signed Keychain normal path | Developer ID signed arm64 build of `991c831` installed in `/Applications`, data-protection Keychain | **Passed.** Adding a six-code synthetic item needed no Touch ID. Unlock: one Touch ID, all codes read back. Saving a rename: one Touch ID (edit authentication), then readback after a second unlock showed the new name and all six codes. Deleting it restored `metadata.json` and `access-log.json` byte-identically. The fixed-path MCP helper matches the installed bundle. |

Not covered natively: interruption and failure injection between the pending and primary Keychain writes (release builds have no hooks; unit tests only) and QA `akb connect` refusal. Both QA runners removed their profiles (173,224 KiB for the submission profile). The previous 0.4.5 app is kept at `dist/local-protected-items/previous-AgentKeyBox.app` for rollback.

## Merge-blocker fixes — 2026-11-05 (unreleased)

Implemented in the `feat/protected-items-browser` verification worktree, based on `aab7b5d`. No App launch/installation, production vault/Keychain/token access, native acceptance, signing, notarization or publication was performed in this pass. Historical native results below remain historical evidence; they do not validate these new binaries.

| Fix | Commit | Result and regression evidence |
| --- | --- | --- |
| P1 text filtering | `1e557c6` | Body and link text share bounded per-text-node visibility filtering. `testPageAndLinkTextExcludeInvisibleAndBlockedDescendants` covers hidden/script/textarea/display-none/visibility-hidden/collapse descendants plus hidden body text and preserved visible labels through real WebKit. Browser policy/runtime subset: 21 tests, 0 failures. |
| P1 project revocation | `b3d938e` | Persist project removal, revoke every removed item, then delete Keychain values. App checks browser ownership/current metadata again after awaited page operations. `testRevocationDuringReadDiscardsLatePage` and existing `testRevocationDuringFollowDiscardsLatePageAndClosesOnce` reject late pages; `ProtectedAccessRevocationTests` covers all matching login browsers, a pending recovery browser, unrelated items, and preservation of started submission outcomes. Related runtime/revocation/localization subset: 24 tests, 0 failures. |
| P1 Keychain replacement | `8df2a51` | Approach **b**: insert-only protected pending copy, replace primary, then remove pending; authenticated reads repair pending first. Approach **a**, `SecItemUpdate`, was rejected because save callers do not carry a grant and updating user-presence items may add authentication. Mutation contexts disallow UI, while accessibility and user-presence flags remain unchanged; legacy operations retain their existing implementation. Eight `RecoverableSecretReplacementTests` cover add/delete failures, interruption after each mutation, pending-only/old-primary/same-primary recovery, repair/authentication failure, stale pending protection, deletion and stale recovery revisions. Related replacement/recovery/submission/runtime subset: 41 tests, 0 failures. |
| P2 QA registration | `08628af` | `akb connect` invokes a Core guard before helper installation and adapter calls, returns a localized error/nonzero exit in QA, and keeps release behavior. `testQAProfileRejectsAgentRegistrationAndNormalProfileAllowsIt` plus profile/localization subset: 9 tests, 0 failures. The CLI command itself was not executed. |

Recovery reservations now rotate payload revisions for both endpoint and browser use. The app persists the issued payload and matching metadata before sending. Interrupted metadata/secret writes fail closed; no recovery path silently reuses an older available-code payload. Read repair can return the latest authenticated pending value even if cleanup fails; another write stays blocked until repair succeeds. A partially committed edit/reservation may therefore require native recovery of a revision mismatch rather than silently rolling back code history.

Other removal paths were inspected individually and left unchanged:

- `importBackup` (original line ~635): removes only newly imported IDs after metadata-save failure. It is synchronous on the main actor; no broker request can obtain those IDs before rollback.
- `addCredential` (original line ~830): rolls back one newly generated ID in the same synchronous call after persistence fails; no protected request/browser can exist for it.
- `storeEnvSecrets` (original line ~951): removes only just-added environment-variable IDs without a suspension point; existing IDs are not removed. No additional protected revocation is needed.

Final automated verification (same source state as the four repair commits; subsequent changes are documentation only):

| Command / check | Actual result |
| --- | --- |
| `swift build --disable-sandbox --scratch-path .build-debug -Xswiftc -warnings-as-errors` | Exit 0; 10.33 seconds. |
| `swift test --scratch-path .build-test -Xswiftc -warnings-as-errors` | Exit 0; **184 tests, 2 skipped, 0 failures**; 36.110 seconds for the full suite. Both skips are opt-in LiveBrowserTests, which remained disabled. |
| `swift build --disable-sandbox --scratch-path .build-release -c release -Xswiftc -warnings-as-errors` | Exit 0; 31.91 seconds. |
| `AGENTKEYBOX_BIN_DIR=$PWD/.build-release/release Scripts/mcp-smoke-test.sh` | Exit 0; **11 JSON-RPC responses**, including **9 expected validation errors** rejected before contacting the App. |
| `python3 -B Scripts/test-browser-acceptance-client.py` | **24 tests, 0 failures**. Includes exact project-removal/cancellation evidence and fresh reservation-revision requirements for endpoint/browser drivers. |
| `Scripts/security-static-check.sh` | Exit 0; both hardcoded-secret and unsafe logging/persistence checks passed. |
| `bash -n Scripts/run-browser-acceptance-macos.sh` | Exit 0; **1 modified shell file**. Only parsed, never executed. |
| `xcrun swift-format lint --strict` on changed Swift files | **17 files; 0 new diagnostics, 0 remaining pre-existing diagnostics**. |
| Aggregate whitespace check | `git diff --check HEAD~4` passed with the final documentation working changes included; the corresponding post-documentation-commit check is `git diff --check HEAD~5`. |
| Release QA exclusion | `strings -a` / `grep -F`, supplemented by raw UTF-8 checks: **3 executables × 13 markers = 39 checks, 0 matches**. |

The 13 excluded markers were `AGENTKEYBOX_QA_ID`, `recovery-fixture.json`, `submission-fixture.json`, `PinnedRecoveryFixtureBrowser`, `interrupt-card-save`, `removal-project`, `remove-project-pending`, both new English QA project/card labels, both Traditional Chinese labels, and the English/Traditional Chinese QA registration error. No release executable was launched except the MCP helper's validated smoke-test input.

The sandboxed builds each reported SwiftPM's two user-cache accessibility warnings; Swift compilation still passed warnings-as-errors. An initial combined edit/test invocation failed at manifest sandbox setup; the standalone, authorized `swift test` invocation succeeded. Initial combined git stage/commit commands could not create the shared worktree index lock; separate permitted git commands succeeded. No code/test failure remains.

**Native/signed acceptance remains unverified:** run the fresh-profile `remove-project-pending` procedure and signed Keychain interruption/prompt-count checklist in [MACOS_TEST.md](MACOS_TEST.md). The new fixture is a dedicated DEBUG/QA project and card; its exact synthetic account is included in runner cleanup. The driver requires cancellation within **5 seconds** of persisted removal, no new approval decision or POST, unchanged code statuses, a released approval slot and a responding broker. Existing native submission and browser recovery cases also need to exercise the newly advancing reservation revision. The signed public-demo login/read/close result below remains valid historical evidence; signed card/recovery submission, browser recovery continuation and the changed Keychain replacement have not been validated here.

Build cleanup is delegated to Claude as requested. Retained scratch directories: `.build-debug` **157,628 KiB**, `.build-test` **268,900 KiB**, `.build-release` **119,308 KiB** (**545,836 KiB total** at measurement). No shared DerivedData or `.xcresult` was created or removed; no build artifacts were staged. This pass freed **0 KiB** of build artifacts.

## Evidence and review scope

Documentation was first reconciled on **2026-10-22** against the **0.4.0** baseline. The same task then implemented the unreleased protected-field submission increment described below. Released-product evidence, new automated checks, and still-pending GUI/provider checks are kept separate.

Historical runtime/test results are recorded separately in [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md), primarily dated 2026-10-15. [PRODUCT.md](PRODUCT.md) owns the product requirements; [ROADMAP.md](ROADMAP.md) owns the selected next work.

## Native protected JSON import acceptance — 2026-10-26 (unreleased)

All four original/renamed JSON cases passed in isolated profile `593D6043-A276-4C12-A1C3-453DD37062BF`. Added **Add Item → Import File…** in English/Traditional Chinese: a single-file native `NSOpenPanel` uses the existing drop/import path. Each file was selected individually; the list increased from two to six items. This is native file-picker acceptance, not an automated cross-window drag.

| File | Protected kind / new ID |
| --- | --- |
| `QA — Local synthetic card (edited).card.json` | `creditCard` / `F95BDFF0-871F-4D87-8771-0A4A181FA736` |
| `renamed-card.json` | `creditCard` / `F068E756-62A6-4C57-BAF9-406B44FDA412` |
| `QA — Local submission codes.recovery-codes.json` | `recoveryCodes` / `478DA42E-9858-4C81-8306-82D2E0D1DEA6` |
| `renamed-codes.json` | `recoveryCodes` / `6EE70FCB-F714-4BB3-ADE4-04FD0080650F` |

Metadata and live MCP discovery confirmed protected kinds and no inherited destination, injection variable, settings, allowed hosts or project scope. The original two records remained identical. Exact-service/account Keychain readback compared only these four known synthetic payloads inside the checker, without printing values: card contents, revisions, recovery-code IDs/generation and conservative statuses matched. Both imported sets contain **[needsReview, used, needsReview × 6]**. The checker first needed hexadecimal decoding for `security` output; another attempt checked three items before the last access prompt exceeded ten seconds. A separate successful read checked that last UUID. No Keychain access controls or code statuses were changed.

Exposure review confirmed the four plaintext originals/copies remained readable and byte-identical after import. Card SHA-256: `263e1ba207620f3e8fc18bb5774782301ddfa0696e93e4eebe92cd58f17b5b14`; code SHA-256: `9265aa8ac693484a8d463b755497386a518db8becfbc652632092f5ec6c6d1cd`. Import does not erase original files or copies from opened backups. Raw/base64/URL/hex fixture values were absent from metadata, history, receiver evidence and MCP discovery. The earlier encrypted backup stayed byte-identical; the receiver still had one entry and zero errors. No new submission occurred. An optional readback-backup Save panel stayed disabled under automation; it was cancelled and produced no backup. Scoped Keychain checks supplied the readback evidence instead. Previously passed cancellation, editing, replacement, interruption and backup/restore cases were not rerun.

**QA launch defect found and fixed:** opening the stopped QA bundle through Launch Services without `AGENTKEYBOX_QA_ID` initially loaded production metadata and refreshed the fixed-path MCP helper with an ad-hoc helper. That app was closed, the original signed **0.4.4** helper restored, and the production app restarted after confirming zero browser sessions/no pending prompt. A fresh installed signed helper successfully queried the restored broker. Production metadata retained SHA-256 `cb543c231773526c45a70a441e57e83e2dfd961e7623058d2ed3ede1c7a8bbe6`; no production secret was read. Existing MCP processes were not terminated: processes that loaded the temporary ad-hoc helper need reconnection and are correctly rejected by the signed broker.

`DevelopmentProfile` now rejects QA bundle launches with a missing, malformed or mismatched profile UUID before any production fallback. Three regression tests cover this boundary and ordinary development/helper behavior. A real QA app probe without the environment aborted before changing production metadata, history, token, helper or broker socket inode. **Eight targeted tests passed** (three profile and five localization tests); DEBUG/release warnings-as-errors builds, strict formatting of changed Swift files, final signed MCP/CLI smoke and whitespace checks passed. Earlier full-suite/core results remain applicable and were not rerun.

A local arm64 **0.4.5** candidate is prepared at `dist/local-storage-acceptance/AgentKeyBox.app`, signed with the existing Developer ID, provisioning profile and exact Keychain entitlements. All three executables exclude QA selectors/hooks. Normal macOS deep/strict signature verification passes; verification inside the restricted executor sandbox failed and was rechecked successfully with normal certificate access. The candidate was then installed locally as described below. It has not been notarized or published; signed sensitive-use acceptance remains open.

Cleanup completed: all seven exact QA Keychain accounts (three fixture IDs plus four imported IDs) returned not-found (44), the isolated preferences were removed and no QA image was mounted. Removed `/private/tmp/akb-qa-593D6043-A276-4C12-A1C3-453DD37062BF` (**14,500 KiB**) and `/private/tmp/akb-storage-native.zAsVTG` (**391,224 KiB**), freeing **405,724 KiB (396.2 MiB)**. This includes the synthetic plaintext originals/copies and encrypted QA backup. No shared DerivedData or `.xcresult` was created or removed. The candidate and non-secret validation records remain under `dist/local-storage-acceptance`.

## Signed local 0.4.5 public-demo login acceptance — 2026-10-27

Installed the signed arm64 candidate at `/Applications/AgentKeyBox.app`, retaining a verified **0.4.4** rollback at `dist/local-storage-acceptance/previous-AgentKeyBox.app`. The installed app and rollback pass normal macOS deep/strict signature validation; the fixed-path MCP helper is byte-identical to the installed helper. Provisioning profile and Keychain entitlements are unchanged. Native Settings confirms the data-protection Keychain path, a responding broker and zero private browser sessions. Source/release version remains 0.4.0; this is a local build update, not a public release.

Used one disposable native **Website login** item, `QA Signed 0.4.5 public demo`, ID `BA4E7D4A-D459-442E-8691-7105E3F4ADD1`, containing the test site's publicly supplied demonstration values and `https://the-internet.herokuapp.com/login`. The earlier automatic approval rejection was resolved by the user's explicit authorization of that account/destination. The installed signed MCP connector successfully discovered the item and performed this test; no unrelated production credential was read.

Native approval and authentication completed. Both `browser_login` and `browser_read` returned the expected **Welcome to the Secure Area** marker over production TLS, with the same private session and renewed link IDs. Acceptance depends on that marker, not `pageReady` alone. `browser_close` returned its fixed success message; a subsequent read failed with the fixed browser-operation error. No link was followed. Native Settings showed **zero private browser sessions**, disabled End Browser Access, and the allowed Codex request.

Exactly one new native history event, `02F0B62F-99B8-4CEE-B902-662294EC14B6`, records `allowOnce` for Codex, this item and this project. Metadata stayed byte-identical during use. Raw, URL-encoded, base64 and hex forms of known fixture values were absent from tool output, metadata and history. The retained non-secret summary is `dist/local-storage-acceptance/validation/signed-login.json`, with the pre-use fingerprints in `signed-login-baseline.json`.

Deleted only this disposable item through the native app. The global list is empty and connector discovery no longer exposes it. The two pre-existing project credentials and project metadata are byte-identical to the original pre-test file, SHA-256 `cb543c231773526c45a70a441e57e83e2dfd961e7623058d2ed3ede1c7a8bbe6`. The historical access event remains. Removed the obsolete `dist/local-storage-acceptance/validation/signed-login-pending.json` (222 bytes; 4 KiB allocated) and this verification's `Scripts/__pycache__/browser-acceptance-client.cpython-314.pyc` (33,594 bytes; 36 KiB allocated), freeing **40 KiB** of allocated file storage. No build, DerivedData or `.xcresult` was created in this continuation. Documentation whitespace checks passed; previously passed tests were not rerun.

This passes the **Developer ID signed app + data-protection Keychain + native-approved public-demo login/read/close** slice. Signed card/recovery endpoint use with production PKI, real private-account/GitHub/checkout compatibility and readable browser follow remain open. The local candidate is still unnotarized and unpublished; source/release version remains 0.4.0.

## Native protected storage lifecycle acceptance — 2026-10-26 (unreleased)

The JSON/cleanup checkpoint at the end of this historical section is superseded by the continuation above.

The endpoint/storage cases below passed in isolated profile `593D6043-A276-4C12-A1C3-453DD37062BF`, using the ad-hoc DEBUG app, separate legacy Keychain, ordinary native approval and human LocalAuthentication. Synthetic values went only to the pinned loopback HTTPS receiver. Production metadata matched the SHA-256 fingerprint recorded before this work; the installed production app remains local build **0.4.4**.

| Case / native label | Observed result |
| --- | --- |
| Cancel endpoint authentication / `QA c188723c` | Client observed pending approval and system authentication, then human cancellation. Exact fixed denial, no new history decision, no POST/reservation/metadata change, freed approval slot and responsive broker. |
| Edit while endpoint approval is pending / `QA fced0f22` | Authenticated native card rename created a consistent new revision and promptly cancelled the old request. No approval decision, POST or code-status change; destination and other metadata retained. |
| Submit one code / `QA b131f00b` | One native approval and exact-fields form POST; the first code was durably `issued` before receipt. Fixed result, no reflected secrets or cookies. |
| Native status edit and file replacement | Code 2 changed to `used` through the authenticated editor and explicit status confirmation. Importing the same eight known codes produced a new generation/revision while retaining `[issued, used, available × 6]`; card and destinations unchanged. |
| Native encrypted export | `qa-backup.dmg` opened with the synthetic password. Read-only inspection verified encrypted compressed format 2, exact known card/code payloads, matching revisions and statuses, and protected JSON files without `.env`/`env.txt`. Image was unmounted after inspection. |
| Wrong password and duplicate import | Native UI rejected a deliberately wrong password. Correct password previewed two keys/zero projects; import reported zero additions, retaining exact metadata, statuses and generation. Backup hash unchanged. |
| Real save interruption / same-profile restart | Driver observed native metadata save before Keychain write, killed only verified QA PID `16429`, and required a new boot from PID `18713`. Only the card revision became inconsistent; no POST or code-status change. |
| Approved use after interruption / `QA 08a9f5e1` | Normal Allow Once/authentication still rejected the mismatched payload. Exact fixed error/history, no additional POST/reservation and responsive broker. |
| Native export after interruption | UI reported a corrupt/type-mismatch error. `blocked-backup.dmg` was not created; the earlier valid backup remained byte-identical. |
| Native restore into empty QA | Both disposable items were deleted through the UI and zero-item metadata confirmed. Native backup import restored exact item metadata/revisions/generation; card consistency returned. Code 2 stayed `used`; all seven other codes became `needsReview`. |

The first attempt (`QA f49c1d63`) was refused at the AKB prompt before system authentication and correctly **failed** the specific authentication-cancellation case. It did not send or consume anything. The later observed cancellation above is the passing evidence. The receiver recorded **one unique POST, zero duplicates/unexpected requests and zero fixture errors** throughout these lifecycle cases. Native Settings showed zero browser sessions.

Fixed the acceptance-only backup inspector: `hdiutil -stdinpass` receives the exact password bytes followed by EOF, matching `BackupArchive`; its former trailing newline was interpreted as part of the password and caused inspection to fail. The same native-exported image passed after this correction. No production implementation changed. The current DEBUG incremental build, inspector syntax and whitespace checks passed; the prior **168 Swift tests (166 passed, two opt-in external tests skipped)** and **23 offline acceptance tests** remain applicable rather than being rerun for documentation/test-tool changes.

The earlier prepared profile `025A5B39-423F-4A5F-84C9-1683A9A21D41` was no longer running when resumed. All eight codes were still available. Its three exact QA Keychain accounts were removed/verified not-found (44), preferences removed, and its **14,268 KiB** directory deleted before using the fresh profile. The dedicated build was reused.

Supplementary native original/renamed JSON import is **awaiting human drag-and-drop**, not passed. Four verified synthetic files are prepared in `/private/tmp/akb-qa-593D6043-A276-4C12-A1C3-453DD37062BF/json-reimport`, and Finder is open there. The current UI only exposes generic file import through drop; the available computer tool does not provide reliable cross-window drag targeting. The user was asked to drop the four files individually into the isolated QA global list. No new imports had occurred at this checkpoint (two restored items remain). Originals and the prepared decrypted copies are readable files outside the executor boundary; importing does not erase them. Inspection mounts were detached and removed.

Final read-only checks passed: the restored broker answered discovery, had no pending approval slot, and known raw/common encoded synthetic values were absent from model-readable metadata, history and ledger. No unexpected destination was recorded. The active QA runner (session `53474`, app PID `18713`) and dedicated build `/private/tmp/akb-storage-native.zAsVTG` are retained only for this unfinished manual check. After import, validate all four new items as protected types with no inherited destination or injection settings, verify conservative code statuses, record their IDs for exact QA Keychain cleanup (the runner only knows its original three fixture IDs), then quit QA and remove this run's profile/build and plaintext copies. No shared DerivedData or `.xcresult` was created or removed. Only the old unused profile's **14,268 KiB (13.9 MiB)** has been freed so far.

Real provider/checkout/GitHub compatibility, other agent hosts, pure-cloud transport, team-signed sensitive use and successful readable browser follow remain separate open gates.

## Protected storage lifecycle follow-up — implementation and automated validation (unreleased)

Fixed the pending endpoint approval lifecycle: authenticated native edits now cancel the selected item's old approval/authentication before committing the change; deletion does so after metadata removal succeeds. Browser invalidation remains in the same path. Already-started endpoint operations retain their actual outcome rather than being labelled as cancelled before use. A request-ID recheck after the asynchronous decision-recording step prevents a cancelled request from persisting a late approval or starting execution.

Added `storage-acceptance-client.py` for observed native authentication cancellation, authenticated editing during a pending submission, real QA interruption between metadata and Keychain writes, and approved rejection of the persisted revision mismatch. Assertions require exact fixed output/history, unchanged receipt/status evidence and a responding broker. The DEBUG fixture exports only authentication phase, revision-match flags, a payload revision reference and code generation; the one-shot crash window is restricted to the seeded synthetic card and falls back to ordinary rollback after ten seconds. Release builds exclude these hooks. `inspect-submission-backup.py` inspects only the two known fixture items in a QA-local encrypted image and unmounts it without printing payloads/passwords.

Automated verification: **168 Swift tests executed, 166 passed, 2 opt-in external-site tests skipped, 0 failures**; **23 offline acceptance-driver tests passed**. The new real encrypted-disk-image regression round-trips typed card/code payloads, checks conservative restored statuses, and confirms that a revision-mismatch export leaves the previous valid backup byte-identical. DEBUG/release warnings-as-errors builds, release MCP/CLI smoke, strict changed-core/test formatting, Python/shell syntax, security static checks and whitespace checks passed. The final app-only request-ID guard also passed DEBUG/release rebuilds; the unchanged helpers retain their smoke results and core test evidence remains applicable. All three final release executables exclude the QA selector, phase/storage/crash hooks, certificate paths and synthetic values.

Native status: the isolated QA profile `30457FAE-57C0-466E-9314-667CEC56C35A` launched successfully. UI-tool attachment was unusually slow; no approval test was started during that wait. The final DEBUG app was loaded with a same-profile restart before testing. An `auth-cancel` attempt (`QA 54d5f911`) observed the real pending approval and LocalAuthentication phase. The automation's Escape action did not establish cancellation: authentication actually completed, history recorded `allowOnce` and the first synthetic code became `issued`. The driver correctly **failed** cancellation acceptance. Its receiver then encountered a missing case-configuration file before reading the POST body (one failing POST-handler entry); no valid receipt ledger was produced. The test client now initializes that configuration and complete synthetic field map even for negative cases, so accidental approval will have countable receipt evidence. The issued code was not reset.

**None of the new native lifecycle/replacement/backup cases has passed yet.** The remaining cases require coordinated human authentication; the readiness question was still unanswered at this checkpoint. The earlier seven endpoint outcomes remain valid evidence for their own cases. Native procedures are in [MACOS_TEST.md](MACOS_TEST.md#12-protected-field-submission-increment--native-transport-acceptance-passed); the release gates stay unchecked in [ROADMAP.md](ROADMAP.md). Production metadata matched the pre-run SHA-256 fingerprint.

The installed production bundle remains local build **0.4.4**. This follow-up does not install or publish a new release, access production secrets, establish provider/GitHub compatibility or add a cloud endpoint.

Cleanup: the QA runner exited, stopped its server and removed its app/profile/preferences. All three exact QA Keychain account lookups returned not-found (44). After preserving the results above, removed `/private/tmp/akb-storage-acceptance.j2hl50` (**402,708 KiB**) and `/private/tmp/akb-qa-30457FAE-57C0-466E-9314-667CEC56C35A` (**14,264 KiB**), freeing **416,972 KiB (approximately 407.2 MiB)**. No shared DerivedData or `.xcresult` was created or removed. Existing shared changes and retained production rollback bundles remain untouched. Continue the outstanding native cases in a fresh synthetic profile; do not revive the issued code from this failed cancellation attempt.

## Native protected-field submission acceptance — 2026-10-24 (unreleased)

All seven planned native endpoint cases passed in isolated profile `AC8EC680-5316-4231-8A4D-A3AA0CAC55BA`. The ad-hoc DEBUG app used a separate legacy Keychain, normal native approval and human Touch ID/login-password authentication. Only synthetic values were sent to its exact loopback HTTPS destinations; no payment or real account operation occurred. The installed production app remains local build **0.4.4**.

| Case / native agent label | Verified result |
| --- | --- |
| `card-form` / `QA 65d5b97c` | One form POST containing only card number, month and the literal test note; holder/year omitted; fixed `received`. |
| `card-json` / `QA 285048e4` | One JSON POST containing all four selected card fields and the note; fixed `received`. |
| `code-received` / `QA b4fa211c` | First code durably reserved before one form POST; fixed `received`. |
| `code-rejected` / `QA 87d7b8e9` | Second code reserved before one JSON POST; HTTP 422 became fixed `rejected`, without restoring availability. |
| `code-redirect` / `QA 5e06e667` | Third code reserved before one form POST; HTTP 302 became fixed `redirectBlocked`. No request followed the secret-bearing Location. |
| `code-unknown` / `QA 36071f8d` | Fourth code reserved before one JSON POST; receiver closed the connection before response headers. Fixed `unknown`, no second POST or automatic reuse. |
| `code-restart` / `QA 41ee5ffc` | Fifth code durably received once while the server held its response. The driver killed only verified QA PID `69723`; the runner restarted the same profile as PID `71794`. Fresh boot evidence followed Keychain readback, the waiting MCP call returned the exact unknown-submission error, and the restarted broker answered discovery. |

Final evidence: **7 exact `allowOnce` history decisions, 7 unique POSTs, 0 duplicate/redirect requests, 0 fixture server errors**. All five submitted codes remained `issued`; the other three remained `available`, including after restart. Each receiver entry validated the exact fields/content type and absence of Cookie/Authorization. Code entries additionally verified persisted status before receipt. Metadata remained unchanged except for the expected recovery item's update timestamp; its revision and destination were preserved. Model-readable results/history contained no raw or common encoded synthetic values, cookies, response bodies, headers or redirect destinations. The native app returned to its main window without an approval prompt after restart. These are transport outcomes, not proof of payment or sign-in success.

Added repeatable `--submission` QA with a DEBUG-only profile-bound certificate pin around the real submission transport, eight synthetic codes, a status-only Keychain read-back and ordinal/boolean receiver evidence. The new client requires an exact native history decision, exact fixed output and exactly one matching POST. Offline tests reject wrong fields, encodings, outcome text, duplicates and missing durable reservations. Existing fixture storage is never reset on restart. Native refusal, actual timeout and pending-slot checks from the earlier run remain separate valid evidence.

Validation: **167 Swift tests executed, 165 passed, 2 opt-in external-site tests skipped, 0 failures**, with warnings-as-errors; **20 offline Python acceptance tests passed**. The new real-network test confirms that the normal transport rejects the fixture certificate, the DEBUG transport accepts only its exact destination/certificate, and a different valid certificate is rejected before POST. DEBUG/release builds with warnings-as-errors, release MCP/CLI smoke, strict formatting for changed core/test Swift files and Package.swift, security static checks, shell/Python syntax and diff whitespace checks passed. All three release executables exclude the QA selector, submission configuration/status/boot paths, fixture certificate/type and synthetic values. This run adds acceptance infrastructure, not provider integration or a production installation.

Remaining gates: generic endpoint pending-edit/authentication cancellation and native interrupted-save/replacement/backup scenarios; signed-release protected-secret use and production PKI; native successful readable browser follow; real provider/checkout/GitHub workflows and in-product tests on other agent hosts. Browser-recovery cancellation evidence does not substitute for endpoint-specific checks.

Production metadata matched the pre-run SHA-256 fingerprint. The runner stopped its server, removed its isolated app/profile/preferences, and all three exact QA Keychain account lookups returned not-found (44). After recording results, removed only this run's artifacts:

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-submission-acceptance.WDhOpx` — dedicated builds, modules, logs and synthetic evidence | 405,760 |
| `/private/tmp/akb-qa-AC8EC680-5316-4231-8A4D-A3AA0CAC55BA` — QA app/profile/server certificate and evidence | 14,208 |

Total freed: **419,968 KiB (approximately 410.1 MiB)**. No shared DerivedData or `.xcresult` was created or removed. Existing shared changes, production credentials and retained rollback bundles were preserved; nothing was committed, pushed or published.

## Native recovery success and abnormal-case acceptance — 2026-10-24 (unreleased)

This run uses isolated ad-hoc DEBUG apps, synthetic credentials in separate legacy Keychain services, normal native approvals/LocalAuthentication, and the exact-certificate-pinned loopback HTTPS fixture. No production vault, agent registration, installed app or system trust is changed. The installed production bundle remains local build **0.4.4**.

Completed native acceptance:

| Case | Evidence |
| --- | --- |
| MCP recovery success | Profile `E74EAE4B-C74F-4BFA-9A04-A983F78261A2`, `QA 85009bf6`: separately approved login and recovery; fixed challenge followed by the verified-page marker, constrained read and closed-session rejection. |
| CLI recovery success | Same profile: original client-session/project handles retained; the second code was reserved and submitted once, without reusing the first code. |
| Recovery refusal | Same profile, `QA 64d0712b`: exact `deny` history event, no additional reservation or POST, session closed. |
| Close while awaiting approval | Same profile, CLI: broker confirmed a pending recovery approval, then closing its browser promptly failed the request without a decision, reservation or POST. |
| Real recovery approval timeout | Profile `C4AE102B-6F2A-43D8-ADE1-30CE6C25B7F3`, `QA 23cc5661`: untouched recovery prompt reached the actual 120-second deadline and exact `timedOut` history/result; all four codes available, zero code POSTs, session closed. |
| Close during local authentication | Second profile, CLI: DEBUG phase evidence confirmed LocalAuthentication was pending; browser closure cancelled it and the waiting request, without a decision, reservation or POST. |
| Edit selected item while approval is pending | Second profile, CLI plus native editor: authenticated rename created a new payload revision and cancelled the old request immediately; destination, IDs, scope and all code statuses remained unchanged, with zero code POSTs. |
| App interrupted during recovery POST and restarted | Second profile, CLI: the server held its response after one durable reservation and one POST; QA PID `64113` was killed, then the runner started PID `66452` with the same profile. A new boot marker followed Keychain readback: `[issued, available, available, available]`. The interrupted request failed, the restarted broker responded, and the old browser handle was rejected. No second POST occurred. |

Every native case checks model-readable output/history for raw and common encoded synthetic login values, codes, cookies and private challenge/CSRF values. Server evidence logs ordinal/status/count only and establishes reservation before receipt. The first profile's two earlier timeout attempts were accidentally approved: both **failed** timeout acceptance and consumed their own next synthetic code. Their issued statuses were never reset. The second profile is a new test dataset, not a reactivation of those codes.

Automated validation: **166 Swift tests executed, 164 passed, 2 opt-in external-site tests skipped, 0 failures**; **17 offline acceptance-driver tests passed**. DEBUG/release warnings-as-errors builds, release MCP/CLI smoke, changed-Swift strict formatting, security static checks, shell/Python syntax and diff whitespace checks passed. All three release executables exclude the QA selector, certificate/config/status/authentication-phase/boot paths and synthetic recovery values.

The QA fixture now has four synthetic codes, an ordered duplicate-rejecting receipt ledger, phase-only authentication evidence and a fresh boot marker written after Keychain readback. The client supports native edit cancellation and a same-profile crash during held submission. The native cases above all passed. After restart, native Settings displayed **zero private browser sessions** and disabled End Browser Access, with no remaining prompt. The read-back also verified that native editing preserved the known code values and statuses. Cleanup is recorded below. Real-provider/GitHub compatibility, production PKI and team-signed protected-secret use remain separate release gates. Generic protected-field/card submission and backup/interrupted-save acceptance are not established by this browser flow.

Production metadata matched this run's saved SHA-256 fingerprint. Both QA runners stopped their servers and removed their profiles/preferences; all three exact Keychain account lookups in each profile returned not-found (44). Removed only this run's artifacts after recording the evidence:

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-recovery-acceptance.8wHta4` — dedicated builds, modules, logs and synthetic summaries | 379,132 |
| `/private/tmp/akb-qa-E74EAE4B-C74F-4BFA-9A04-A983F78261A2` — first QA app/profile/fixture | 14,008 |
| `/private/tmp/akb-qa-C4AE102B-6F2A-43D8-ADE1-30CE6C25B7F3` — second QA app/profile/fixture | 14,016 |

Total freed: **407,156 KiB (approximately 397.6 MiB)**. No shared DerivedData or `.xcresult` was created or removed. Existing shared modifications and retained production rollback bundles were preserved; nothing was committed, pushed or published.

## Native recovery acceptance infrastructure and partial run — 2026-10-24 (unreleased)

Historical partial run; its open native recovery cases were completed by the acceptance run immediately above.

Added a repeatable isolated recovery QA path. `Scripts/run-browser-acceptance-macos.sh --recovery` creates a loopback-only HTTPS site and an ad-hoc DEBUG app with separate broker, Keychain service, metadata, preferences and history. `DevelopmentRecoveryFixture` accepts only its profile-bound high port, exact per-run certificate and seeded login. Certificate validation remains scoped to that challenge; no system trust is changed. The normal native approval and local authenticator still run. The runner stops its server and cleans only its own fixture accounts/directories on exit.

The QA app reads back its two known synthetic recovery codes from its isolated legacy Keychain and writes statuses only. The receiving server records whether the durable issued status existed before POST, plus a request count; no raw request bodies are logged. Existing fixture data is preserved on relaunch. The new `recovery-acceptance-client.py` supports MCP/CLI success, denial and real timeout, plus CLI closure while recovery approval is pending. It requires exact native history, fixed challenge output, receiving-server evidence and metadata/status invariants; transport failure, accidental approval, duplicate POST or a missing reservation cannot pass. A successful run requires a fresh fixture; refusal checks can retain an earlier issued code without resetting it.

### Automated results

- Full Swift suite: **166 executed, 164 passed, 2 opt-in external-site tests skipped, 0 failures**, with warnings-as-errors. This includes a new real-WebKit check proving the DEBUG fixture accepts its exact certificate, rejects a different valid fixture certificate, and rejects mismatched profile/invalid port configuration.
- **15 offline Python acceptance checks passed**, including strict fixed challenge content/session identity, original CLI recovery handles, reservation-before-POST, duplicate POST rejection and unchanged prior reservations during refusal.
- DEBUG and release builds with warnings-as-errors, release MCP/CLI smoke, strict formatting of changed Swift files, shell/Python syntax, security static checks and `git diff --check` passed.
- All three release executables exclude `AGENTKEYBOX_QA_ID`, recovery config/certificate/status paths, the pinned QA browser type, synthetic recovery values and the refusal domain. This increment adds test infrastructure; the installed production app remains local build **0.4.4**.

### Native evidence and incomplete gates

Used isolated profile `DB1B17B9-3442-4928-842F-DF9DEB23FCBB` with synthetic data only. The user agreed to local authentication. No production credential was read or changed.

- First MCP run (`QA 5d3c7893`) timed out at login approval. No login/code POST occurred. It failed the requested success case.
- Second run (`QA 6468093f`) showed **local authentication cancelled or failed**, with no new approval event and no login/code POST. It also failed success acceptance.
- On the user-requested retry (`QA 019b78da`), native login approval/authentication succeeded. MCP received only fixed `recoveryCodeRequired` output, and repeated read retained that fixed state with no code POST. The separate recovery prompt visibly named the original login, code set and exact local POST destination, defaulted to Deny, and explained issued-before-send/no automatic reuse.
- The recovery prompt then timed out. History recorded `timedOut` for that code set, both codes remained `available`, no recovery POST was received, and native Settings showed **zero private browser sessions** with End Browser Access disabled. The success driver correctly failed instead of treating the login approval or timeout as completed recovery.

This establishes native entry into the recovery gate and the observed timeout's zero-use state. It does **not** complete successful native recovery, the explicitly requested timeout/denial driver cases, CLI recovery, selected-item editing, authentication interruption or restart-race acceptance. The new tools make those repeatable; their unchecked release gates remain in [ROADMAP.md](ROADMAP.md) and [MACOS_TEST.md](MACOS_TEST.md#restricted-browser-recovery-continuation--isolated-native-acceptance-passed). GitHub and other provider compatibility, production PKI and team-signed Keychain secret-use verification remain separate.

Updated architecture/security/acceptance documentation and the roadmap. Existing shared changes were preserved. Production metadata was byte-identical to this increment's initial fingerprint; no production installation or agent registration was changed.

QA cleanup stopped the server, removed the isolated app/profile/preferences, and all three exact fixture-account lookups returned Keychain not-found (44). Removed this run's scratch after recording results:

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-native-recovery.wQGBCU` — build products, modules and test logs | 376,256 |
| `/private/tmp/akb-qa-DB1B17B9-3442-4928-842F-DF9DEB23FCBB` — QA app, server certificate/key and synthetic evidence | 13,976 |

Total freed: approximately **381.1 MiB**. No shared DerivedData or `.xcresult` was created or removed.

## Restricted browser recovery continuation — 2026-10-24 (unreleased)

Implemented a recovery step within the existing private browser. A compatible challenge after login returns only fixed `recoveryCodeRequired` text and no website content/links. MCP `browser_recover` and CLI `akb browser recover` accept an existing browser plus stored recovery-item reference; they never accept raw codes, URLs or selectors. Discovery now advertises this use for code sets, and CLI listing includes `recoveryCodeSets`.

The recovery item's native-configured HTTPS submission destination must exactly match the discovered same-origin POST action. A new native approval identifies the website login, selected set and destination; no standing grant is offered. The app revalidates visibility and metadata/payload revisions, persists one entry as `issued` before filling/submitting it, then discards the filled view and transfers same-site cookies privately into a fresh ephemeral browser. Errors and uncertain results retain the reservation. A repeated challenge closes the session without another code attempt. Editing/deleting the selected set also invalidates a pending recovery approval.

Supported forms are intentionally narrow: traditional form-encoded POST, one writable visible text input named `recovery_code` or `recovery-code`, optional hidden fields and submit/button controls, no cross-origin/action overrides or other enabled input controls. Website JavaScript remains disabled and the landing GET must be repeatable. This does not establish GitHub compatibility, TOTP/SSO support, checkout, or transfer of login state into another agent's browser.

### Verification

- Full Swift suite with warnings-as-errors: **165 executed, 163 passed, 2 opt-in external-site tests skipped, 0 failures**. The two live tests were not enabled in this increment.
- Includes **13 real WebKit runtime tests**, five covering recovery: successful private continuation and reflection filtering; failed save/stale revision/swapped item/revocation before POST; unsupported forms; rejected/repeated/cross-origin outcomes retaining reservation; and closure during an in-flight code POST. Server markers establish reservation-before-send and exactly one code POST without retaining raw request bodies. TLS trust is confined to the test subclass and generated fixture certificate; production system trust is unchanged.
- Three recovery-policy tests cover endpoint/type binding, persisted reservation/reload/exhaustion, and the separate deny-default approval. CLI tests cover recovery argument validation, denied results, code-set listing and fixed challenge status.
- **12 offline Python acceptance-driver tests passed.** Release build with warnings-as-errors passed. Final release MCP smoke produced 11 responses with 9 expected malformed-input errors, and CLI smoke passed. The actual DEBUG selector `AGENTKEYBOX_QA_ID`, refusal domain and recovery fixture value were absent from all three release executables.
- Strict formatter checks passed for the Swift files changed in this increment, including the app browser section; security static checks, shell syntax and `git diff --check` passed.
- This increment did **not** run native approval/Touch ID + Keychain + MCP/CLI recovery end-to-end. That gate, including denial/timeout and edit/authentication/restart races for this new path, is explicitly unchecked in [ROADMAP.md](ROADMAP.md) and described in [MACOS_TEST.md](MACOS_TEST.md#restricted-browser-recovery-continuation--isolated-native-acceptance-passed). Previous endpoint-refusal and native login evidence below cannot substitute for it.

### Local installation and documentation

Installed **local bundle build 0.4.4** in `/Applications/AgentKeyBox.app` with the existing Developer ID, provisioning profile and identical Keychain entitlements. The source/release version remains 0.4.0; no release was notarized or published. Stage and installed strict signature checks passed. Original metadata remained byte-identical, the fixed-path MCP helper matched the installed bundle, and the app opened normally with its existing items. Opened the empty recovery editor, confirmed its Traditional Chinese exact-destination/approval/issued/no-retry explanation, then cancelled without saving. No production secret was accessed or new QA Keychain account created. Already-running MCP helpers require reconnection to load the new tool.

Updated PRODUCT, ARCHITECTURE, INTEGRATION, ROADMAP, MACOS_TEST, UI_DIRECTION, SECURITY, compatibility notes, both READMEs and CHANGELOG to separate implemented restricted recovery from unverified native/provider flows. Existing shared changes were preserved.

Retained `dist/local-browser-recovery/AgentKeyBox.app` and integrity-checked `dist/local-browser-recovery/AgentKeyBox-before-recovery.zip` for rollback. Removed this run's scratch `/private/tmp/akb-browser-recovery.LyJIFv` after recording results: **391,244 KiB (approximately 382.1 MiB)** of builds, module caches, logs, signing material and the redundant previous-app copy. No shared DerivedData or `.xcresult` was created or removed.

## Browser closure cancels pending navigation — 2026-10-24 (unreleased)

Fixed the app's browser-close callback to cancel the pending approval belonging to that exact browser ID, dismiss local authentication if it is still active, and release the waiting broker request. Previously the callback only removed the browser from the registry; explicit CLI close or automatic expiry could leave a matching prompt waiting until it was answered or timed out. The existing request-ID guards prevent a stale authentication/operation completion from finishing a later prompt. Other leases using the same credential are not matched by this callback.

### Native and automated evidence

- Isolated ad-hoc App + Keychain + normal local authentication + **CLI** passed public-demo login, protected-page read and close. Separate CLI calls retained the original client-session/project handles. This is a synthetic public account, not GitHub or another private account.
- A different session and a different project each failed to read, follow or close the original browser, without a new approval. Positive-control reads by the original owner still returned the protected-page marker. A link from an older read was rejected without approval.
- During a new follow request, a read probe observed the exact pending-approval response. The driver immediately closed that same browser; the pending follow failed within the ten-second gate, with no new history decision. Later reads were rejected, the global approval slot was free, metadata was byte-identical and native Settings showed **zero browser sessions**, disabled End Browser Access, and no remaining prompt. The final QA history contained one allowed login and one earlier timed-out login; cancellation did not invent an allow/deny decision.
- Two earlier manually coordinated cancellation attempts were approved instead; both failed acceptance and are not counted. A later UI-tool attachment took several minutes and its login prompt timed out; this also failed the allowed-login test. The final driver uses the broker's explicit pending response rather than assuming that a sleep or an unfinished subprocess proves a pending prompt.
- **8 actual WebKit runtime tests passed**, including a new slow-navigation cancellation test: while the HTTPS fixture is handling the GET, reads are blocked; revocation fails the in-flight call, closes the lease, prevents further reads and invokes the close callback only once. Test TLS trust remains confined to the existing test subclass pinned to its generated certificate; system trust was not changed.
- **12 offline Python acceptance tests passed**, covering the previous refusal gates plus page identity/content, exact fixture-link selection, CLI follow handle mapping and cancellation/busy false positives. DEBUG/release builds passed with warnings-as-errors; release MCP/CLI smoke checks, security static checks, changed Swift test-file formatting and `git diff --check` passed. The full Swift suite was not rerun in this increment.

The public demo has only Logout as an eligible same-origin link; it returns to a password form, which the current observation policy intentionally refuses. Earlier accidental follow approvals therefore closed the session instead of returning a page. This does **not** establish successful native readable navigation. The existing synthetic WebKit test covers successful follow. Team-signed secret use, UI edit/authentication/restart races, card/recovery allowed submission and actual checkout/GitHub recovery workflows remain open.

### Local installation

Installed **local bundle build 0.4.3** in `/Applications/AgentKeyBox.app` using the existing Developer ID, provisioning profile and identical Keychain entitlements. Source/release version remains 0.4.0; no release was notarized or published. Strict signature verification passed. The updated app opened normally, original metadata was byte-identical and the fixed-path MCP helper matched the bundle. No production secret was accessed and no active agent conversation was terminated.

Retained `dist/local-browser-lifecycle/AgentKeyBox.app` and the integrity-checked `dist/local-browser-lifecycle/AgentKeyBox-before-lifecycle-fix.zip` for rollback. Existing unrelated edits and prior local-update artifacts were preserved.

Both QA apps exited, their cleanup completed and all six exact synthetic Keychain accounts were confirmed absent (status 44). Removed these directories after recording the evidence:

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-browser-lifecycle.kDeNe5` — builds, modules, logs, signing files and extra previous-app copy | 388,224 |
| `/private/tmp/akb-qa-905102BD-24A7-48D6-A8E4-1906794B8FF6` | 13,600 |
| `/private/tmp/akb-qa-8DBE64D1-F1B1-4466-A43B-502E50B945D5` | 13,600 |

Total freed: approximately **405.7 MiB**. No shared DerivedData or `.xcresult` was created or removed.

## Native refusal, timeout and pending-approval acceptance — 2026-10-24 (unreleased)

Completed the next native approval gate using isolated DEBUG App + Keychain + MCP/CLI profiles. All fixtures are synthetic: the existing public demo login, a test card, and two invented recovery codes. Card/recovery destinations use `akb-acceptance.invalid` and cannot establish successful submission or task completion. No production credential was read, edited or created.

### Results and acceptance rules

| Native scenario | Result | Evidence |
| --- | --- | --- |
| MCP card denial | Passed | `QA ada3f123`, matching `deny` event, 9.0 s |
| MCP recovery-code denial | Passed | `QA 997e86ef`, matching `deny` event, 8.7 s |
| MCP browser-login denial | Passed | `QA 638cae98`, matching `deny` event, 8.6 s |
| MCP card timeout | Passed | `QA e21ef9c3`, matching `timedOut` event and exact timeout result, 130.1 s |
| MCP recovery-code timeout | Passed | `QA cfe11271`, matching `timedOut` event and exact timeout result, 128.6 s |
| MCP browser-login timeout | Passed | `QA 26641460`, matching `timedOut` event and exact timeout result, 129.4 s |
| MCP request while another approval is pending | Passed | `QA 0e783ec3`, exact pending-approval result in about 0.16 s, no new approval event; original card prompt remained visible |
| CLI request while another approval is pending | Passed | Exit 1, empty stdout and exact pending-approval stderr in about 0.04 s |
| CLI browser-login denial | Passed | `Local agent (akb browser)`, matching `deny` event, 9.6 s |

The configured unanswered-approval deadline is **120 seconds**; observed client durations include scheduling and request overhead. Each denial/timeout required a new history event matching the caller, item and project, an error result, and byte-identical metadata before/after. Timeout additionally required at least 119 seconds and the exact native timeout message. Native Settings showed **zero private browser sessions** and disabled End Browser Access after the final run. Its history contained exactly three timeouts and the CLI denial; the busy probes added no approval.

An initial card-denial attempt and an initial card-timeout attempt were accidentally approved. Both failed their intended acceptance checks and are **not** included as passes. An initial concurrency probe also failed because the helper hid the app's pending-approval error; the implementation was corrected and the probe passed with freshly rebuilt helpers.

### Implementation and automated checks

- `BrokerError.controlledApprovalMessage` exposes only the two exact, fixed native messages for pending approval and approval timeout. Protected MCP operations and `akb browser` now preserve those outcomes. Arbitrary app/network diagnostics remain suppressed. A client/transport timeout still reports an unknown outcome because it cannot establish whether an operation ran.
- The acceptance driver now correlates new native history entries rather than accepting any error as a refusal. It checks unchanged metadata and raw/common encoded fixture-value leakage, rejects accidental approval, distinguishes native timeout from transport failure, and supports CLI refusal plus MCP concurrency probes. Seven offline harness tests are part of `Scripts/check-all.sh`.
- The DEBUG-only QA profile adds separate card/recovery fixtures. The runner removes all three exact fixture Keychain accounts when it exits. QA selectors and fixture strings were verified absent from all three release executables.
- **5 focused Swift tests and 7 Python harness tests passed**, with zero failures. DEBUG/release builds passed with warnings-as-errors. MCP/CLI smoke checks passed against final release binaries. Changed-file strict Swift formatting, security static checks, shell syntax and `git diff --check` passed. The full Swift suite was **not** rerun in this increment; earlier full-suite results below remain historical evidence.

### Installed local update and remaining scope

Installed the corrected release binaries in `/Applications/AgentKeyBox.app` using the existing Developer ID, provisioning profile and exact Keychain entitlements. The local bundle build identifier is now **0.4.2**; source/release version remains **0.4.0**. Strict signature verification passed, existing metadata stayed byte-identical, and the Application Support MCP helper matches the new bundle. Existing MCP processes must reconnect to load the new helper; no active agent conversation was terminated.

Retained `dist/local-approval-update/AgentKeyBox.app` and the integrity-checked rollback archive `dist/local-approval-update/AgentKeyBox-before-approval-fix.zip`. This is a local development update, not a notarized/published release.

This gate covers denial, native timeout and contention for the approval prompt. It does **not** establish successful card/recovery submission, recovery-code reservation/consumption after allowed submission, checkout, GitHub authentication, edit/authentication interruption or restart races. Native CLI allowed login/follow, team-signed protected-secret use, and in-product tests for other agent products remain open. The detailed acceptance commands and remaining checks are in [MACOS_TEST.md](MACOS_TEST.md).

After recording the evidence, both QA apps exited normally and their runner cleanup completed. All six exact fixture Keychain accounts across the two isolated services were confirmed absent (Keychain status 44). Removed only this increment's temporary directories:

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-approval-checks.SH1qH0` — build/module caches, logs, temporary signing files and extra previous-app copy | 388,992 |
| `/private/tmp/akb-qa-3BDAF759-5907-4033-9661-9D4FC0AA9A9C` | 13,596 |
| `/private/tmp/akb-qa-04D7CF30-68E5-4F64-91A5-7480A5A24037` | 13,600 |

Total freed: approximately **406.4 MiB**. No shared DerivedData or `.xcresult` was created or removed. The staged app and rollback archive above remain available.

## Local installation and protected-item form visibility — 2026-10-24

The installed `/Applications/AgentKeyBox.app` was still the original 0.4.0 release with **Add Key**. The working tree already contained the three protected-item editors; the earlier implementation had not updated the app the user was actually opening. No additional form implementation was necessary.

- Built the current working tree for arm64 in release configuration with warnings-as-errors, then installed a local build using the existing Developer ID team, provisioning profile, bundle identifier and exact Keychain entitlements. The bundle's build identifier is **0.4.1**; the source/release version remains **0.4.0**. This is a local development update, **not** a newly notarized or published release.
- Verified the installed native interface: **新增項目 → 信用卡** exposes card number, cardholder, expiration month/year; **網站登入** exposes sign-in page, username/email and password; **復原碼** exposes paste and file import. Opened each empty sheet and cancelled it without entering or saving secrets. Also visually inspected the card sheet's layout.
- The app and both bundled helpers passed strict signature verification. MCP and CLI smoke checks passed against the installed signed helpers, and the installed MCP helper in Application Support matches the bundle. The release executables exclude the DEBUG QA profile selector.
- Existing metadata remained byte-for-byte unchanged. No production credential was read, edited or created. This UI check does not establish new credit-card checkout, recovery-code sign-in, or signed-build secret-use acceptance.
- Kept the staged app at `dist/local-update/AgentKeyBox.app` and an integrity-checked rollback archive at `dist/local-update/AgentKeyBox-0.4.0-before-input-forms.zip` (both ignored build artifacts). No remote publication or platform submission occurred.

After verification, removed the build/module caches, temporary signing files/logs and extra old-app copy under `/private/tmp/akb-input-forms.8gmWus`, freeing approximately **130.4 MiB**. No shared DerivedData or `.xcresult` was created or removed.

## Local agent entry point and native browser acceptance — 2026-10-24 (unreleased)

Implemented `akb browser list/login/read/follow/close` for local-command agents. It uses the same app-owned browser and approvals as MCP, accepts only bounded IDs/purpose/project arguments, retains no browser state in the CLI, and exports an explicit JSON result allowlist. `clientSessionID` binds independent CLI calls to the original project/session. Agent identity is the fixed `akb-browser` entry point, not a claimed authenticated vendor. Unknown MCP clients now default to `Local Agent`.

Official interfaces for dots / ChatGPT Work, Meta Muse, Grok Bot and Claude Duet were researched and recorded in `docs/AGENT_COMPATIBILITY.md` (removed on 2026-11-05; see git history), with direct sources and a per-product acceptance gate. The user confirmed they currently have only Codex and Claude Code. The four other products therefore remain **unverified in-product**. Connected-computer execution and pure-cloud execution have different requirements; no remote MCP service, public tunnel, provider submission or cloud-browser credential handoff was implemented.

### Evidence from this run

- **153 XCTest tests: 151 passed, 2 opt-in live tests skipped, zero failures**, with warnings-as-errors. This adds four CLI ownership/input/output tests and two opt-in live checks to the prior 147 tests.
- The **two live tests also passed separately**, using the production `ControlledBrowserSession` and normal system TLS: public demo login at `https://the-internet.herokuapp.com/login` → protected Secure Area → read → close; and `https://github.com/login` preflight → exact `https://github.com/session` POST action, **without credentials or submission**. The public demo advertises its synthetic account on its login page. This is not GitHub authentication, recovery-code or checkout evidence.
- Isolated **native App + Keychain + normal LocalAuthenticator + MCP** acceptance passed against that public demo: helper initialization/discovery → native approval → protected page → read → close → subsequent read rejected. The visible Traditional Chinese prompt named the actual POST destination and the 15-minute limit, and the access log recorded `allowOnce`. No authentication bypass was added. The evidence confirms the app's normal local-authentication path, not which human authentication factor was used.
- Requests intended to exercise denial were instead approved during the run. The final client recognized this as an allowed-path run and verified/closed it. Native denial/timeout was unverified at this earlier checkpoint; it was subsequently verified in the native-refusal increment above. A passed allowed-path run is not counted as a passed denial test.
- The new CLI was invoked from the current Codex task against the isolated native broker and listed only its single public fixture login. Full CLI request construction/owner isolation/output filtering has unit coverage; a separate native CLI login/follow run remains pending. The MCP acceptance driver is a test client, not a newly configured Claude Code or Codex MCP session.
- MCP/CLI smoke tests, security static checks, shell syntax, Python syntax and `git diff --check` passed. Strict Swift format lint passed for the changed implementation/test files except `Localization.swift`, where the pre-existing `L` helper triggers two `AlwaysUseLowerCamelCase` diagnostics; those unrelated names were preserved.
- An arm64 release build passed with warnings-as-errors. All three release executables were checked to exclude `AGENTKEYBOX_QA_ID` and the native QA seed fixture. This is **not** a new notarized universal release or an installed-app update.

### Native QA support and Keychain fix

`Scripts/run-browser-acceptance-macos.sh` builds or accepts matching DEBUG binaries, refuses a release/mixed helper set, creates a separate bundle/preferences domain, broker/token/metadata/history directory and Keychain service, and seeds only the public demonstration login. It skips automatic integration installation and login-item changes. Both the native app and helpers select the same UUID profile; an invalid QA ID fails instead of falling back to the production vault. The profile selector is compiled out of release builds.

This exposed an ad-hoc Keychain capability bug: a query for an absent item could look usable while the subsequent write failed with `-34018` (missing entitlement). The capability check now verifies the running app's signed `keychain-access-groups` entitlement before selecting data-protection storage. The existing legacy fallback was successfully exercised by the isolated app. Team-signed/data-protection release behavior still needs release validation.

The final runner's startup, isolated broker readiness, termination cleanup, directory deletion and exact Keychain-item absence were verified. An earlier runner was edited while its shell was waiting and emitted a shell-read error during exit; its cleanup trap completed. The final saved script passed syntax and a fresh start/terminate/cleanup run.

No production vault, installed app, agent registration, login item, certificate trust or remote service was changed. Remaining work includes native denial/timeout/concurrent edit cases, actual GitHub authentication/recovery codes, card checkout, and release/in-product compatibility acceptance.

Cleanup completed after recording the evidence above (sizes measured before deletion):

| Removed directory | KiB |
| --- | ---: |
| `/private/tmp/akb-agents.sQJiwO` — SwiftPM debug/release products, module caches and test logs | 375,680 |
| `/private/tmp/akb-qa-396388D3-92F0-4926-BD6A-0B4E8900413E` | 13,564 |
| `/private/tmp/akb-qa-C648ABFF-E9BA-4BF6-BFD2-0D0EF7A02357` | 13,564 |
| `/private/tmp/akb-qa-9EBC885F-29EB-4021-9FD5-D06E110B3A00` | 13,596 |
| `/private/tmp/akb-qa-6EDF37FA-1230-492C-9DEE-80F58AD03566` | 13,592 |

Total: approximately **419.9 MiB**. All four exact QA Keychain service/account pairs were confirmed absent afterwards. No shared DerivedData directory or `.xcresult` was created or removed by this run.

## Controlled browser increment implemented on 2026-10-23 (unreleased)

The next local browser slice is now implemented in the working tree. It preserves the exclusion of provider-side OAuth/GitHub/payment-management services.

- Added protected `login` payloads, a native English/Traditional Chinese Website login editor, optional public `loginURL` metadata, and `.login.json` files in format-2 encrypted backups. Login values cannot use generic HTTP, commands, environment/temp-file delivery, or protected-field submission.
- Added an app-owned offscreen WKWebView with website JavaScript disabled, strict same-origin HTTPS navigation, a single traditional username/password POST form, native approval/authentication, and revision checks. The filled view/history/storage is discarded before observation resumes; only same-site cookies move internally to a fresh non-persistent browser.
- Added MCP `browser_login`, `browser_read`, `browser_follow`, and `browser_close`. Results contain constrained text and opaque links, with login/cookie reflection redaction. No raw DOM, arbitrary scripts/selectors/URLs, form editing, screenshots, cookies or storage are exported. Every follow has a separate native approval.
- Added helper-session/agent/project binding, four-session capacity, a 15-minute lifetime, Settings/menu-bar End Browser Access, and invalidation when the login is edited/deleted. Native termination cancels the browser and any pending browser prompt.
- Production TLS retains system trust. A test-only subclass accepts only the ephemeral fixture's pinned leaf certificate; no trust bypass, global certificate installation or insecure-HTTP runtime option was added.

### Verification

- **147 XCTest tests passed, zero failures**, with warnings-as-errors enabled while compiling all package products and tests. This includes the previous 135 tests plus 5 browser policy/storage/approval tests and 7 actual WebKit runtime tests in [BrowserTests.swift](../Tests/AgentKeyBoxCoreTests/BrowserTests.swift).
- The synthetic HTTPS runtime checks complete login → protected account page → same-site follow → close; submission failure; unsupported GET/cross-site/OTP forms; a real 307 cross-origin redirect whose sink received no request; reflected login/cookie values; production rejection of the self-signed test certificate; revoked/stale-payload submission; and a concurrent read/revocation during sign-in.
- Browser policy checks cover secret-free metadata and encrypted-backup round trips, developer-tool exclusion, origin/port/scheme checks, ownership/expiry, observation states, non-reopenable closure, per-use approval, and overlapping/short/truncated secret redaction.
- MCP discovery plus seven malformed protected-tool requests passed without contacting the app. CLI smoke, security static checks, changed-file strict Swift formatting and `git diff --check` passed.
- The first sandboxed attempt could compile, but could not bind a loopback socket. Tests were rerun with approved local execution outside that restriction; a diagnostic explicitly confirmed the sandbox's `PermissionError`. The fixture uses only generated synthetic credentials and certificates.

These are actual WebKit/core and MCP protocol checks, **not** a signed native UI/Touch ID + MCP end-to-end run. No real account, installed app, registration, system trust setting or third-party service was modified. Real-site compatibility, native denial/timeout/edit races, signed packaging, SSO/JavaScript/OTP, recovery-code browser use and checkout remain open. The landing page is fetched again in a fresh browser, so this increment requires a repeatable landing GET. `pageReady` is not an assertion of successful authentication.

Build/test output used `/private/tmp/agentkeybox-browser.VjrB3k`, not shared DerivedData. After the final one-time cleanup-callback adjustment, all **12 browser tests** were rerun and passed with warnings-as-errors. Cleanup completed: removed `/private/tmp/agentkeybox-browser.VjrB3k` and the five synthetic-certificate directories left by the initial sandbox-blocked fixture startup, freeing approximately **262.5 MiB**. Later fixture runs clean up their own certificates/server processes automatically. No shared DerivedData or `.xcresult` was created or removed.

The five removed fixture directory suffixes under `/private/var/folders/ys/7qypr4yj5bb5v76lb45b380w0000gp/T/akb-browser-test-` were `ECB72153-E7D9-4B5B-BD3E-1AC4654CDE0D`, `7B4C38A0-D28B-484C-ADA4-24629DE2A2DA`, `10C30FC2-087D-4167-AD9C-EF5F5F1CFD92`, `D2DD67DE-A5F2-4284-946F-00776E6C15B9`, and `6F8EB4F2-F59F-4F54-80A6-654F90F4047C`.

## Unreleased increment implemented on 2026-10-22

- `SensitivePayload.swift`: structured card number/cardholder/expiration, recovery-code sets with local status, versioned encoding, and metadata/payload revision binding. No CVV.
- `SensitiveItemView.swift`: native create/edit forms, authenticated access, paste/plain-text code import, replacement preserving matching-code history, and deliberate status correction. No raw code list or copy-to-agent action.
- `SensitiveSubmission.swift` and MCP `submit_sensitive_fields`: exact user-configured HTTPS endpoint, POST only, selected whole-field placeholders, form/JSON encoding, per-use approval, and fixed outcomes without upstream response content. No generic child process or browser insertion.
- `AgentKeyBoxApp.swift`: generic HTTP/command/temp-file/environment restrictions, approval-time snapshot check, synchronous code reservation before networking, and no automatic reissue after uncertainty. Recognized protected JSON envelopes cannot be imported or executed as ordinary credentials.
- Backup format 2 for protected types, compatibility with developer-only format 1, dedicated structured files inside the encrypted image, and restore setting non-used recovery entries to `needsReview`.
- README, product, architecture, integration, backup, UI direction, security, roadmap, and changelog updated to distinguish implementation from browser/task workflows still pending.

### Verification for this increment

On this Apple silicon Mac:

- Package build with `-Xswiftc -warnings-as-errors`: passed. The final full `swift test` also used warnings as errors while compiling the app, helper, CLI, core, and tests.
- **135 XCTest tests passed, zero failures**, including **13 new sensitive-item tests** in [SensitiveItemTests.swift](../Tests/AgentKeyBoxCoreTests/SensitiveItemTests.swift). Coverage includes typed validation, selected-field encoding, secret-free summaries, failed persistence stopping a send, unknown outcomes retaining reservation, restart/replacement/stale restore, partial-edit revision mismatch, protected-JSON recognition, backup versions, reflected/encoded response content and error details, and a real loopback redirect that was not followed.
- MCP discovery/malformed-argument smoke tests and CLI smoke test: passed. The new MCP cases reject non-string fields, URL overrides, and non-string encoding before contacting the app.
- Strict `xcrun swift-format lint` for changed Swift files: passed. Whole-repository lint still reports pre-existing findings in other files; it is not warning-free.
- Security static scan, shell syntax, and `git diff --check`: passed.
- The first sandboxed full-suite attempt failed on loopback/Unix socket and `hdiutil` permissions. The approved rerun outside that sandbox passed all tests; those environmental failures are not counted as product regressions.

Build/test commands used isolated `/private/tmp/agentkeybox-protected.T22jO1` scratch/module caches, with SwiftPM's nested sandbox disabled because it cannot start inside this tool sandbox. No shared Xcode DerivedData, installed app, agent registration, real card, real recovery code, or third-party account was changed. The separately present login/session-restoration fix in the shared working tree was preserved.

This is automated core/transport coverage, **not** a native Touch ID/GUI + MCP end-to-end run, a tested GitHub sign-in, or a completed checkout. Through-app concurrency, denial/timeout, interruption/restart, and signed-release validation remain pending. The test fixture uses synthetic values only. The endpoint must be trusted and compatible; receipt does not establish task success.

## Features previously described as future work

| Earlier wording / location | Current status | Source evidence and remaining boundary |
| --- | --- | --- |
| Allow for Session / future approval UX (`PRODUCT`, `ARCHITECTURE`, `UI_DIRECTION`) | Implemented | [ApprovalEngine.swift](../Sources/AgentKeyBoxCore/ApprovalEngine.swift): `grantSession`, `sessionApproval`, eight-hour expiry. [ApprovalPresentation.swift](../Sources/AgentKeyBoxCore/ApprovalPresentation.swift) offers the checkbox only without warnings. HTTP grants cover the same listed host, not an individual action. |
| Session/project approval management (`UI_DIRECTION`) | Session controls implemented; project-wide grants not exposed | [MainWindow.swift](../Sources/AgentKeyBoxApp/MainWindow.swift): `SettingsView`; [AgentKeyBoxApp.swift](../Sources/AgentKeyBoxApp/AgentKeyBoxApp.swift): `MenuBarContent`, `revokeSessionApprovals`. Both show active sessions and **Ask Every Time**. Enum cases for project approval do not implement a user-facing grant. |
| Menu bar (`PRODUCT`, `UI_DIRECTION`) | Implemented | `MenuBarExtra`, `MenuBarContent`: pending request, recent history, session controls, Open/Quit. No **Lock Vault** action. |
| Dedicated file credential cards (`UI_DIRECTION`) | Implemented as type-aware cards | `MainWindow.swift`: `KeyCard`; [CredentialCardText.swift](../Sources/AgentKeyBoxCore/CredentialCardText.swift): file-aware attention states; credential-type icons and bundle labels. |
| Richer provider bundles / service templates (`PRODUCT`, `ARCHITECTURE`, `UI_DIRECTION`) | Presets and App Store Connect/Supabase bundles implemented | [ProviderCatalog.swift](../Sources/AgentKeyBoxCore/ProviderCatalog.swift), [ProviderBundles.swift](../Sources/AgentKeyBoxCore/ProviderBundles.swift), [ProjectScanner.swift](../Sources/AgentKeyBoxCore/ProjectScanner.swift). Team ID and a structured Firebase project-ID/client-email editor are not implemented. Bundles do not replace file delivery. |
| Empty states and human-readable errors (`UI_DIRECTION`) | Empty states implemented; error cleanup partial | `EmptyStateView`, `ProjectDetailView`, and Settings history in `MainWindow.swift`. Some app error paths still display `localizedDescription`. |
| Auto-detect project folder (`PRODUCT`) | User-selected folder scanning and request-path resolution implemented | `ProjectScanner.scan`; MCP helper project-path resolution; [ProjectScopeResolver.swift](../Sources/AgentKeyBoxCore/ProjectScopeResolver.swift). Do not describe this as automatic discovery of any foreground IDE project. |
| Future safer HTTP/proxy path (`ARCHITECTURE`, `INTEGRATION`); provider-specific operations checked off (`ROADMAP`) | Generic HTTP broker implemented; provider-specific action policy not implemented | [HTTPRequestBroker.swift](../Sources/AgentKeyBoxCore/HTTPRequestBroker.swift), MCP `http_request`, app `handleHTTPRequest` / `executeApprovedHTTPRequest`. Unlisted hosts ask for approval; they are not an unconditional hard block. |
| Credential metadata and notes (`PRODUCT`) | Metadata implemented; notes absent | [Models.swift](../Sources/AgentKeyBoxCore/Models.swift): label, service, project, environment, kind, settings, timestamps. No notes field. |
| `.env` export (`PRODUCT`) | Encrypted-backup use case implemented; no standalone plaintext-export UI | [BackupArchive.swift](../Sources/AgentKeyBoxCore/BackupArchive.swift) writes `.env` and `env.txt` inside encrypted backups; Settings has backup export/import. These are distinct from a new plaintext export feature. |
| Signing, notarization, real-Mac launch listed as future gates (`ARCHITECTURE`) | Implemented with historical verification | [build-release-macos.sh](../Scripts/build-release-macos.sh), [notarize-release-macos.sh](../Scripts/notarize-release-macos.sh), and the 0.4.0 release checklist. Physical Intel Mac validation remains open. |
| Reference image described as not a production master (`BRAND`) | Production assets already exist | [assets/brand/README.md](../assets/brand/README.md); build script bundles `AppIcon.icns` and runtime assets. The large-size master is raster, with separate small-size SVG masters. |

## Implemented baseline

### Product and agent path

- Native SwiftUI macOS app; local Keychain and metadata storage; no hosted account/backend.
- Project/global credential organization, creation/editing/deletion, `.env` import, supported key-file import, and project-folder setup.
- Claude Code/Codex adapters and MCP `list_credentials`, `request_credential`, `http_request`, and `run_with_secret`.
- Native approval, denial, two-minute unanswered-approval timeout, and local authentication; missing-credential entry can wait up to ten minutes.
- Session grants with the boundaries listed above; no persistent project approval UI.
- Generic HTTPS execution, environment injection, protected temporary-file delivery, bounded output, and common secret redaction.
- Type-aware cards, provider metadata bundles, menu bar, English/Traditional Chinese, setup/empty states, and persistent approval history.
- `akb run` for terminal tools; it hands raw values to the child process and does not redact its terminal output.

### Storage and local hardening

- Team-signed builds with the provisioning profile use the data protection keychain and user-presence authentication. Session grants can reuse the approved context.
- Authenticated owner-only Unix socket, signed-helper/CLI peer checks in team-signed builds, freshness/replay protection, request limits, and timeouts.
- Encrypted backup export/import, independently readable recovery contents, and **Remove Keys from Files** guarded by a covering backup.
- Claude Code deny-rule setup and agent instructions. Instructions alone are not isolation; plaintext copies remain readable outside enforced guards.

### Baseline coverage (included in the full-suite rerun above)

[AgentKeyBoxCoreTests.swift](../Tests/AgentKeyBoxCoreTests/AgentKeyBoxCoreTests.swift) includes:

- `testSessionApprovalIsBoundToOperationAndDelivery`
- `testSessionApprovalForHTTPCoversTheSameListedHostOnly`
- `testUnlistedHostsAndAkbRunAreNeverSessionGranted`
- `testSessionApprovalsExpireAndCanBeRevoked`
- `testPromptOffersSessionApprovalOnlyWithoutWarnings`
- `testHTTPPolicyLetsUserDecideOnUnlistedHost`
- `testBrokerReplayGuardRejectsReplayAndExpiredRequests`
- `testApprovedCommandRunnerTemporaryFileDeliveryCleansUp`

[BackupArchiveTests.swift](../Tests/AgentKeyBoxCoreTests/BackupArchiveTests.swift) covers backup layout, coverage, import planning, snapshot freshness, and format/password validation. MCP/CLI smoke scripts and static checks are wired into `make check`.

## Previously verified on a real Mac

The 0.4.0 [release checklist](RELEASE_CHECKLIST.md) records:

- SwiftUI app, Keychain/Touch ID, and the Unix-socket broker.
- Approval prompts, denial, and opted-in session approvals.
- Developer ID signing, notarization, and installation from a quarantined download.
- The universal build's x86_64 slice under Rosetta.
- Claude Code and Codex registration, metadata listing, HTTP/command approvals, denial, and redacted output; Codex project-path resolution from its working directory.
- Agent guard behavior when agents start in the project; the checklist records the limitations of instruction-only protection.
- Encrypted backup export, Finder opening, file cleanup, and import.
- Approval timeout and its persisted history entry.

These results are historical evidence, not a fresh runtime certification.

## Remaining work and verification limits

- Typed card/recovery storage, controlled endpoint submission, traditional-form browser login and restricted recovery continuation are implemented but unreleased. Browser checkout/GitHub sign-in and signed native app + MCP end-to-end verification remain open.
- Operation/resource-specific HTTP authorization: same-host approval currently covers multiple actions.
- Search/filter and complete human-readable error handling.
- Permanent project approvals, credential notes, further provider fields, and additional agent adapters remain unimplemented backlog, not completed features.
- Provider-side credential/OAuth/payment-management connectors were removed from the selected direction on 2026-10-22. Local presets, dashboard links, and approved API calls remain.
- A physical Intel Mac run is still unverified.
- Replay rejection and `.p8` temporary-file cleanup have recorded unit coverage, but their through-app scenarios are explicitly not yet verified in the release checklist.

Use [MACOS_TEST.md](MACOS_TEST.md) when new code or unresolved runtime concerns warrant another run. This increment used only its private SwiftPM scratch directory; it generated no `.xcresult` or shared DerivedData. Cleanup completed: removed `/private/tmp/agentkeybox-protected.T22jO1` (approximately 244 MiB, including build output, module caches, and temporary test logs). Test evidence is summarized above; no shared build directories were touched.

## Product goal and current boundary

The goal is to let agents complete approved tasks without reading raw sensitive values. Generic command execution and `akb run` do not enforce that guarantee: approved processes can disclose values they receive. HTTP execution keeps secret insertion inside AgentKeyBox, but redaction is not full containment. New types must validate a controlled execution and observation boundary before being advertised as agent-ready.
