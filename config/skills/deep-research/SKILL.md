---
name: deep-research
description: >-
  Tiered research and planning workflow that first estimates a task's complexity,
  then runs the matching effort level: a direct answer for trivial asks, a few
  parallel researchers for standard ones, or a scoped research -> synthesis
  pipeline for complex ones with optional delegated planning. Use when the
  user asks to research, investigate, look into, dig into, figure out, scope, deep
  dive, compare options, or plan something, or otherwise needs information
  gathered and synthesized across the codebase, the web, or connected tools.
---

# Deep Research (tiered orchestrator)

Always do **Step 0 (complexity triage)** first, then run exactly one tier. Scale
effort to the task: don't spin up subagents for a trivial question, and don't
hand-answer a broad investigation that deserves the full pipeline.

Subagents run in isolated contexts and do not see this conversation. Every prompt must restate
the goal, relevant context, sources, constraints, and expected output.

## Step 0 - Complexity triage (always)

Score the request across four axes, then pick a tier:

- **Breadth** - how many distinct areas / files / sources are involved?
- **Depth** - how much reasoning, domain knowledge, or synthesis is required?
- **Ambiguity** - is the question well-formed, or does it need scoping first?
- **Stakes** - how costly is a shallow or wrong answer?

State the chosen tier in one short line before proceeding (e.g.
`Triage: Tier 2 (standard) - 3 independent threads, low ambiguity`). Then run that
tier. When genuinely on the fence between two tiers, pick the lower one but say so.

- **Tier 1 - Trivial / Direct**: answerable from what you already know or with one
  quick lookup. Narrow scope, low stakes.
- **Tier 2 - Standard**: a handful of mostly-independent threads; the shape of the
  answer is clear; little upfront scoping needed.
- **Tier 3 - Complex / Deep**: broad, ambiguous, high-stakes, or needs a plan
  before research can even start. Multiple interacting threads, heavy synthesis.
  Choosing Tier 3 **commits you to delegated scoping, research, and synthesis**.
  Collection stays on the cheap tiers; the deep-reasoning roles run on the
  escalation model (see Models).

## Models

- `researcher-lite`: `opencode/minimax-m2.7` (cheap/fast collection)
- `researcher-mid`: `opencode/kimi-k2.6` (standard research)
- `researcher-deep`, `research-planner`, and `research-synthesizer`:
  `opencode/claude-sonnet-5` (deep reasoning)

Models are pinned in each agent's frontmatter (`~/.config/opencode/agents/`) per
`docs/model-routing.md`. If you pass a model explicitly on a subagent call, keep it
aligned with the agent frontmatter.

The `claude-sonnet-5` roles are the expensive escalation tier. Assigning a subtask to
them **is** the escalation decision — escalate by launching the deeper agent, not by
switching models on a cheaper role:

| Role | Use when |
|------|----------|
| `researcher-deep` | Heavy architecture/tradeoff, security/performance, or conflicting-source reasoning — ideally with the subtask evidence packet already gathered by cheaper collectors. |
| `research-planner` | Difficult decomposition remains after collectors assembled a complete evidence packet — including irreversible schema/deploy sequencing or cross-service contract design. |
| `research-synthesizer` | Tier 3 synthesis (always); large, conflicting, or high-stakes researcher outputs need deeper judgment to curate. |

`researcher-mid` never does deep-reasoning work — if a subtask needs it, assign
or reassign the subtask to `researcher-deep` instead. Tier 2 never launches
`research-planner` or `research-synthesizer` (the main chat synthesizes). Tier 3 alone
does not justify `researcher-deep` or `research-planner`, but after collectors finish,
prefer them when the remaining question is irreversible schema/deploy sequencing or
cross-service contract design. When unsure on other cases, stay on the cheap tiers.
Give the deep roles complete, self-contained evidence packets so their expensive
context is spent reasoning, not sweeping sources — tell them to stop with exact
missing evidence rather than gathering anything.

## Tier 1 - Direct

1. Answer directly from your own knowledge.
2. If a single fact / file / symbol needs confirming, spawn **one**
   `researcher-lite` for it; otherwise use your own tools inline. If the session
   is running on the escalation model (`claude-sonnet-5`), do not use tools
   inline — always spawn a cheap collector instead.
3. Give a concise answer with citations (`file:line` for code, URLs for web). No
   planner, no synthesizer, no report file.

## Tier 2 - Standard

1. Create a short todo list with `todowrite` (one item per research thread + "synthesize").
2. Decompose the request inline into 2-4 subtasks. Mark each as independent or
   dependent on another subtask's output, and assign each a tier (lite vs mid) by
   its difficulty.
3. **Dispatch dependency-aware research**: launch independent researchers in
   parallel with multiple task tool calls in a single message.
   For dependent subtasks, wait for the dependency to return, then launch the next
   researcher with the prior findings included in its self-contained prompt.
4. Collect the findings and **synthesize them yourself** (no synthesizer subagent
   at this tier — do not launch `research-planner` or `research-synthesizer`).
   Deduplicate overlaps; resolve contradictions or flag them.
5. Present a scannable summary with citations. Write a report file only if the result is a
   standalone analytical artifact (see "Reports").

## Tier 3 - Complex (full pipeline)

