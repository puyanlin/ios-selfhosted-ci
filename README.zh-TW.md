# ios-selfhosted-ci

把你桌上的 Mac 變成所有 iOS app 的 CI：**PR 自動編譯檢查、用手機把任意分支打包上 TestFlight、AI 自動 code review**，全部集中在一個 repo 管理。

[English →](README.md)

## 為什麼

獨立開發者、手上有好幾個 private iOS app 的情況：

| | 每月費用（約 12 個 app） | AI review | GitHub 必過檢查 | 手機打任意分支 |
|---|---|---|---|---|
| **本專案（自己的 Mac）** | 約 $0 | ✅ Claude，算在你的訂閱 | ✅ | ✅ |
| Xcode Cloud | 25 小時免費，超過 $49.99 起 | ❌ | ❌ | ✅ |
| Codemagic／Bitrise | 約 $50 起 | ❌ | ✅ | ✅ |
| GitHub 代管 macOS | 約 $60 起 | ✅ | ✅ | ✅ |

功能：

- **PR check**：每個 PR 在你的 Mac 上跑 unit test（跳過 UI test；沒有 test 就只編譯，也可以改編不簽章的實機版），搭配 ruleset 強制「通過才能 merge」。
- **隨時隨地打 TestFlight**：*Actions › TestFlight › Run workflow*，輸入**任何**分支、tag 或 commit（那個分支甚至不需要包含 workflow）。build 號預設 `YYMMDD01`，撞號時 Xcode 會自動往上加。
- **Claude review**：每個 PR 由 Claude（預設 Opus）留 inline comment 和總結，跑在專用 runner 上，不會卡住 build。
- **不用管憑證檔**：Xcode 雲端簽章＋App Store Connect API 金鑰；不用把 p12、profile 放進 secrets，也不用 fastlane match。（已經在用 fastlane？見 [docs/fastlane.md](docs/fastlane.md)。）
- **新 app 一個指令設好**：`scripts/bootstrap-repo.sh MyApp`，runner、workflow、ruleset 一次到位，並跑一次編譯驗證。
- **改一次、全部生效**：app repo 只呼叫這裡的共用 workflow；prompt、模型、流程都在這裡改。

> ⚠️ **只能用在 private repo。** self-hosted runner 掛在 public repo 上，任何人發的 PR 都能在你的 Mac 上執行程式。腳本會拒絕 public repo。開始前請先讀 [docs/security.md](docs/security.md)。

## 建議環境

