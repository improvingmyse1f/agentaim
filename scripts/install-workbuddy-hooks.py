#!/usr/bin/env python3
"""把 AgentAim 的 hooks 装进 WorkBuddy（= CodeBuddy Code）自己的配置里。

设计约束（用户 2026-09-14 明确要求「不要影响其它应用的 hook」）：
  1. **只写一个文件**：`~/.workbuddy/settings.json`。Claude Code 的
     `~/.claude/settings.json`、Codex 的 `~/.codex/{config.toml,hooks.json}`、
     插件自带的 `hooks/hooks.json` 一律不碰。
  2. **只增不减**：既有的顶层键与既有 hook 条目原样保留；同一事件下我们的条目是
     *追加*，不是替换。已经装过就不再装（按命令字符串判重，幂等）。
  3. **只删自己的**：`--remove` 只摘掉 command 里同时含 AgentAimHook 与
     `--provider workbuddy` 的条目，别人的 hook 一条不动。
  4. 写入前把原文件备份到 `<repo>/.workbuddy/backup/`，权限保持 0600。

用法：
    scripts/install-workbuddy-hooks.py --dry-run     # 只看会改什么
    scripts/install-workbuddy-hooks.py              # 安装
    scripts/install-workbuddy-hooks.py --remove     # 卸载（只摘自己的）
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BINARY = os.path.join(REPO, "dist", "AgentAim.app", "Contents", "MacOS", "AgentAimHook")
BACKUP_DIR = os.path.join(REPO, ".workbuddy", "backup")
SETTINGS = os.path.join(os.path.expanduser("~"), ".workbuddy", "settings.json")
PROVIDER = "workbuddy"
MARKERS = ("AgentAimHook", f"--provider {PROVIDER}")

# WorkBuddy 支持的事件集。**故意不写** Claude Code 那些它没有的事件
# （PermissionRequest / Elicitation / ElicitationResult / PostToolUseFailure /
# StopFailure）—— 写了会被当未知事件跳过，只会刷 warning。
EVENTS_WITHOUT_MATCHER = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]
NOTIFICATION_MATCHER = "permission_prompt|idle_prompt"


def entry(command: str) -> dict:
    return {"hooks": [{"type": "command", "command": command, "timeout": 1}]}


def our_entries(binary: str) -> dict:
    command = f'"{binary}" --provider {PROVIDER}'
    plan = {name: [entry(command)] for name in EVENTS_WITHOUT_MATCHER}
    # waiting 信号在 WorkBuddy 上只剩这一条路，必须带上 matcher。
    plan["Notification"] = [{"matcher": NOTIFICATION_MATCHER, "hooks": entry(command)["hooks"]}]
    return plan


def is_ours(group: dict) -> bool:
    """判断一个 matcher 组是否属于 AgentAim（要求两个标记都命中，避免误伤）。"""
    haystack = json.dumps(group, ensure_ascii=False)
    return all(marker in haystack for marker in MARKERS)


def load() -> dict:
    if not os.path.exists(SETTINGS):
        return {}
    with open(SETTINGS, encoding="utf-8") as handle:
        return json.load(handle)


def backup() -> str:
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    target = os.path.join(BACKUP_DIR, f"workbuddy-settings-{stamp}.json")
    shutil.copy2(SETTINGS, target)
    return target


def install(settings: dict, binary: str) -> list[str]:
    hooks = settings.setdefault("hooks", {})
    changes = []
    for event, groups in our_entries(binary).items():
        existing = hooks.setdefault(event, [])
        for group in groups:
            if any(json.dumps(g, sort_keys=True) == json.dumps(group, sort_keys=True) for g in existing):
                changes.append(f"  = {event} 已存在，跳过")
                continue
            existing.append(group)
            changes.append(f"  + {event} 追加 1 条")
    return changes


def remove(settings: dict) -> list[str]:
    hooks = settings.get("hooks", {})
    changes = []
    for event in list(hooks.keys()):
        kept = [g for g in hooks[event] if not is_ours(g)]
        dropped = len(hooks[event]) - len(kept)
        if dropped:
            changes.append(f"  - {event} 摘掉 {dropped} 条（其余保留）")
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if "hooks" in settings and not settings["hooks"]:
        del settings["hooks"]
    return changes


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", default=DEFAULT_BINARY, help="AgentAimHook 的绝对路径")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--remove", action="store_true", help="卸载 AgentAim 的条目")
    args = parser.parse_args()

    if not args.remove and not os.path.exists(args.binary):
        print(f"找不到转发器：{args.binary}\n先跑 ./scripts/package.sh", file=sys.stderr)
        return 1

    settings = load()
    before_keys = sorted(settings.keys())
    changes = remove(settings) if args.remove else install(settings, args.binary)

    if not changes:
        print("没有需要变更的内容。")
        return 0

    print(f"目标文件：{SETTINGS}")
    print("改动：")
    print("\n".join(changes))
    print(f"顶层键：{before_keys} -> {sorted(settings.keys())}（除 hooks 外均未改动）")

    if args.dry_run:
        print("\n--dry-run：未写入。")
        return 0

    saved = backup()
    payload = json.dumps(settings, ensure_ascii=False, indent=2) + "\n"
    descriptor = os.open(SETTINGS, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(payload)
    print(f"\n已写入（备份：{saved}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
