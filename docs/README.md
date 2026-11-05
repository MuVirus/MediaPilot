# MediaPilot 文档

MediaPilot 是一个 MoonBit 原生实时音视频网关，当前聚焦实时音频。文档只回答四类问题，每类一个入口：

| 你想知道 | 读这里 |
| --- | --- |
| 外部客户端可以依赖什么？ | [contract.md](contract.md) |
| 系统怎么分层、依赖往哪走？ | [architecture.md](architecture.md) |
| 现在做到哪、下一步是什么？ | [roadmap.md](roadmap.md) |
| 某个 provider 的 wire 行为是什么？ | [providers/](providers/) |
| 为什么做了某个选择？ | [decisions/](decisions/) |

## 写作规则

1. **只写当前行为。** 计划写在 `roadmap.md`，不要写成现在时。
2. **承诺必须可验证。** `contract.md` 里的每条承诺都要有 `Locked by` 指向一个测试；P0 阶段允许写 `pending: P1`。
3. **一页一个问题。** 能改现有页面就不要新建。
4. **中文优先。** 有真实外部用户后再加英文镜像，不为了“双语”而双语。
5. **暂不建站点。** 文档超过约 20 页，或出现版本化、i18n、对外发布需求时，再引入 VitePress。

## 维护时机

- 行为变了 → 同一次改动里更新 `contract.md` 和对应测试。
- 协议变了 → 同时改 MoonBit 类型、客户端类型、`contract.md`，并升版本。
- 做了架构取舍 → 在 `decisions/` 加一篇 ADR，编号递增。
- 阶段完成 → 更新 `roadmap.md` 的退出条件，不要只改状态词。
