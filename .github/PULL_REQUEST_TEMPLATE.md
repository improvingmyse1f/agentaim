## 解决的问题

<!-- 描述用户遇到的问题，以及为什么需要这次改动。 -->

## 改动内容

<!-- 保持范围具体；一次 PR 尽量只解决一件事。 -->

## 验证

- [ ] `swift test`
- [ ] `./scripts/package.sh`
- [ ] `codesign --verify --deep --strict dist/AgentAim.app`
- [ ] `cd port && cargo fmt --all --check && cargo test --workspace`
- [ ] 涉及 UI/输入时，已验证 `Esc`、`Q`、右键和超时恢复鼠标
- [ ] 涉及玩法时，已更新并验证 `fixtures/gameplay-v1.json`

## 平台边界

<!-- 列出实际验证过的 macOS / Windows 版本，以及仍未验证的部分。 -->

## 隐私检查

- [ ] 未提交 `.workbuddy/`、个人配置、凭据、prompt、transcript 或本地备份
