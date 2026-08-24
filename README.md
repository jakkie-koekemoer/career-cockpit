# Career Cockpit

Private application-management dashboard for Jakkie Koekemoer's engineering leadership job search.

## Live architecture

- **Supabase Career project** is the canonical data store.
- **Supabase Edge Function `career-cockpit`** serves the live dashboard and its private API.
- **GitHub** stores the reproducible project configuration and schema.
- The dashboard is protected by a long random browser-held access key; only its SHA-256 hash is stored in the deployed function.
- Database RLS remains enabled as defence in depth.

## Current capabilities

- Prioritized application pipeline and fit scores
- Search and status filters
- Status updates persisted to Supabase
- Editable next actions and notes
- Application links and contact/profile links
- Tailored outreach messages with copy-to-clipboard
- Compensation positioning, gaps and application/interview preparation
- Application activity history
- Responsive desktop/mobile interface

## Documents

Role-specific resumes remain in the canonical ChatGPT Career Search Library while private document hosting is being connected to the live dashboard. The interface already has the document slot, so adding storage will not change the workflow.

## Supabase

`supabase/schema.sql` documents the application data model. `supabase/config.toml` records the Edge Function's custom-auth configuration.
