# AgentAim Windows 安装说明（给安装 Agent 用）

## 安装

优先运行仓库中的签名可读脚本，不要临时拼接下载命令：

```powershell
.\scripts\install-windows.ps1
```

默认安装到 `%LOCALAPPDATA%\AgentAim`，无需管理员权限。安装器会下载 GitHub Release、
校验 SHA-256、创建开始菜单快捷方式并启动应用。当前预览包没有 Authenticode 签名，
SmartScreen 提示并不等于校验失败；仍需确认下载源是本仓库且 SHA-256 校验已通过。

## 必须告诉用户

- AgentAim 在 Windows 通知区域常驻；右键图标 → **Start training** 开始。
- 对局中按 `Esc`、`Q` 或鼠标右键立即退出并释放鼠标。
- 90 秒没有开火也没有移动鼠标会自动退出。
- 万一界面异常，在任务管理器结束 `AgentAim.exe`，或执行
  `Stop-Process -Name AgentAim -Force`；Windows 会在进程退出时解除光标裁剪。
- 设置入口为通知区域右键图标 → **Settings…**。
- “Start when an agent works”和“Launch at sign-in”默认均关闭。
- 自动触发只显示底部圆环，鼠标停留 2 秒后才进入训练。

## Hooks

安装目录包含 `AgentAimHook.exe` 与 `windows-*.json` 示例。只把对应 hooks 合并进用户
现有配置，禁止整份覆盖。`AgentAimHook.exe` 只允许固定字段并通过 `WM_COPYDATA` 发送给
同一桌面会话内已运行的 AgentAim；主应用未运行时静默退出。

## 卸载

```powershell
.\scripts\uninstall-windows.ps1
```

卸载会删除程序、开始菜单和登录启动项，但保留 `%APPDATA%\AgentAim\settings.json`。
