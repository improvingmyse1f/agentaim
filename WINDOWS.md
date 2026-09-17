# AgentAim for Windows

支持 Windows 10 22H2 与 Windows 11 x64。Windows 外壳使用原生 Win32、GDI 和 Raw Input，
不需要管理员权限，也不需要辅助功能、屏幕录制或输入监控权限。

## 安装

在 PowerShell 中运行：

```powershell
irm https://raw.githubusercontent.com/improvingmyse1f/agentaim/main/scripts/install-windows.ps1 | iex
```

安装器下载 GitHub Release 中的 x64 压缩包并校验 SHA-256，默认安装到
`%LOCALAPPDATA%\AgentAim`，创建开始菜单快捷方式并启动应用。

当前预览版尚未进行 Authenticode 代码签名，Windows 可能显示 SmartScreen 提示。
请只从本仓库的 Releases 下载，并核对发布页中的 SHA-256。

## 使用

- 双击启动后，底部中央会出现一个 56px 确认圆环，10 秒后自动消失。
- 主动训练：通知区域右键 AgentAim → **Start training**。
- 退出本局：`Esc`、`Q` 或鼠标右键；90 秒无鼠标移动和开火也会自动收局。
- 设置：通知区域右键 AgentAim → **Settings…**，可选择 VALORANT / CS2、画面比例、
  游戏内灵敏度和可选 DPI。
- 紧急退出：任务管理器结束 `AgentAim.exe`，或在 PowerShell 执行
  `Stop-Process -Name AgentAim -Force`。进程退出后 Windows 会自动解除光标裁剪。

## Agent 状态联动

发布包内含 `AgentAimHook.exe` 和三份 `windows-*.json` 示例。把对应示例中的 hooks
合并进 Codex、Claude Code 或 WorkBuddy 的现有配置，**不要整份覆盖原配置**。
应用必须已经运行，hook 才会把经过白名单过滤的生命周期事件发给它。

开启 Settings 中的 **Start when an agent works** 后，新一轮 Agent 工作只会亮起确认圆环；
鼠标停留 2 秒才会接管屏幕。Agent 等待确认、回复、失败或中断时会自动收局。

## 从源码构建

```powershell
cd port
cargo test --workspace
cargo build --release -p agentaim-windows
cd ..
.\scripts\package-windows.ps1 -Version 0.1.0
```

输出位于 `dist/AgentAim-Windows-x64-<version>.zip`。
