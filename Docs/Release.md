# Auralis 测试发布

`.github/workflows/release.yml` 负责从版本 tag 构建并发布一个不依赖付费开发者账户的 GitHub
测试 Release，资产包括：

- Android 手机/平板 debug APK
- Android TV debug APK
- 未签名 macOS DMG
- `SHA256SUMS.txt`

iOS/iPadOS 暂不进入 Release。iOS/iPadOS 的设备安装和运行仍需要 Apple 签名，因此等后续
准备好 Apple Developer 账户后再增加 IPA 发布。

## 触发方式

发布只接受三段式版本 tag，例如 `v1.2.0`。tag 必须已经指向要发布的提交。

```bash
git tag -a v1.2.0 -m "Auralis 1.2.0"
git push origin v1.2.0
```

也可以在 GitHub Actions 中手动运行 `Auralis Test Release`，填写一个已经存在的版本 tag。
Android 和 macOS 构建成功后，流水线会创建或更新对应的 GitHub Release，并将其标记为
pre-release 测试版本。

## 为什么 Android 可以直接安装

流水线构建的是 `assembleDebug`，Android Gradle Plugin 会使用 runner 上的 debug keystore
自动签名；这不是 Google Play 发布签名，也不需要购买开发者账户。debug APK 可以直接安装到
允许安装外部来源应用的 Android 手机、平板或电视上。

Android CI 会缓存同一把临时 debug key，使后续测试包可以作为更新安装，而不是每次都因为签名
变化要求先卸载旧包。这个 key 只用于测试，不能用于正式发布或 Google Play。

因此，资产文件名会明确包含 `-debug`，不要把它当作正式商店包。

## 为什么 macOS 仍然可以提供 DMG

macOS 只负责把未签名的 `Auralis.app` 打进 DMG，不执行 Developer ID 签名、公证或
staple。首次打开时，Gatekeeper 可能阻止直接双击；可以在 Finder 中右键应用选择“打开”，
或在系统设置中允许本次运行。

未签名 DMG 适合当前早期阶段的本机测试，不代表可以无提示分发给其他用户。

## 版本和产物

tag `v1.2.0` 会注入：

- Android `versionName=1.2.0`
- Android 和 macOS 构建号使用该次 Actions run number
- macOS `MARKETING_VERSION=1.2.0`

发布资产名称包含完整 tag，例如：

- `Auralis-v1.2.0-Android-Mobile-debug.apk`
- `Auralis-v1.2.0-Android-TV-debug.apk`
- `Auralis-v1.2.0-macOS-unsigned.dmg`

所有证书、描述文件、keystore 和私钥都不再是当前测试发布流程的必需项。后续增加正式
iOS IPA、Android release APK 或 macOS 公证包时，再单独引入相应的签名配置；不要为了当前
测试把任何密钥写入仓库。
