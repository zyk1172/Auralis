# Auralis 跨平台发布

`.github/workflows/release.yml` 负责从稳定版本 tag 构建并发布以下 GitHub Release 资产：

- Android 手机/平板签名 APK
- Android TV 签名 APK
- iOS ad-hoc IPA
- macOS Developer ID 签名并公证的 DMG
- `SHA256SUMS.txt`

## 触发方式

正式发布只接受三段式稳定版本 tag，例如 `v1.2.0`。tag 必须已经指向要发布的提交。

```bash
git tag -a v1.2.0 -m "Auralis 1.2.0"
git push origin v1.2.0
```

也可以在 GitHub Actions 中手动运行 `Auralis Release`，填写一个已经存在的稳定版本 tag。
所有平台构建成功后，流水线才会创建或更新对应的 GitHub Release；任何签名、导出、公证或
校验失败都会阻止发布。

## 必需的 Actions Secrets

所有证书、描述文件、keystore 和私钥都只应保存为 GitHub Actions Secrets，不得提交到仓库。
Base64 值可以按以下方式生成，避免把换行写入 secret：

```bash
base64 < file | tr -d '\n'
```

### Android

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Android workflow 会将 keystore 解码到 runner 的临时目录，构建结束后删除。`app-mobile` 和
`app-tv` 使用同一个发布 keystore，版本号由 tag 和 Actions run number 注入，而不是从源码中
固定读取。

### iOS

- `APPLE_TEAM_ID`
- `APPLE_IOS_DISTRIBUTION_CERTIFICATE_BASE64`
- `APPLE_IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`
- `APPLE_IOS_PROFILE_BASE64`
- `APPLE_IOS_INTENTS_PROFILE_BASE64`
- `APPLE_IOS_LIVE_ACTIVITY_PROFILE_BASE64`

三个 provisioning profile 必须分别覆盖这些 Bundle ID：

- `com.auralis.player.ios`
- `com.auralis.player.ios.AuralisIntents`
- `com.auralis.player.ios.AuralisLiveActivity`

默认导出方式是 `ad-hoc`，适合从 GitHub Release 下载后安装到已登记设备。手动运行 workflow
时也可以选择 `app-store`，但它仍然只是导出的 IPA，不是自动上传到 App Store Connect；它
不能替代 TestFlight 或 App Store 审核上传流程。

### macOS

- `APPLE_TEAM_ID`
- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64`
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `DEVELOPER_ID_APPLICATION`，例如 `Developer ID Application: Example (TEAMID)`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`
- `APPLE_NOTARY_KEY_BASE64`，App Store Connect API `.p8` 私钥的 Base64 值

macOS 构建会创建临时 keychain，使用 Developer ID Application 签名，提交 DMG 到 Apple
notary service，staple 公证票据，然后运行 `spctl` 和 `stapler validate`。未完成公证的 DMG
不会进入 GitHub Release。

## 版本和产物

tag `v1.2.0` 会注入：

- Apple `MARKETING_VERSION=1.2.0`
- Android `versionName=1.2.0`
- Apple/Android 构建号使用该次 Actions run number

发布资产名称包含完整 tag，例如：

- `Auralis-v1.2.0-Android-Mobile.apk`
- `Auralis-v1.2.0-Android-TV.apk`
- `Auralis-v1.2.0-iOS.ipa`
- `Auralis-v1.2.0-macOS.dmg`

仓库设置中的 Actions workflow permissions 还必须允许 `GITHUB_TOKEN` 写入 repository contents，
否则构建会成功但最后的 Release 上传会因权限不足而失败。
