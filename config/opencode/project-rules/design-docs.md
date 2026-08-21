<!-- Project rule: structure for design docs and technical specs.
     Use by pasting into a project's AGENTS.md or listing this file's path in the project's opencode.json "instructions" array. -->

# Design Docs

Use this rule when creating design write-ups, posting plans to Notion, writing technical specs for reviewers, or when the user asks for a design doc.

Write design docs that help engineers understand the **why**, the architecture, and the API before diving into code. These accompany larger features and live in your team wiki (linked from MR/PR descriptions).

## Required sections (in this order)

If a section does not apply, keep the heading and write `N/A` with a one-line reason (e.g., "N/A — no new endpoints or webhooks in this change"). Do not remove or reorder headings.

### `## Problem`

Why does this feature exist? Who needs it and what's the current gap? Name concrete symptoms or business drivers. Be specific, not vague.

```markdown
## Problem

Acme Corp needs to notify downstream systems when an order ships.
No existing hook lets an external fulfillment partner push status into our
orders API in real time — today operators paste tracking numbers by hand.
This blocks Acme from scaling partner fulfillments.
```

### `## Solution`

High-level approach in 1-2 paragraphs. How does the system work after this change? Follow with a **sequence or flow diagram** (mermaid) if the flow involves multiple services or async steps.

```markdown
## Solution

orders-service emits shipment events to an external fulfillment partner via webhook.
When the partner confirms delivery, it calls back with a tracking payload.
orders-service updates the order and notify-service emails the customer.

[mermaid sequence diagram here]
```

### `## How It Works`

Document the complete end-to-end flow from **two perspectives**. This is the most important section — if a reader only reads one part of the doc, this should give them a full mental model of the feature.

**Product perspective**: Walk through the feature step-by-step as the user (or system) experiences it.

**Code perspective**: For each step in the product flow, name the service, module, and function that handles it. Trace the full call chain from trigger to completion.

```markdown
## How It Works

### Product flow
1. Warehouse marks an order as shipped
2. External partner receives a webhook with shipment details
3. Partner confirms delivery in their UI
4. Partner calls back with tracking payload
5. Customer receives an email; order status updates

### Code flow
1. **orders-service** (`shipment_service.mark_shipped()`) — emits outbound webhook
2. **orders-service** (`ShipmentWebhookView.post()`) — receives partner callback
3. **orders-service** (`shipment_service.apply_tracking()`) — updates order row
4. **notify-service** (`email_worker.send_delivery_email()`) — queues customer email

[mermaid sequence diagram showing the full flow]
```

### `## API Contract`

Request/response shapes for any new endpoints or webhooks. Include examples with realistic data. Specify auth, error codes, and edge cases. Use JSON code blocks.

### `## System Design`

Key technical decisions, state machines, data models, and rationale.

### `## Architecture`

Component diagram showing **new vs modified** components and how they connect. Use mermaid. Label each component as **new**, **modified**, or **existing (unchanged)**.

### `## Deployment & Rollout`

- Deploy order (which service first and why)
- Feature flags and kill switches
- Migration steps
- Rollback plan

### `## Test Plan`

- Key unit test cases
- Integration / local testing approach
- Manual verification steps
- Failure path tests

## Guidelines

- **Start with why.**
- **Diagrams over prose** for flows and architecture.
- **Concrete over abstract.**
- **Link to MRs/PRs**, don't duplicate them.
- **Keep it proportional.**

## Anti-patterns

- A file list masquerading as architecture
- Vague problem statement ("we need this feature")
- Missing error handling / failure paths
- API contract without example payloads
- State machine without terminal states
- High-level solution without step-by-step product and code flow
