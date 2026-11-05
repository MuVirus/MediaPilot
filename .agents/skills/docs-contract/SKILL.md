---
name: docs-contract
description: Write or update MediaPilot documentation, especially promises in docs/contract.md and their locking tests
---

# Docs and contract

Use this when writing docs, changing promised behavior, or reviewing whether a
doc matches the code.

## Pick the right page

| Content | Where |
| --- | --- |
| External promises | `docs/contract.md` |
| Layers, ownership, data flow | `docs/architecture.md` |
| Phase plan, exit criteria | `docs/roadmap.md` |
| A choice with trade-offs | `docs/decisions/NNNN-*.md` |
| How to do a repeated task | `.agents/skills/<id>/SKILL.md` |
| Project rules for agents | `AGENTS.md` |

Do not create a new page for a paragraph that belongs in one of these.

## Writing a contract promise

1. State behavior in the present tense, from the client's point of view.
2. Name the exact endpoint, event, field, or error code.
3. Add a row to the capability table or the relevant table.
4. Fill `Locked by` with a real test path.
5. If no test exists yet, write `pending: <phase>` and do not describe the
   behavior as stable anywhere else.
6. Add the test in the same change if the code exists.

A promise without a test is a bug in the doc.

## Style

- One claim per sentence. Avoid "should", "will", "maybe".
- Define a term the first time it appears; do not rely on the reference
  project's vocabulary.
- Prefer a table for enumerations (events, codes, capabilities).
- Include one concrete JSON example for each message family, not for every
  field.
- Keep Chinese docs Chinese. Code identifiers, event names, and error codes
  stay in English.
- No screenshots of text. No generated API dumps.

## Review checklist

- [ ] Every "must" maps to code or a test.
- [ ] No roadmap language in `contract.md`.
- [ ] No provider names or raw provider fields in the contract.
- [ ] Links resolve; anchors match headings.
- [ ] `docs/README.md` still points to the right entry pages.
- [ ] If behavior changed, the contract changed in the same commit.
- [ ] If a capability was added, `GET /api/health` and the table agree.

## When to add a docs site

Do not. Until `docs/` exceeds roughly 20 pages, or versioned/i18n publishing is
a real requirement, Markdown plus contract tests is cheaper and harder to
drift. Revisit only with a concrete external audience.
