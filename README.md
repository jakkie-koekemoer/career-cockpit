# Career Cockpit

Private, evidence-backed application management for Jakkie and Maryka Koekemoer.

## Operating model

- **Supabase Career** is the canonical operational record.
- **Career Cockpit** is the authenticated human view and approval surface.
- **Co-work** researches, reconciles, prepares, and coordinates; it is not the database.
- **Chats, email, job sites, and ATS portals** are evidence inputs, not the final record.
- **The applicant retains authority** over external actions.

External actions use three deliberately narrow approval gates:

- `PURSUE` — prepare for one named role.
- `SUBMIT` — authorise one exact finalized package and listing snapshot.
- `SEND` — authorise one exact message, recipient, and channel.

Recording approval does not perform the external action. Submission execution remains a separate, idempotent intent with confirmation evidence and an explicit uncertain state.

## Capabilities

- Separate member-owned pipelines with Google sign-in and Row Level Security
- Independent listing, decision, application, and outreach state lanes
- Next-action owner and due-date queues
- Immutable, versioned application packages with artifact and snapshot hashes
- Scoped, expiring, revocable approvals
- Idempotent submission intents and a no-blind-retry uncertain state
- Evidence, communication, reconciliation, and candidate-fact records
- Dedupe identifiers and source provenance
- Compatibility summary in the legacy `applications.status` field
- Priorities, fit scores, role preparation, notes, activity, and feedback
- Private Supabase-backed resume generation
- Responsive desktop/mobile interface

## Repository layout

- `index.html` — static authenticated dashboard
- `supabase/schema.sql` — historical bootstrap schema
- `supabase/migrations/` — canonical forward schema history
- `supabase/tests/` — database contract checks to run after migrations
- `tests/` — local static application checks
- `docs/OPERATING_MODEL.md` — authority, states, invariants, and cadence
- `docs/RECONCILIATION_RUNBOOK.md` — safe historical-import procedure
- `docs/SECURITY_AND_RECOVERY.md` — security, backup, incident, and fallback rules

## Database change procedure

1. Take a protected data export; never commit it.
2. Apply migrations to an isolated Supabase branch.
3. Run the database contract test and test RLS as each member.
4. Review Supabase security and performance advisors.
5. Apply the same migration to production, verify counts and access, then deploy the matching UI.

The browser publishable key is intentionally public. RLS, table grants, and authenticated membership functions are the security boundary. Service-role keys and private data must never enter this repository.

## Deployment

Production is connected to this GitHub repository on Vercel. Commits to `main` trigger deployment, so schema and UI changes must be released in the order above. Local branches do not change production.
