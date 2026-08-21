---
title: personal-ai-setup
permalink: /
---

# personal-ai-setup

A self-owned personal AI, built from open-source parts and pay-as-you-go
inference: one [Goose](https://github.com/aaif-goose/goose) agent with one
shared conversation history runs 24/7 on a small hardened VPS; your laptop and
phone are thin clients to it; scheduled automations (morning brief, inbox
triage, weekly review) deliver to your phone; and sensitive data only ever
reaches zero-data-retention inference endpoints.

**Everything lives in the GitHub repository — start there:**

- **[The repository & README](https://github.com/PhillipChaffee/personal-ai-setup)** — what you get, prerequisites, costs (~$15–35/mo), and the quickstart
- [Setup runbooks](setup/00-overview.md) — the five phases, from empty Mac to deployed brain
- [Model routing](model-routing.md) & [data-classification rules](privacy.md) — which model handles which job, and the hard privacy rules that bound it
- [Privacy policy](app-privacy-policy.md) — for the self-created Google OAuth app each instance uses
- [Security model](security.md) · [Automations](automations.md) · [Troubleshooting](troubleshooting.md) · [Roadmap](roadmap.md)

Licensed [MIT](https://github.com/PhillipChaffee/personal-ai-setup/blob/main/LICENSE).
Built for one person to rebuild for themselves in a weekend.
