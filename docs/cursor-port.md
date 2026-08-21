# The Cursor port: skills, rules, and agents in Goose + OpenCode

[PhillipChaffee/.cursor](https://github.com/PhillipChaffee/.cursor) is a mature
Cursor setup — 11 skills, 20 rules, 31 subagent prompts. This stack ports it
(issue #12): the artifacts live in this repo as the single source,
`scripts/mac/bootstrap-mac.sh` installs them no-clobber, and this document
records every porting decision so nothing was dropped silently.

## Where everything landed

| Cursor artifact | In this repo | Installed to | Read by |
|---|---|---|---|
| `skills/*/SKILL.md` (11 skills + reference libraries) | `config/skills/` | `~/.agents/skills/` | **Both**: OpenCode ("agent-compatible" global dir) and goose ≥ 1.16 (built-in skills support, enabled by default; repo pins 1.4x) |
| `rules/*.mdc` — global-worthy (9) | merged into `config/opencode/AGENTS.md` | `~/.config/opencode/AGENTS.md` | OpenCode (all sessions) |
| `rules/*.mdc` — stack-specific (8) | `config/opencode/project-rules/*.md` | not installed — per-project | Paste into a project's `AGENTS.md`, or list in the project's `opencode.json` `"instructions"` array |
| `agents/*.md` (30 of 31) | `config/opencode/agents/` | `~/.config/opencode/agents/` | OpenCode (agent name = filename; dispatched via the task tool / `@`-mention) |

Facts this layout relies on (verified against the OpenCode and goose docs and
the workspace-mcp/goose sources, 2026-08-21): OpenCode reads global skills
from `~/.agents/skills/<name>/SKILL.md` and goose discovers the same
directory, so **one install target serves both tools with zero duplication**;
OpenCode agent frontmatter recognizes `description`/`mode`/`model`/
`permission`/`temperature`/`top_p` etc. and passes **unknown keys through as
provider model options** — which is why Cursor's `name:` and `readonly:` keys
were stripped everywhere (`readonly: true` became `permission: { edit: deny }`).

## Model mapping

Cursor ran everything on its own slugs (`cursor-grok-4.6-high-fast`,
`composer-2.5-fast`, with an optional "Fable thinking" upgrade tier). Those
map onto this stack's routing (`docs/model-routing.md`) by **role**, pinned in
each agent's frontmatter:

| Role | Agents | Model |
|---|---|---|
| Fast/mechanical | `researcher-lite` | `opencode/minimax-m2.7` |
| Standard reviewers & workers | all `cr-*` reviewers, `cr-implementer`, 7 structural `pr-*` reviewers, `pr-implementer`, `researcher-mid`, `research-synthesizer`, both `refactor-*-scout`s | `opencode/kimi-k2.6` |
| Deep reasoning | `cr-planner`, `cr-verifier`, `pr-planner`, `pr-verifier`, `pr-adversarial`, `pr-architecture`, `researcher-deep`, `research-planner` | `opencode/claude-sonnet-5` |

Because models are now **pinned per agent**, the skills' old "upgrade this
reviewer to the thinking model" machinery collapsed: the escalation criteria
survive as guidance for *which agents to select* (the deep-reasoning ones),
not for switching a given agent's model mid-flight. If `model-routing.md`
changes tiers, update the agent frontmatter and the roster prose in
`research-planner.md` together.

## Decisions: rules

Merged into `config/opencode/AGENTS.md` (9): `engineering`, `minimal-changes`,
`code-organization`, `comment-style`, `look-it-up`, `plan-steps`,
`merge-requests`, `subagents` (adapted — its Cursor dispatch/model prose was
rewritten against the ported agent roster and the three-tier model mapping),
and `skill-creation` (adapted — the frontmatter constraints are identical in
the Claude-compatible skill spec both tools read; Cursor-only mechanics
removed).

Kept per-project in `config/opencode/project-rules/` (8): `python`,
`python-pytest`, `python-docstrings-google`, `python-class-sections`,
`django-migrations`, `linear-tickets` (work-specific; `ship` references it
here), `design-docs` and `writing-voice` (both opt-in in Cursor too —
`writing-voice` keeps its fill-in-template warning).

Dropped (3): `github-vs-gitlab-mcp` (Cursor MCP-server disambiguation, moot —
MCP servers are explicit in `opencode.json`), `mr-review-chat-title` (needs
Cursor's chat-UI rename tool), `autopilot` (constrains Cursor's built-in
`/autopilot` skill, which isn't vendored — its size-budget discipline was
distilled into AGENTS.md's *Keeping an MR Merge-Ready Without Ballooning the
Diff* section).

## Decisions: skills

All 11 ported to `config/skills/`. `ci-lint-test`, `code-review`'s
`checklists.md`/`examples.md`, and `refactor-planner`'s nine `references/`
files are byte-identical to source. The rest carry targeted adaptations:
Cursor dispatch (`Task`/`subagent_type`/`generalPurpose`) became OpenCode
task-tool dispatch by agent name; `.cursor/...` paths became
`~/.agents/skills/...` / AGENTS.md references; plan artifacts live at
`.agents/plans/` (workspace root) instead of `.cursor/plans/`; slash
invocations became plain skill names (skills load via the agent's `skill`
tool). Two larger calls:

- **`ship`**: the Cursor `/autopilot` handoff phase became `merge_watch` — a
  merge-readiness wrap-up that hands the MR back with a keep-it-merge-ready
  checklist (per AGENTS.md's merge-request conventions), or on explicit
  request a read-only GitLab-MCP watch that never merges.
- **`deep-research`**: the "grok default / Fable upgrade" model economy became
  the pinned three-tier roster; the "Fable never gathers evidence" guardrail
  survives as "the deep tier never does the broad sweep". Its Cursor-canvas
  output section became a plain markdown report section.

GitLab and Linear flavor was kept throughout (`mr-review`,
`pre-mr-checklist`, `ship` state their MCP dependencies up top) — the owner
uses both at work; the review/planning workflows are tool-agnostic.

## Decisions: agents

All 30 ported to `config/opencode/agents/` (11 `cr-*` + 12 `pr-*` + 2
refactor scouts + 5 research agents — the issue's "31" was a miscount),
filenames (= agent names) unchanged so every cross-reference in the skills
resolves. 8 `cr-*` and 7 `pr-*` bodies are byte-identical to source; the
adapted ones swap Cursor tool names (`StrReplace` → `edit`), Cursor read-only
phrasing (→ the `permission` mechanism), and Cursor model-routing prose
(→ the pinned tiers). Every read-only agent (all reviewers, verifiers,
planners, scouts, researchers) carries `permission: { edit: deny }`; the two
implementers write files and don't. The `subagents` rule that orchestrates
the roster lives in AGENTS.md's *Subagent Use* section.

## What was deliberately NOT done (first pass)

- **No goose recipes from the review panels.** The `cr-*`/`pr-*` flows are
  interactive coding workflows; goose `sub_recipes` (experimental) could host
  them on the brain later, but nothing life-admin needs them yet. Revisit if
  a scheduled "review yesterday's commits" automation ever earns its keep.
- **No brain install.** The brain does life admin, not code review; skills
  are discoverable there anyway if you clone this repo and copy
  `config/skills/` into `~/.agents/skills/` on the VPS.
- **`goosehints` untouched.** The hub's behavior rules stay lean
  (`config/goose/goosehints.example`); coding conventions live in AGENTS.md
  where the coding surface reads them. goose sessions in a project directory
  still pick up that project's `AGENTS.md` automatically (goose's default
  context files include `AGENTS.md`), so the conventions follow you into
  goose without a second copy.

## Verifying the port on your Mac

```bash
./scripts/mac/bootstrap-mac.sh          # installs skills/agents/AGENTS.md no-clobber

# OpenCode: agents + skills visible?
opencode                                 # then: @cr-security should autocomplete;
                                         # ask "list your available skills" (skill tool)

# goose: skills discovered?
goose skills list                        # should list the 11 ported skills
```

End-to-end smoke test (the issue's acceptance bar): in a repo with a real
diff, ask OpenCode to run the `code-review` skill — it should dispatch `cr-*`
subagents via the task tool and produce the curated summary; then
`goose skills list` proves the same SKILL.md files parse on the goose side.
