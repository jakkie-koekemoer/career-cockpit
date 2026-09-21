-- Follow-up from the post-migration Supabase performance advisor.

create index if not exists application_approvals_package_id_idx
  on public.application_approvals(package_id)
  where package_id is not null;

create index if not exists application_evidence_package_id_idx
  on public.application_evidence(package_id)
  where package_id is not null;

create index if not exists application_evidence_submission_intent_id_idx
  on public.application_evidence(submission_intent_id)
  where submission_intent_id is not null;

create index if not exists application_packages_supersedes_id_idx
  on public.application_packages(supersedes_id)
  where supersedes_id is not null;

create index if not exists applications_duplicate_of_idx
  on public.applications(duplicate_of)
  where duplicate_of is not null;

create index if not exists reconciliation_items_application_id_idx
  on public.reconciliation_items(application_id)
  where application_id is not null;

create index if not exists submission_intents_approval_id_idx
  on public.submission_intents(approval_id);

create index if not exists submission_intents_package_id_idx
  on public.submission_intents(package_id);

drop policy if exists owner_self_select on public.cockpit_owner;
create policy owner_self_select
on public.cockpit_owner for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists owner_first_google_insert on public.cockpit_owner;
create policy owner_first_google_insert
on public.cockpit_owner for insert to authenticated
with check (
  singleton = true
  and user_id = (select auth.uid())
  and coalesce((select auth.jwt()) -> 'app_metadata' ->> 'provider', '') = 'google'
);
