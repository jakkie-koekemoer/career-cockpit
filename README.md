# Career Cockpit

Private application-management dashboard for Jakkie and Maryka Koekemoer.

## Live architecture

- **Supabase Career project** is the canonical data store.
- **GitHub** stores the reproducible dashboard source and schema.
- Google sign-in is restricted to authorised cockpit members.
- Row Level Security isolates each member's applications, activity, feedback and private resume configuration.

## Current capabilities

- Separate Jakkie and Maryka application pipelines based on the signed-in Google account
- Prioritised roles and fit scores
- Search and status filters
- Status updates, editable next actions and notes persisted to Supabase
- Application and contact links
- Tailored outreach messages with copy-to-clipboard
- Compensation positioning, gaps and application/interview preparation
- Application activity history
- Role-specific resume PDF generation from private Supabase-backed resume configuration
- General and role-specific feedback queue for ChatGPT, with responses visible in the cockpit
- Responsive desktop/mobile interface

## Documents

Canonical Word/PDF resumes remain in the ChatGPT Career Search Library. The dashboard generates application-ready PDF copies from private role-specific resume configurations stored behind Supabase RLS, avoiding public resume content in the GitHub repository.

## Supabase

The Supabase project stores applications, members, activity, feedback and private resume configuration. RLS is the primary access-control boundary for cockpit data.

## Deployment

Production is connected to this GitHub repository on Vercel. Commits to `main` trigger a fresh deployment.
