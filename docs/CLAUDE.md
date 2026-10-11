# `docs/` — agent guide

Reference and runbooks for this repo. Area rules live in each area's own
`CLAUDE.md`; this file governs `docs/` itself. It follows the insolvia repo's
[`docs/CLAUDE.md`](https://github.com/insolvia-ai/insolvia/blob/main/docs/CLAUDE.md),
minus the kinds this repo does not keep.

## Two kinds here, and two that live in insolvia

File a new document by **how it will be read**, not what it is about.

| Where | Kind | The test |
|---|---|---|
| `reference/` | How something works, durably | You will reread it in a year; it changes only when the system does. |
| `runbooks/` | A procedure a human executes | It has steps, an order, and a "done". |
| insolvia's [`docs/adr/`](https://github.com/insolvia-ai/insolvia/tree/main/docs/adr) | A decision and its reasoning | Someone will otherwise re-litigate it. **ADRs stay in insolvia**, including ones about this repo ([0025](https://github.com/insolvia-ai/insolvia/blob/main/docs/adr/0025-shared-infra-and-mailer-move-to-insolvia-services.md) is the split itself): one numbered sequence, not two. |
| insolvia's `docs/plan.md` | The single living plan | There is exactly one, and it is not here. |

## What does *not* belong in `docs/`

**One fact, one owner:**

- **A procedure an agent must not improvise → a skill** (`.claude/skills/`).
  Deploy rules, credential export, ruleset edits and deploy-role changes are
  skills for that reason. **A doc must not restate a skill's body — name the
  skill and stop.**
- **Rules for changing one area → that area's `CLAUDE.md`.** `docs/`
  describes how the system *works*; a `CLAUDE.md` constrains how you *edit*
  it.
- **Anything about the app, its API or its stacks → the insolvia repo.**
  Link to it with an absolute
  `https://github.com/insolvia-ai/insolvia/blob/main/<path>` URL; never copy
  it here. A relative link that climbs out of this repo resolves nowhere on
  GitHub.

## Conventions

- `lowercase-kebab-case.md`.
- **Link, never restate.** When two documents need the same fact, one owns it
  and the other links — across the doc/skill line and across the two repos.
- Keep a document current when you change the thing it describes. A runbook
  that has been executed says so at the top rather than being deleted.
- Update [`README.md`](README.md)'s table when you add or move a document.
