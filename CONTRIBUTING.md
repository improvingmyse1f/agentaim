# Contributing to AgentAim

感谢你愿意改进 AgentAim。提交改动前，请先确认问题范围清楚，并尽量保持一次 Pull Request
只解决一件事。

## 开发环境

- macOS 13+、Swift 6：macOS 应用与 Swift 核心
- Rust stable：可移植核心与 Windows 外壳
- Windows 10 22H2 / Windows 11 x64：Windows 交互与打包验收

## 本地检查

Swift：

```bash
swift test
./scripts/package.sh
codesign --verify --deep --strict dist/AgentAim.app
```

Rust：

```bash
cd port
cargo fmt --all --check
cargo test --workspace
```

受限环境如果无法创建 Unix socket，Swift 的 `UnixDatagramTests` 可能返回 `posix(1)`；这属于
执行环境限制，必须在允许本地 socket 的真实环境重新运行，不能据此修改业务逻辑或跳过测试。

## 跨端玩法合同

`fixtures/gameplay-v1.json` 是 macOS 与 Windows 共享的玩法合同。修改靶子出生、命中判定、
计分或随机数消耗顺序后，必须重新生成并同时验证两端：

```bash
AGENTAIM_WRITE_FIXTURES=1 swift test --filter writesFrozenVectors
swift test
cd port && cargo test --workspace
```

Pull Request 需要明确写出“玩法合同已更新，Windows 侧需要同步验证”。

## UI 与输入改动

- 不要只用截图证明窗口层级、点击穿透或圆环生命周期正确。
- 必须验证 `Esc`、`Q`、右键和 90 秒无操作都能恢复鼠标。
- 不要为悬停检测新增辅助功能、输入监控或屏幕录制权限。
- 自动训练与登录启动必须继续默认关闭。

## Pull Request 内容

- 说明用户遇到的问题和预期结果。
- 列出实际运行过的测试与平台。
- 对尚未验证的 macOS/Windows 行为明确标注边界。
- 不提交 `.workbuddy/`、个人配置、构建缓存或签名凭据。

安全问题不要公开提交，处理方式见 [SECURITY.md](SECURITY.md)。
