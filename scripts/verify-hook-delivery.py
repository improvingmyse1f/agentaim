#!/usr/bin/env python3
"""验收 AgentAimHook 是否真的把 hook 事件投递出去了。

为什么需要它：转发器以「失败静默、exit 0」为设计目标，所以只看退出码
永远无法区分「投递成功」和「根本没投递」。唯一可靠的判据是：**在 socket 上真收到数据报**。
（2026-09-14：正因为缺这一步，stdin 的 EOF bug 让转发器一次都没成功过，却看起来一切正常。）

用法：
    scripts/verify-hook-delivery.py                    # 校验 workbuddy + claude + codex 三条
    scripts/verify-hook-delivery.py --provider claude  # 只校验一条
退出码非 0 表示有 provider 没投递成功。
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(REPO, "dist", "AgentAim.app", "Contents", "MacOS", "AgentAimHook")
RUNTIME_DIR = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "AgentAim")

# 每个 provider 用一条真实 payload 形状的事件。
CASES = {
    "workbuddy": {"session_id": "verify-workbuddy", "hook_event_name": "UserPromptSubmit"},
    "claude": {"session_id": "verify-claude", "hook_event_name": "Stop"},
    "codex": {"session_id": "verify-codex", "hook_event_name": "PreToolUse", "tool_name": "Bash"},
}
# 不允许出现在线上协议里的字段：转发器必须先把它们脱掉。
FORBIDDEN = ("cwd", "transcript_path", "prompt", "tool_input", "tool_response", "message")


def verify(provider: str, timeout: float = 5.0) -> bool:
    os.makedirs(RUNTIME_DIR, exist_ok=True)
    path = os.path.join(RUNTIME_DIR, f"verify-{provider}.sock")
    if os.path.exists(path):
        os.unlink(path)

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    listener.bind(path)
    listener.settimeout(timeout)
    try:
        payload = json.dumps(CASES[provider]).encode()
        result = subprocess.run(
            [BINARY, "--provider", provider, "--socket", path],
            input=payload,
            capture_output=True,
            timeout=timeout + 5,
        )
        if result.returncode != 0 or result.stdout or result.stderr:
            print(f"  ✗ 退出码 {result.returncode}，stdout/stderr 应为空：{result.stdout[:80]}{result.stderr[:80]}")
            return False
        data, _ = listener.recvfrom(8_192)
    except socket.timeout:
        print("  ✗ 没收到数据报 —— hook 没有投递出去（这才是真正的失败）")
        return False
    finally:
        listener.close()
        if os.path.exists(path):
            os.unlink(path)

    try:
        event = json.loads(data)
    except json.JSONDecodeError:
        print(f"  ✗ 收到的东西不是 JSON：{data[:120]!r}")
        return False

    if event.get("provider") != provider:
        print(f"  ✗ provider 不匹配：期望 {provider}，收到 {event.get('provider')}")
        return False
    if event.get("hook_event_name") != CASES[provider]["hook_event_name"]:
        print("  ✗ hook_event_name 不匹配")
        return False
    leaked = [key for key in FORBIDDEN if key in event]
    if leaked:
        print(f"  ✗ 私密字段漏进协议了：{leaked}")
        return False

    print(f"  ✓ 投递成功，字段 {sorted(event)}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", choices=sorted(CASES), action="append")
    args = parser.parse_args()

    if not os.path.exists(BINARY):
        print(f"找不到转发器：{BINARY}\n先跑 ./scripts/package.sh", file=sys.stderr)
        return 1

    failed = []
    for provider in args.provider or sorted(CASES):
        print(f"[{provider}]")
        if not verify(provider):
            failed.append(provider)

    print()
    if failed:
        print(f"未通过：{', '.join(failed)}")
        return 1
    print("全部通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
