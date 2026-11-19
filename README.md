# Cleaner

Cleaner 的首个 iPhone 开发里程碑是截屏清理。工程采用 Swift 6、SwiftUI、PhotoKit 和系统 SQLite，部署目标为 iOS 17。

## 运行

在 Xcode 16 或更新版本中打开 `Cleaner.xcodeproj`，选中 `Cleaner` scheme 和 iPhone 模拟器后运行。真机运行需要在 Signing & Capabilities 中选择开发者团队，并按需替换原型 bundle identifier。

模拟器可通过 **Device → Trigger Screenshot** 生成带系统截屏标记的测试资产。回到 Cleaner，进入 **Scan My Photos → Screenshots**，预览并选入测试截屏，再进入复核。取消系统确认后，选择和免费额度应保留。确认移入「最近删除」后，结果页、本地历史和额度应同步更新。

```sh
xcodebuild -project Cleaner.xcodeproj -scheme Cleaner \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

## 语言

支持英语、西班牙语、德语、法语和简体中文。Cleaner 读取 iOS 的语言偏好，英语是默认回退语言。可在 iOS 的 Cleaner 应用设置中选择首选语言，或在 Xcode 的 **Edit Scheme → Run → Options** 中分别设置 **App Language** 和 **App Region** 来验证语言和地区格式。

界面、错误提示和数量单复数使用 `App/Localizable.xcstrings`，系统照片授权弹窗里的用途说明使用 `App/InfoPlist.xcstrings`。

## 当前范围

- 示例无需照片授权。实际扫描支持完整和有限授权，截屏按月展示，可按 30 天筛选。
- 先预览，再逐项选择。复核显示选择数量、收藏项和恢复路径，提示 iCloud 同步及共享图库影响，然后提交给系统确认。
- 每次安装有 10 项免费额度。系统确认成功后，本地事务才会写入历史并扣减额度。重启遇到结果未知的批次时，应用提示检查系统照片并刷新。
- 重复照片、相似照片、大视频、原件大小计算、StoreKit 订阅及持久扫描索引属于后续里程碑。共享图库、iCloud 同步与恢复还需多台真机验收。