| | 建議 |
|---|---|
| 機器 | Apple silicon Mac mini，16GB 以上記憶體（同時跑 VM／容器建議 24GB 以上），SSD 至少留 256GB |
| macOS 使用者 | 最好**另外開一個 CI 專用的一般使用者**（見安全說明）；設定自動登入、永不睡眠 |
| 電源 | 系統設定 › 能源：防止睡眠、停電後自動開機 |
| Xcode | 正式版放在 `/Applications/Xcode.app`；beta 放別處，只在需要時明確指定 |
| 工具 | [GitHub CLI](https://cli.github.com)（`gh auth login`）、Claude Code（`claude`）、[bun](https://bun.sh)（讓 review 快速啟動） |
| GitHub | private repo 要用 ruleset 需要 **GitHub Pro**（個人）或 Team（組織）；其他功能 Free 就能用 |
| 網路 | 建議有線網路；review workflow 指定本機的 `claude`／`bun`，避免每次重新下載 |

## 誰可以設定

**App Store Connect**（API 金鑰放在 runner 那台 Mac 上）：

| 步驟 | 需要的角色 | 說明 |
|---|---|---|
| 為團隊開通 App Store Connect API（只有第一次） | **帳號持有人** | 「使用者與存取權限 › 整合」頁的「要求權限」按鈕 |
| 建立**團隊** API 金鑰 | **管理**（或帳號持有人） | 其他角色打不開「團隊金鑰」頁 |
| 本專案使用的金鑰角色 | **管理** | 這裡所有功能都實測過：自動簽章 archive、雲端管理發佈簽章、上傳 TestFlight、`asc-release.py` 送審 |
| 只用 `asc-release.py`（建版本、填新功能、送審） | 「App 管理」應該就夠 | 本專案沒有實測；回覆使用者評論需要「管理」 |
| 個人 API 金鑰 | ❌ 不支援 | Apple 文件寫明個人金鑰不能用 Provisioning 相關 API（簽章需要），而且腳本需要 Issuer ID |

雲端管理的發佈簽章，帳號持有人和「管理」預設就能用；「開發者」要另外勾選 *Access to Cloud Managed Distribution
Certificate* 權限。「App 管理」角色的**金鑰**能不能雲端簽章，官方沒有寫清楚，沒實測過之前請用「管理」。

如果 app 屬於另一個團隊，而你在那邊只是「App 管理」或「開發者」（公司帳號常見的情況），請用
**[手動簽章](docs/manual-signing.zh-TW.md)**：由團隊的「管理」角色提供 Apple Distribution 憑證和 App Store 描述檔
（或從你平常上架用的那台 Mac 匯出），上傳用「App 管理」金鑰或你的 Apple ID＋App 專用密碼，完全不需要「管理」金鑰。
不然也可以只用 PR check 和 Claude review（`--no-testflight`）。

**GitHub**：要有 app repo 的管理員權限（runner、secret、ruleset）。**private** repo 要用 ruleset，個人帳號需要
GitHub Pro，組織需要 Team 方案。

**Mac**：runner 使用者的登入鑰匙圈裡要有該團隊的 *Apple Development* 憑證（Xcode › Settings › Accounts 會建立），
`ci-signing-setup.sh keychain` 會把它複製進 `ci.keychain`。

來源：[Creating API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) ·
[Cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/) ·
[Program roles](https://developer.apple.com/help/account/access/roles/)

## 設定步驟（約 20 分鐘）

### 1. 取得這個 repo

可以直接引用（`puyanlin/ios-selfhosted-ci@v1`），或 **fork 一份**（建議，更新由你控制）。fork 的話，把 `.github/workflows/*.yml` 裡的 `puyanlin/ios-selfhosted-ci` 換成你的 fork，並設定下面的 `CI_REPO`。fork 成 private 時要開放存取：*fork › Settings › Actions › General › Access →「Accessible from repositories owned by the user」*。

```bash
git clone https://github.com/puyanlin/ios-selfhosted-ci ~/ios-selfhosted-ci
mkdir -p ~/.config/ios-selfhosted-ci
cp ~/ios-selfhosted-ci/config.example ~/.config/ios-selfhosted-ci/config
open -e ~/.config/ios-selfhosted-ci/config      # 填 GH_OWNER、TEAM_ID、CI_REPO…
```

### 2. 簽章（每台 Mac 一次）

1. **簽章憑證**：先確認 Xcode 已經建立你的 *Apple Development* 憑證（Xcode › Settings › Accounts），然後：
   ```bash
   scripts/ci-signing-setup.sh keychain     # macOS 會跳視窗要一次登入密碼
   ```
   會建立只放簽章憑證的 `ci.keychain`。job 只會解鎖它，碰不到你的登入鑰匙圈。
2. **App Store Connect API 金鑰**：App Store Connect › 使用者與存取權限 › 整合 › App Store Connect API › 團隊金鑰 › **＋**，存取權限選「**管理**」（雲端管理的發佈簽章需要）。下載 `.p8`（只能下載一次！）並記下 Issuer ID：
   ```bash
   scripts/ci-signing-setup.sh asc ~/Downloads/AuthKey_XXXXXXXXXX.p8 <Issuer ID>
   scripts/ci-signing-setup.sh status
   ```

### 3. 每個 app repo

```bash
scripts/bootstrap-repo.sh MyApp
# 一個 repo 兩個 app、分在不同分支：
scripts/bootstrap-repo.sh MyApp --scheme "MyApp MyAppPro" --branch pro
# SDK 沒有 arm64 模擬器版本：
scripts/bootstrap-repo.sh MyApp --destination device
# review 用繁體中文留言（或在設定檔設 REVIEW_LANGUAGE）：
scripts/bootstrap-repo.sh MyApp --review-language "Traditional Chinese (Taiwan)"
# 只要 PR check＋review，不要 TestFlight：
scripts/bootstrap-repo.sh MyApp --no-testflight
# 先不要 ruleset（預設分支還編不過時）：
scripts/bootstrap-repo.sh MyApp --no-ruleset
# PR check 只編譯（test 暫時壞掉時）／跳過部分 test：
scripts/bootstrap-repo.sh MyApp --no-test
scripts/bootstrap-repo.sh MyApp --skip-testing "MyAppTests/SlowTests"
```

已經設好的 repo 重跑也安全：只會更新有變動的呼叫檔，不會重複建立 ruleset。在設定檔設 `XCODE_BETA_APP`，TestFlight 的 Xcode 選單就會多出 beta 選項。

> 用 Claude Code 的話：`ln -s ~/ios-selfhosted-ci/skills/ios-ci-setup ~/.claude/skills/ios-ci-setup`，之後直接說「幫 MyApp 設 CI」，[ios-ci-setup skill](skills/ios-ci-setup/SKILL.md) 會幫你跑這些步驟。

### 4. Claude review 的 token（一次，之後每個新 repo 再設一次）

在**你自己的終端機**執行（不要透過 AI agent，token 才不會留在對話紀錄）：

```bash
claude setup-token                       # 複製 sk-ant-oat 開頭的 token
scripts/set-claude-token.sh              # 設定所有有 runner 的 repo；或：set-claude-token.sh MyApp
```

GitHub 個人帳號沒有「全帳號共用」的 Actions secret，所以每個 repo 都要設。

## 日常使用

- **開 PR**：`pr-check / build` 和 `review / review` 會同時開始跑。
- **打包上 TestFlight**：*Actions › TestFlight › Run workflow*，填分支（任何 ref）、是否上傳、Xcode、build 號。手機 GitHub app 也可以。
  ```bash
  gh workflow run testflight.yml -R you/MyApp -f branch=feature/x          # 終端機
  gh workflow run testflight.yml -R you/MyApp -f branch=main -f upload=false  # 試跑
  ```
- **修改流程**：改這裡的 `.github/workflows/*`，再 `git tag -f v1 && git push -f origin v1`，所有 app 下次執行就會用新版。（想要不可變的版本，可以改成釘在 commit SHA。）

## 送審 App Store

`scripts/asc-release.py` 透過 App Store Connect API 完成整個送審流程，不用開網頁、也不會遇到登入過期：

```bash
scripts/asc-release.py status --bundle-id com.example.app
scripts/asc-release.py submit --bundle-id com.example.app --version 1.4.0 \
    --notes-dir fastlane/metadata \            # <語系>/release_notes.txt（fastlane deliver 的目錄結構）
    --release after-approval --no-phased --dry-run    # 拿掉 --dry-run 才會真的送審
```

它會建立或沿用版本、等 build 處理完（`--wait-build 30`）、選 build、填各語系「新功能」、設定發佈方式／階段性發佈／審核備註、檢查沒有漏填，最後送審；被退件後重新送審也適用。`--dry-run` 會列出每一步但不改任何東西。

用 AI agent 的話，[`skills/app-store-submit/SKILL.md`](skills/app-store-submit/SKILL.md) 是 Claude Code 的 skill：讓你選語系、從 git 紀錄起草更新說明、讓你確認計畫，你同意後才送審。它可以用繁中或英文跟你溝通（設定檔的 `LANGUAGE`）。安裝：`ln -s ~/ios-selfhosted-ci/skills/app-store-submit ~/.claude/skills/app-store-submit`。

## 指定 Xcode 版本

所有 workflow 用同一套規則選 Xcode（見 `xcode.sh`）：

1. `xcode` 參數：可以填路徑（`/Applications/Xcode-beta.app`），**也可以填版本號**（`27.1`，或 `27`＝已安裝的最新 27.x，優先正式版）；
2. 沒填就看 repo 裡的 **`.xcode-version`** 檔（xcodes／fastlane 的慣例，內容例如 `27.1`）；
3. 都沒有就用 runner 預設（`/Applications/Xcode.app`）。

可以用 [xcodes](https://github.com/XcodesOrg/xcodes) 並存安裝多個版本，再用 `.xcode-version` 讓各 repo 固定版本。

參數說明見 [README.md 的 inputs 表](README.md#reusable-workflow-inputs)。

## 延伸閱讀

- [docs/security.md](docs/security.md)：威脅模型與加固建議
- [docs/troubleshooting.md](docs/troubleshooting.md)：實際踩過的坑與解法
- [docs/fastlane.md](docs/fastlane.md)：沿用既有的 fastlane lane
- [docs/manual-signing.zh-TW.md](docs/manual-signing.zh-TW.md)：公司團隊、沒有「管理」金鑰時的手動簽章

## 授權

MIT
