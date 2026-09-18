# Release Checklist

## 版本与内容

- [ ] 工作区只包含计划发布的改动
- [ ] Git Tag、Release 名称、应用版本和 Changelog 一致
- [ ] `release-channels/preview` 或 `release-channels/stable` 已指向准备发布的 Git Tag
- [ ] README 中的系统、CPU 架构、签名状态和已知限制准确
- [ ] 未提交 `.workbuddy/`、本地备份、签名凭据或个人配置

## 自动检查

```bash
swift test
./scripts/package.sh
codesign --verify --deep --strict dist/AgentAim.app
cd port
cargo fmt --all --check
cargo test --workspace
```

- [ ] Swift 65 项测试通过
- [ ] Rust workspace 测试通过
- [ ] macOS 包签名结构校验通过
- [ ] Release workflow 在目标 macOS / Windows runner 上通过

## 产物检查

- [ ] 用 `file` 检查 macOS 主程序与 AgentAimHook 的实际架构
- [ ] 用 `plutil` 检查 Bundle ID、最低系统版本和版本号
- [ ] 发布包名称、SHA-256 文件名与安装器匹配
- [ ] Windows ZIP 包含主程序、Hook、示例配置、许可证和卸载入口
- [ ] Release 说明明确标注未进行 Apple / Microsoft 商业代码签名

## 实际安装

- [ ] 在没有源码和旧构建缓存的账户上下载 Release
- [ ] 手动安装路径验证完成
- [ ] Agent 安装脚本路径验证完成
- [ ] 更新旧版本时设置得到保留，失败时不会丢失旧应用
- [ ] 启动后能看到 Dock / 菜单或 Windows 托盘入口
- [ ] `Esc`、`Q`、右键、90 秒无操作和紧急退出均能恢复鼠标
- [ ] 没有出现辅助功能、输入监控或屏幕录制授权请求

## 发布后

- [ ] GitHub Release 可下载且 SHA-256 与本地复算一致
- [ ] 安装命令实际选择到本次 Release
- [ ] 新建 Issue 能看到 Bug / Feature 模板
- [ ] 更新下载页、路线图与已知问题
