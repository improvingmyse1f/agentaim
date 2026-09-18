# Changelog

本项目遵循语义化版本表达功能变化。公开预览版可能仍包含兼容性调整。

## Unreleased

- 重构仓库首页，补充英文 README、贡献指南、安全策略、路线图和 Issue 模板。
- 明确 macOS Release 当前仅支持 Apple Silicon，且双平台发布包均未商业签名。
- 更新 macOS 普通用户与 Agent 安装说明，使用新版 Gatekeeper 放行路径。
- macOS 安装更新增加产物结构与签名校验，并在替换或启动请求失败时恢复旧版本。
- Release 打包根据 Git Tag 写入应用版本，带后缀的 Tag 自动发布为预览版。
- macOS 与 Windows 安装器改用版本频道文件和 Release 直链，避免匿名 GitHub API 限流。

## 0.1.0-preview.1

- 发布原生 macOS AgentAim 应用与 Windows x64 预览外壳。
- 支持 VALORANT / CS2 灵敏度配置、可选 DPI 和 `cm/360` 显示。
- 支持菜单直接训练、自动触发确认圆环、90 秒无操作退出和鼠标恢复。
- 提供 Codex、Claude Code、WorkBuddy hooks 模板与本地隐私过滤。
- 引入 macOS / Windows 共享玩法向量和自动 Release 流水线。
