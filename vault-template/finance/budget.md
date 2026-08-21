# Budget

Monthly targets per category. The monthly `budget-checkin` automation
(disabled until you enable it — see the personal-ai-setup repo's
`docs/automations.md`) totals last month's `ledger.csv` per category and
compares against this table. Replace the EXAMPLE rows with your real
categories; category names must match the ledger's `category` column
byte-for-byte.

## Conventions

- `ledger.csv` columns: `date,amount,category,note` — dates as `YYYY-MM-DD`,
  **amounts as positive numbers meaning money spent** (record refunds as
  negative amounts in the same category).
- Targets below are per calendar month, in your home currency.
- Keep the table small and honest — a handful of categories you actually
  maintain beats twenty you don't.

## Monthly targets

| Category | Monthly target | Notes |
|---|---:|---|
| groceries | 400 | (EXAMPLE — replace) |
| transport | 120 | (EXAMPLE — replace) |
| Total | 520 | keep in sync with the rows above |

## Notes

Free-form context for future you and for the agent: planned one-off expenses,
categories under review, why a target changed. Dated bullets work well:

- 2026-08-21 — seeded from template (EXAMPLE — replace)
