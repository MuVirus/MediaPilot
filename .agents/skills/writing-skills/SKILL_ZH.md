---
name: writing-skills
description: 创建、审查或更新 agent skill，并保持中英文版本同步
---

# 编写 Skill

> 严格中文翻译，与 SKILL.md 同步更新。

在 `.agents/skills/` 下新增 skill、修改现有 `SKILL.md`，或判断一个 skill 是否值得保留时，使用本 skill。

## 硬性规则

1. `SKILL.md` 一律用英文编写。
2. 中文是可选项：在旁边添加 `SKILL_ZH.md` 作为严格翻译。
3. 如果存在 `SKILL_ZH.md`，两个文件必须在同一次提交中修改。绝不能只改其中一个。
4. 目录名就是 skill ID：小写 kebab-case，1–64 个字符。
5. `name` 必须等于目录名。`description` 是一句英文，以动词开头，并说明触发场景。
6. 一个 skill 只负责一件可重复执行的事。项目级规则应放在 `AGENTS.md`，不要放这里。
7. `SKILL.md` 控制在约 150 行以内。长内容放到 `references/`。

## 结构

```markdown
---
name: <directory-id>
description: <one sentence: what it does and when to use it>
---

# <Title>

<One paragraph: the job this skill does.>

## When to use

- <trigger>
- <trigger>

## Workflow

1. <step>
2. <step>

## Checklist

- [ ] <verifiable check>

## Do not

- <anti-pattern>
```

## 写作规则

- 从触发场景写起。如果 `description` 没有告诉模型什么时候加载，这个 skill 就不会被用到。
- 步骤要写成动作，而不是主题：“运行 X”“阅读 Y”“添加 Z”。
- 写出真实的路径、命令和文件名。
- 任何可验证的内容，优先用清单而不是散文。
- 明确写出反模式。Agent 对禁止性规则执行得很好。
- 不要重复 `AGENTS.md` 的内容，改为链接过去。
- 不要包含密钥、令牌或与机器相关的绝对路径。

## 翻译规则

`SKILL_ZH.md` 是严格翻译，不是摘要。

- 保持相同的标题顺序和层级。
- 保持相同的章节、步骤和清单条目数量。
- 翻译散文。不要翻译标识符、命令、路径、事件名、能力 ID、错误码或代码。
- 代码块保持逐字节一致，包括注释。
- 中文文件中不要增加例子、注意事项或额外解释。
- frontmatter 的 `name` 保持不变，只翻译 `description`。
- 在标题下添加这一行：`> 严格中文翻译，与 SKILL.md 同步更新。`

## 同步检查

完成前，确认两个文件是一起修改的：

```sh
git diff --stat -- .agents/skills/<id>
```

英文文件和中文文件必须出现在同一次改动中。如果只出现一个，停下来修正。

## 审查清单

- [ ] 目录名是 kebab-case，且等于 `name`。
- [ ] `description` 同时说明了动作和触发场景。
- [ ] 每一步都能直接执行，不需要再追问。
- [ ] 没有本应放在 `AGENTS.md` 的项目级规则。
- [ ] `SKILL.md` 只有英文。
- [ ] `SKILL_ZH.md` 存在，或已明确决定不添加。
- [ ] 两个语言文件的结构和代码块完全一致。
- [ ] 没有密钥或与机器相关的路径。

## 不要

- 为一次性任务创建 skill。
- 把架构文档抄进 skill。
- 使用“小心一点”“遵循最佳实践”这类模糊指令。
- 在一个 skill 里混入多个不相关的工作流。
- 让中文文件退化成摘要。
