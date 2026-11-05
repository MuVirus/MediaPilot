---
name: writing-skills
description: Create, review, or update agent skills and keep the English and Chinese versions in sync
---

# Writing skills

Use this skill when adding a skill under `.agents/skills/`, editing an
existing `SKILL.md`, or reviewing whether a skill is worth keeping.

## Hard rules

1. `SKILL.md` is always written in English.
2. Chinese is optional: add `SKILL_ZH.md` beside it as a strict translation.
3. If `SKILL_ZH.md` exists, both files change in the same commit. Never update
   one alone.
4. The directory name is the skill ID: lowercase kebab-case, 1–64 characters.
5. `name` must equal the directory name. `description` is one English sentence
   that starts with a verb and names the trigger.
6. A skill owns one repeatable task. Project-wide rules belong in `AGENTS.md`,
   not here.
7. Keep `SKILL.md` under about 150 lines. Put long material in `references/`.

## Structure

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

## Writing rules

- Start with the trigger. If the description does not tell the model when to
  load the skill, the skill will not be used.
- Write steps as actions, not topics: "run X", "read Y", "add Z".
- Name real paths, commands, and file names.
- Prefer a checklist over prose for anything verifiable.
- State anti-patterns explicitly. Agents follow prohibitions well.
- Do not repeat `AGENTS.md`. Link to it instead.
- Do not include secrets, tokens, or machine-specific absolute paths.

## Translation rules

`SKILL_ZH.md` is a strict translation, not a summary.

- Keep the same heading order and hierarchy.
- Keep the same number of sections, steps, and checklist items.
- Translate prose. Do not translate identifiers, commands, paths, event names,
  capability IDs, error codes, or code.
- Keep code blocks byte-identical, including comments.
- Do not add examples, caveats, or explanations in the Chinese file.
- The frontmatter `name` stays identical; translate only `description`.
- Add this line under the title: `> 严格中文翻译，与 SKILL.md 同步更新。`

## Sync check

Before finishing, confirm both files changed together:

```sh
git diff --stat -- .agents/skills/<id>
```

The English and Chinese files must appear in the same change. If only one
appears, stop and fix it.

## Review checklist

- [ ] Directory name is kebab-case and equals `name`.
- [ ] `description` names both the action and the trigger.
- [ ] Every step can be executed without asking a follow-up question.
- [ ] No project-wide rules that belong in `AGENTS.md`.
- [ ] `SKILL.md` is English only.
- [ ] `SKILL_ZH.md` exists or is intentionally omitted.
- [ ] Both language files have identical structure and code blocks.
- [ ] No secrets or machine-specific paths.

## Do not

- Create a skill for a one-off task.
- Copy architecture docs into a skill.
- Use vague instructions such as "be careful" or "follow best practices".
- Mix multiple unrelated workflows in one skill.
- Let the Chinese file drift into a summary.
