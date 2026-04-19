# MacPolish

[EN](./README.en.md)

MacPolish 是一个原生 macOS 清洁工具，用于在擦拭 MacBook 时同时保护屏幕和键盘输入。它将“擦屏幕”和“擦键盘”整合到一个应用里，支持整机清洁、仅屏幕清洁和仅键盘清洁三种模式。

## 功能特性

- 原生 macOS `SwiftUI + AppKit` 应用
- `Whole Mac`、`Screen Only`、`Keyboard Only` 三种清洁模式
- `Whole Mac` 模式下黑屏并拦截本地键盘输入
- `Screen Only` 模式下只黑屏，键盘保持可用
- `Keyboard Only` 模式下保持屏幕可见并全局禁键，依赖 Input Monitoring 权限
- 根据 macOS 首选语言列表自动切换界面语言
- 已支持英文、简体中文、繁体中文、日文、韩文、法文、德文、西班牙文、意大利文、巴西葡萄牙文
- 内置 `.app`、`.pkg`、`.dmg`、`.zip` 打包脚本

## 开发

```bash
swift build
swift run MacPolishVerification
swift run MacPolish
```

## 打包

```bash
./scripts/package_release.sh
```

生成的产物会输出到 `dist/` 目录。
