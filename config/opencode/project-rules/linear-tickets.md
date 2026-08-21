<!-- Project rule: Linear ticket conventions for ENG issues (structure, style, required sections).
     Use by pasting into a project's AGENTS.md or listing this file's path in the project's opencode.json "instructions" array.
     Creating/updating tickets from a session requires the Linear MCP to be connected. -->

# Linear Tickets (ENG)

## When This Applies

Follow these conventions when creating or updating Linear issues on an ENG team board. Non-ENG tickets (design, ops, support) may follow different formats.

## Title

- Write a short, direct title that describes the concrete task.
- Easy to scan in a list — avoid filler words like "Implement", "We should", or "As a user".
- Prefix with the area or service when it reduces ambiguity (e.g. `service-a: retry on telephony-provider 503`, `service-b: deduplicate webhook delivery`).

```
# ✅ Good
Add rate limiting to outbound call endpoint
service-b: migrate lead status to state machine
Fix timezone offset in availability window calculation

# ❌ Bad — vague, verbose, or user-story format
As a user I want to be able to see my call history
Implement the new thing for the service-b
Improvements
```

## Required Sections

Every ENG ticket body must include these four sections in order. Use the exact headings below so they are consistent and scannable across the board.

### Description

One or two short paragraphs explaining **what** the task is and **why** it matters. Include:

- The problem or motivation — what's broken, slow, missing, or requested.
- Who or what is affected (users, services, internal workflows).
- Links to relevant conversations, bug reports, or data (Slack threads, Sentry links, dashboards).

Keep it concrete. If you're quoting a user or customer, paste the quote directly instead of summarizing.

### Acceptance Criteria

A checklist of conditions that must be true for the ticket to be considered done. Each item should be **verifiable** — someone reviewing the work can confirm yes/no whether it's met.

- Focus on observable outcomes and user-visible behavior, not implementation details.
- Include important edge cases (2–3 max).
- Add performance or reliability constraints when they matter (e.g. "p99 latency stays under 200ms").
- Keep the list short. If you need more than ~6 items, the ticket is probably too large — break it up.

```markdown
## Acceptance Criteria

- [ ] Outbound calls respect the per-company rate limit (default 10/min)
- [ ] Calls that exceed the limit return 429 with a Retry-After header
- [ ] Existing calls in progress are not affected when the limit is hit
- [ ] Rate limit value is configurable per company via admin
```

### Resources

Links, references, and supporting material needed to do the work:

- Design files (Figma links, screenshots)
- Technical specs or project docs
- Relevant PRs, previous tickets, or related issues
- API docs, third-party references
- Logs, Sentry issues, or dashboard links that illustrate the problem

If there are no resources, write "None" — don't remove the section.

### Notes

Additional context that doesn't fit elsewhere:

- Known constraints, blockers, or dependencies on other tickets.
- Suggestions on approach (frame as suggestions, not mandates — let the assignee decide how to solve it).
- Out-of-scope items worth calling out to prevent scope creep.
- Rollout or deploy considerations (feature flag needed, after-hours deploy, etc.).

If there are no notes, write "None" — don't remove the section.

## Full Example

```markdown
## Description

The outbound call endpoint (`/api/v1/calls/outbound`) has no rate limiting.
A misconfigured automation at Acme Corp fired 400 calls in under a minute,
which saturated our telephony-provider pool and degraded call quality for other companies.
See Slack thread: https://slack.com/archives/C0123/p1234567890

## Acceptance Criteria

- [ ] Outbound calls respect the per-company rate limit (default 10/min)
- [ ] Calls that exceed the limit return 429 with a Retry-After header
- [ ] Existing calls in progress are not affected when the limit is hit
- [ ] Rate limit value is configurable per company via admin

## Resources

- Project spec: https://linear.app/docs/outbound-rate-limiting
- Telephony provider rate-limit docs: https://docs.example-telephony.com/rate-limits
- Related ticket: TICKET-892 (inbound rate limiting — same pattern)

## Notes

- Use the existing Redis sliding-window counter from inbound limiting (TICKET-892).
- Feature-flag this behind `outbound_rate_limit_enabled` so we can roll out per-company.
- Out of scope: per-agent limits (future ticket).
```

## Writing Style

- **Write issues, not user stories.** Describe the task directly in plain language. Don't use "As a [role] I want [thing] so that [reason]" format.
- **Be concrete.** Name the service, endpoint, model, or file. Vague tickets waste time in clarification.
- **Keep it brief.** Write only what's needed to do the work and communicate context to the team. Don't pad sections with filler.
- **Break large work into smaller tickets.** If a ticket has more than ~6 acceptance criteria or touches more than 2–3 services, split it.
- **Single owner.** Each ticket should be assignable to one person. If multiple people are needed, create sub-issues.
