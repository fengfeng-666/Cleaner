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

## 截屏清理验收

在 Xcode 中选择 iPhone 模拟器，按 `⌘U` 运行 `CleanerTests`。也可以指定模拟器 UDID 运行同一套测试：

```sh
xcodebuild -project Cleaner.xcodeproj -scheme Cleaner \
  -destination "platform=iOS Simulator,id=$CLEANER_SIMULATOR_UDID" \
  -derivedDataPath DerivedData -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
```

自动化测试使用模拟图库和临时 SQLite 数据库，覆盖取消、成功结算、重复结算、写入失败后的回滚与重试、重启恢复、结果未知，以及授权或资产变化后的旧复核失效。

| 系统验收项 | 通过标准 |
| --- | --- |
| 系统确认取消 | 选择两张测试截屏，在 Photos 确认框取消。截屏与选择均保留，历史为空，剩余 10 项，可重新提交。 |
| 系统确认成功 | 使用初始额度为 10 的测试安装，确认清理两张截屏。在「最近删除」找到这两张截屏，Cleaner 显示一条 2 项记录及剩余 8 项。重启并刷新后结果一致。 |
| 确认前中断 | 系统确认框打开时终止 Cleaner，重启后按需取消遗留的系统确认框。Cleaner 显示待核对提示，核对前禁止新清理，历史与额度保持原值。 |
| 有限授权与资产变化 | 授权部分测试截屏后扫描，只显示获准访问的截屏。复核时撤回访问权限或更改已选资产，旧复核失效，重新提交前必须检查更新后的选择。 |
| 真机与多语言 | 在 iOS 17 和较新系统上核对系统确认流程。使用两台真机检查 iCloud 同步、共享图库及从「最近删除」恢复。逐一检查五种语言的授权文案、复核数量和错误提示。 |

## 语言

支持英语、西班牙语、德语、法语和简体中文。Cleaner 读取 iOS 的语言偏好，英语是默认回退语言。可在 iOS 的 Cleaner 应用设置中选择首选语言，或在 Xcode 的 **Edit Scheme → Run → Options** 中分别设置 **App Language** 和 **App Region** 来验证语言和地区格式。

界面、错误提示和数量单复数使用 `App/Localizable.xcstrings`，系统照片授权弹窗里的用途说明使用 `App/InfoPlist.xcstrings`。

## MVVM 架构

- `App/Models` 定义截屏元数据、清理记录和额度。
- `App/ViewModels` 使用 Swift Observation 管理扫描、筛选、选择、清理以及图片加载状态。
- `App/Views` 用 SwiftUI 呈现状态并转发用户操作。
- `App/Services` 封装 PhotoKit 授权、查询、图片请求、删除和 SQLite 持久化。`App/CleanerApp.swift` 负责组装清理流程用到的服务。

## 当前范围

- 示例无需照片授权。实际扫描支持完整和有限授权，截屏按月展示，可按 30 天筛选。
- 先预览，再逐项选择。复核显示选择数量、收藏项和恢复路径，提示 iCloud 同步及共享图库影响，然后提交给系统确认。
- 每次安装有 10 项免费额度。系统确认成功后，本地事务才会写入历史并扣减额度。重启遇到结果未知的批次时，应用提示检查系统照片并刷新。
- 重复照片、相似照片、大视频、原件大小计算、StoreKit 订阅及持久扫描索引属于后续里程碑。共享图库、iCloud 同步与恢复还需多台真机验收。