Tier 3 is a **delegation pipeline, not a solo investigation**. Your role is to
scope the work, dispatch collectors and researchers, escalate subtasks to the
deep-reasoning roles when the Models criteria apply, and relay the
synthesized result. All source inspection belongs to the lite/mid researchers.

**Definition of a valid Tier 3 run.** Before you present anything, you must have
made, in order:

1. **one or more** `researcher-lite` / `researcher-mid` collector calls to gather
   planning evidence (scoping),
2. optionally **one** `research-planner` call when the Models criteria apply and a
   complete evidence packet exists,
3. **one or more** researcher calls for the planned subtasks, and
4. exactly **one** `research-synthesizer` call.

Do not reach for `researcher-deep` or `research-planner` merely because the task is
Tier 3. Escalate when the remaining question is a difficult reasoning problem — for
example decomposing a high-stakes investigation or analyzing a complete evidence
packet that no longer needs source lookups. The main chat applies any escalation by
launching the deeper agent; this skill does not switch models itself.

### Steps

1. **Track it**: create a `todowrite` list - `scope -> plan -> research (N subtasks)
   -> synthesize -> present`.
2. **Collect planning evidence**: use `researcher-lite` / `researcher-mid` collectors
   to gather the codebase, web, MCP, log, or command evidence needed to scope concrete
   research subtasks. Launch independent collection in parallel. Do not give this
   sweep to the deep-reasoning roles.
3. **Plan**: normally decompose the work yourself from the collected evidence.
   Escalate to `research-planner` when the Models criteria apply. Never put
   deep-reasoning work on `researcher-mid` — use `researcher-deep` instead.
   - Give `research-planner` one discrete planning or reasoning question and a
     compact, complete evidence packet containing the request, constraints, source
     inventory, relevant excerpts, competing findings, and unresolved decisions.
   - Its job is reasoning over the packet, not gathering. If it reports missing
     evidence, send that exact gap to a `researcher-lite` / `researcher-mid`
     collector, then rerun the planner with the completed packet. Never let the
     planner gather the missing evidence itself.
4. **Review the plan** briefly. Adjust tiers, merge redundant subtasks, or drop
   out-of-scope ones. Resolve blocking user choices before spending more research
   effort.
5. **Dispatch dependency-aware research (MANDATORY subagents)**: launch all
   subtasks with no unmet dependencies in parallel on `researcher-mid` by default.
   After each wave returns, launch the next subtasks whose dependencies are complete
   and include the needed prior findings in each self-contained prompt. Escalate a
   subtask to `researcher-deep` when deeper reasoning is justified and its evidence
   packet is complete — never overload mid; reassign to deep. Keep unrelated work
   parallel and use batches of 4-6 for large fan-outs.
6. **Synthesize (MANDATORY subagent)**: spawn the `research-synthesizer` with the
   original request, the plan, and all researcher outputs (attributed by subtask id).
   Do **not** write the summary yourself - even though you could, the synthesis must
   run in an isolated context. It returns one curated, deduplicated summary with
   citations preserved, and a report-ready structure when the deliverable warrants
   it.
7. **Present**: relay the synthesizer's summary. If it is a standalone analytical
   artifact, write a markdown report file (see "Reports"); otherwise post the
   summary in chat. Always surface open questions / gaps and the sources used.

## Dispatch

- Launch independent researchers in parallel; run dependent work sequentially with prior findings.
- If a named agent is unavailable, use a general-purpose subagent with the matching agent
  definition from `~/.config/opencode/agents/` inlined and the same model. Never skip a
  required role.
- Researchers keep their web and MCP access; file edits are already denied by their agent
  `permission` frontmatter — prohibit edits in the prompt as well.
- Deep-reasoning prompts must be self-contained: complete evidence packet in, and an
  instruction to stop with exact missing evidence rather than gathering anything.
- Curate and deduplicate outputs, preserve citations, and surface conflicts or gaps.

## Reports

For Tier 3 (and Tier 2 when it fits), write the result to a standalone markdown
report file when the output is a **standalone analytical artifact** the user would
want beside the chat (structured findings, comparisons, multi-section reports, data
tables). Skip the report file for a direct answer, a quick summary, or work that's a
means to another deliverable.

## Guardrails

- **Triage out loud**: always state the chosen tier and a one-line reason first.
- **Tier 3 means delegate**: if lite/mid collectors did not gather scoping
  evidence, researchers did not inspect the sources, and a synthesizer did not
  merge their findings, you did not run Tier 3.
- **Cheap tiers by default, escalate by role**: collection and standard research run
  on the `minimax-m2.7` / `kimi-k2.6` roles. Reserve the `claude-sonnet-5` roles
  (deep, planner, synthesizer) for genuinely hard reasoning after the evidence
  packet is complete, and state why when you escalate.
- **The deep tier never does the broad sweep**: give `researcher-deep`,
  `research-planner`, and `research-synthesizer` complete evidence packets;
  delegate broad source sweeps, searches, and commands to `researcher-lite` /
  `researcher-mid`. If the session itself runs on `claude-sonnet-5`, delegate every
  source lookup and command to cheap collectors — including Tier 1 confirmations
  (never use tools inline from an escalation-model session).
- **Cite everything**: `file:line` for code, URLs for web, tool/source name for MCP.
- **Right-size effort**: prefer the lowest tier that fully answers the question.
- **Surface gaps**: list what couldn't be confirmed and what would resolve it.
