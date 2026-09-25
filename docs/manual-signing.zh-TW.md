# 手動簽章（公司團隊、沒有「管理」金鑰時）

預設的 TestFlight 流程用 **Xcode 雲端簽章**，需要「**管理**」角色的 App Store Connect API 金鑰。在公司團隊裡，
你通常只是「**App 管理**」或「**開發者**」，公司也不會把「管理」金鑰放到你的 Mac 上。手動簽章只用你**拿得到**的東西：

| 需要什麼 | 找誰拿 | 用途 |
|---|---|---|
| **Apple Distribution** 憑證和私鑰（`.p12`） | 團隊的「管理」角色建立一次；或從你 Mac 上已經有的那張匯出（鑰匙圈存取 › 登入 › 我的憑證 › 輸出） | 簽 archive |
| 每個 bundle ID 各一個 **App Store** 描述檔（app **和**每個 extension、watch app） | 團隊的「管理」角色（Certificates, Identifiers & Profiles › Profiles › + › App Store Connect） | 簽 archive |
| 上傳用的驗證：**「App 管理」API 金鑰**，或**你的 Apple ID＋App 專用密碼** | 金鑰找「管理」角色；App 專用密碼自己在 appleid.apple.com 產生 | 上傳 TestFlight |

Xcode 自動管理的描述檔（名稱像「iOS Team Store Provisioning Profile: …」）**不能用**，Xcode 不允許拿它做手動簽章。
萬用字元描述檔會被略過，請每個 bundle ID 各用一個。

以下指令都在 ios-selfhosted-ci 的資料夾裡執行（`cd ~/ios-selfhosted-ci`）。

## 1. 把簽章憑證放到 runner 那台 Mac

**在你平常上架用的那台 Mac**（或「管理」角色建立憑證的那台）：

1. 鑰匙圈存取 › **登入** › **我的憑證** › 在「Apple Distribution: <公司> (<TEAMID>)」按右鍵 › **輸出** ›
   格式選「個人資訊交換 (.p12)」，設一組密碼。
   - 看不到三角形、格式不能選 .p12？把鑰匙圈存取完全結束再重開；或同時選取憑證**和**它的私鑰（類別選「密鑰」）一起輸出；
     或用 Xcode › Settings › Accounts › （團隊）› Manage Certificates › 右鍵 › Export Certificate。
2. 找出 App Store 描述檔的檔案：`python3 scripts/profiles.py list --team <TEAMID>` 會印出每個描述檔的路徑（沒有
   `ci.keychain` 的 Mac 也能用）。檔案都在 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.mobileprovision`。
3. 用 AirDrop 把 `.p12` 和 `.mobileprovision` 傳到 runner（會放在「下載項目」`~/Downloads`）。

**在 runner 那台 Mac** 的 **Terminal.app** 執行（要輸入密碼的步驟不要透過 AI agent）：

```bash
scripts/ci-signing-setup.sh keychain                          # 每台 Mac 一次；登入鑰匙圈沒有任何憑證也沒關係
scripts/ci-signing-setup.sh p12 ~/Downloads/company.p12       # 會問 .p12 的密碼
scripts/ci-signing-setup.sh profile ~/Downloads/*.mobileprovision
rm ~/Downloads/company.p12                                    # 裡面有私鑰，用完刪掉
```

`profile` 會逐一檢查：是不是 App Store 描述檔、有沒有過期、它的憑證在不在 `ci.keychain`。

## 2. 那個團隊的上傳驗證

用那個團隊的「App 管理」API 金鑰：

```bash
scripts/ci-signing-setup.sh asc ~/Downloads/AuthKey_XXXX.p8 <Issuer ID> --team <TEAMID>
```

或用你的 Apple ID＋App 專用密碼（account.apple.com › 登入與安全性 › App 專用密碼）：

```bash
scripts/ci-signing-setup.sh appleid you@example.com --team <TEAMID>
```

同一個團隊兩種都有時，用 API 金鑰。用 `scripts/ci-signing-setup.sh status` 檢查全部設定。

## 3. 在 app repo 使用

`team-id` 必須是**公司的** Team ID，不是設定檔裡你自己的：

```bash
scripts/bootstrap-repo.sh MyCompanyApp --signing manual --team <TEAMID>
```

或直接改 repo 的 `.github/workflows/testflight.yml`：

```yaml
jobs:
  testflight:
    uses: puyanlin/ios-selfhosted-ci/.github/workflows/testflight.yml@v1
    with:
      scheme: MyCompanyApp
      team-id: <TEAMID>
      signing: manual
      # branch / upload / xcode / build-number 照原本
```

TestFlight job 會：

1. 把這個團隊所有 App Store 描述檔（同一張 Distribution 憑證）交給 `xcodebuild`，每個 target 依 bundle ID 用自己的；
2. 用手動簽章 archive；
3. 依 archive 裡實際的 bundle（app、extension、watch app、App Clip）匯出 `.ipa`；
4. **檢查 entitlement** 都還在、而且是正式環境的值（`aps-environment: production`、`get-task-allow: false`），不對就失敗；
5. 用 `altool` 上傳（API 金鑰或 Apple ID）。

## 安全性

公司的私鑰現在放在 runner 的 `ci.keychain`：凡是以 runner 那個 macOS 使用者身分執行的程式，都能用公司的名義簽章。
公司的 repo 一定要是 private；runner 最好用獨立的 macOS 使用者；匯入後刪掉 `.p12`；那台 Mac 不再用、或你離開專案時，
請「管理」角色撤銷這張憑證。

## 限制

- 送審（[asc](https://asccli.sh)）需要 API 金鑰；只有 Apple ID 的話，送審要在網頁上按。
- 透過 `altool` 上傳時，「僅限內部測試」設定不會生效。
- 描述檔**和** Distribution 憑證都是一年到期；描述檔到期前 30 天 job 會警告。換新描述檔：再跑一次 `profile`；
  換新憑證：重做步驟 1（新的 `.p12` 和描述檔）。
- 已實測：公司團隊裡的單一 target app，以及雲端簽章沒有退步。尚未實測：有 extension＋watch app 的多 target app 用手動簽章，
  以及從 runner job 用 Apple ID 上傳。
