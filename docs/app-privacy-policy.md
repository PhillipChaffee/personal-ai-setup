---
title: Privacy Policy — personal-ai
permalink: /privacy/
---

# Privacy Policy — "personal-ai" (Google OAuth application)

*Effective: 2026-08-21*

**personal-ai** is a personal, single-user application: an instance of the
open-source [personal-ai-setup](https://github.com/PhillipChaffee/personal-ai-setup)
blueprint, operated by its owner for their own Google account. It is not a
service offered to others; the only user of any given instance is the person
who created and runs it. This policy describes what an instance does with
Google user data.

## What the app accesses

Through Google's APIs, and only after the operator grants OAuth consent, the
app accesses the operator's own **Gmail, Google Calendar, and Google Tasks**
data.

## How Google user data is used

- Data is accessed only to serve the operator's explicit requests and the
  automations the operator configured (for example: summarizing the day's
  calendar, triaging the inbox into labels and reply drafts).
- Relevant excerpts may be included as context in requests to the AI
  inference providers the operator configured, under those providers'
  zero-data-retention API terms. This processing happens solely on the
  operator's behalf.
- The app never sends email on its own, never shares data with third parties
  beyond the processing above, and uses no data for advertising. Nothing is
  sold, ever.

## Storage and retention

OAuth tokens are stored only on hardware the operator controls (on an
encrypted volume in the reference setup). Message and calendar content is
processed transiently to produce the requested output and is not accumulated
into any separate store of Google user data.

## Limited Use disclosure

This app's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

## Revoking access

Revoke the app's access at any time at
[myaccount.google.com/permissions](https://myaccount.google.com/permissions);
deleting the instance's token files has the same effect for that machine.

## Contact

The operator of an instance is its own data controller. For this instance and
the blueprint itself: `phillipdensmorechaffee@gmail.com`, or open an issue on
[the repository](https://github.com/PhillipChaffee/personal-ai-setup).
