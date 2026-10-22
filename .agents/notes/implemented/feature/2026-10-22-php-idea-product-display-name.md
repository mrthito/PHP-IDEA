# Agent 笔记：产品显示名为 PHP Idea

状态：已实现

## 先说结论

用户看到的产品名是 PHP Idea。内部标识、可执行文件、安装包目录、Sparkle 归档条目和 Application Support 仍使用 Lithe。不要为了改显示名去改 bundle identifier 或把 `Lithe.app` 改成 `PHP Idea.app`，否则增量更新和已有用户数据会对不上。

## 问题

这个仓库面向 PHP 开发，欢迎页、Dock、窗口标题仍显示 Lithe，容易让人以为产品名还是上游工程名。如果同时改掉 `CFBundleName`、可执行文件名和 `.app` 目录名，Sparkle 会按归档里的 `Lithe.app` 与 `CFBundleName.app` 对齐，现有用户的更新基线和 Application Support 也会断开。

## 决策

显示名只写在一处，再给各平台引用：

- macOS：`ProductIdentity.displayName`（`macos/Sources/LitheModuleAPI/ProductIdentity.swift`）
- Windows：`PRODUCT_DISPLAY_NAME`（`windows/tauri/src/platform/product-identity.ts`）

`Info.plist` 的 `CFBundleDisplayName` 和 Tauri 的 `productName` 使用这个显示名。`CFBundleName`、`CFBundleExecutable`、`app.lithe.desktop` / `app.lithe.windows`、正式包里的 `Lithe.app`、Application Support 目录名保持 Lithe。配色主题与快捷键方案里的 “Lithe” 是方案名，不是产品名，不要改。

Dock 悬停名默认取 `.app` 文件名。本机预览不装进“应用程序”，所以 `scripts/preview.sh` 把实例打成 `PHP Idea.app`。正式包仍是 `Lithe.app`，靠 `LSHasLocalizedDisplayName` 和各语言的 `InfoPlist.strings` 让 Finder/Dock 显示 PHP Idea。AutoBuild 在拷贝本地化之后把这两处改回 `Lithe-Dev`。

### 正确做法

- 欢迎页、窗口回退标题、About/Dock 显示名、插件发行方显示名读取上述常量。
- 新增用户可见文案需要产品名时引用常量，不要再写死 `"Lithe"`。
- 预览包名从 `CFBundleDisplayName` 读取；不要再写死 `Lithe.app`。

### 不要这样做

- 不要把 `Lithe.app` 重命名为 `PHP Idea.app`，也不要把 `CFBundleName` 改成 PHP Idea。`scripts/verify-sparkle-baseline.sh` 要求归档路径与 `CFBundleName.app` 一致。
- 不要改 Application Support 下的 `Lithe` 目录，否则本机设置和缓存会变成另一份空数据。

## 考虑过的备选方案

### 连同 Lithe.app 和 CFBundleName 一起改

显示名和安装包会完全一致，但 Sparkle 基线、预览目录、发布校验和已安装用户的更新链都要重做，不适合只改产品名。

### 只改 README

文档标题变了，运行中的欢迎页和 Dock 仍是 Lithe，用户看到的产品名没有变。

## 后果

- 收益：欢迎页、窗口和系统显示名与仓库定位一致。
- 代价：设置页、更新提示等长文案里仍可能出现 Lithe；那些句子不是产品标题。
- 需要重新评估：若正式发布不再兼容现有 Sparkle 基线，再考虑改 `CFBundleName` 与 `.app` 目录名。

## 验证

- `node scripts/generate-platform-feature-matrix.mjs`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`
- 打开欢迎页，确认侧栏标题和窗口标题为 PHP Idea；Dock 悬停为 PHP Idea，菜单栏应用菜单为 PHP Idea。旧的 `Lithe.app` 预览实例要从 Dock 移除后再启动新预览。

## 适用范围

- `macos/Sources/LitheModuleAPI/ProductIdentity.swift`
- `macos/Resources/Info.plist`
- `macos/Resources/en.lproj/InfoPlist.strings`
- `macos/Resources/zh-Hans.lproj/InfoPlist.strings`
- `scripts/preview.sh`
- `macos/Sources/Lithe/Views/App/WelcomeView.swift`
- `macos/Sources/Lithe/Views/App/RootView.swift`
- `windows/tauri/src/platform/product-identity.ts`
- `windows/tauri/src-tauri/tauri.conf.json`
