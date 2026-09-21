-- Career Cockpit safe application workflow.
--
-- This migration is deliberately additive. The legacy applications.status
-- column remains as a compatibility summary while the independent workflow
-- lanes below become the operational source of truth.

-- Privileged trigger helpers live outside the exposed public schema.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated, service_role;

create or replace function private.is_cockpit_member()
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = 'off'
as $$
  select exists (
    select 1
    from public.cockpit_members m
    where lower(m.email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
      and m.active = true
  );
$$;

create or replace function private.can_edit_cockpit_person(target_person text)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = 'off'
as $$
  select exists (
    select 1
    from public.cockpit_members m
    where lower(m.email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
      and m.active = true
      and m.person = target_person
  );
$$;

create or replace function private.can_view_cockpit_person(target_person text)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = 'off'
as $$
  select exists (
    select 1
    from public.cockpit_members m
    where lower(m.email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
      and m.active = true
      and (m.person = target_person or m.can_view_all = true)
  );
$$;

revoke all on function private.is_cockpit_member() from public, anon, authenticated;
revoke all on function private.can_edit_cockpit_person(text) from public, anon, authenticated;
revoke all on function private.can_view_cockpit_person(text) from public, anon, authenticated;
grant execute on function private.is_cockpit_member() to authenticated, service_role;
grant execute on function private.can_edit_cockpit_person(text) to authenticated, service_role;
grant execute on function private.can_view_cockpit_person(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Applications: independent state lanes, reconciliation, ownership and dedupe
-- ---------------------------------------------------------------------------

alter table public.applications
  add column if not exists listing_state text not null default 'unknown',
  add column if not exists decision_state text not null default 'unreviewed',
  add column if not exists application_state text not null default 'not_started',
  add column if not exists outreach_state text not null default 'not_planned',
  add column if not exists next_action_owner text,
  add column if not exists due_at timestamptz,
  add column if not exists reconciliation_state text not null default 'pending',
  add column if not exists data_confidence text not null default 'unknown',
  add column if not exists source_type text,
  add column if not exists source_ref text,
  add column if not exists source_provider text,
  add column if not exists external_job_id text,
  add column if not exists job_posting_hash text,
  add column if not exists dedupe_key text,
  add column if not exists duplicate_of text references public.applications(id) on delete set null,
  add column if not exists bridge_fit numeric(3,1),
  add column if not exists workflow_version integer not null default 1;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'applications_listing_state_check') then
    alter table public.applications add constraint applications_listing_state_check
      check (listing_state in ('unknown','live','closing_soon','closed','expired','removed','filled','location_blocked'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'applications_decision_state_check') then
    alter table public.applications add constraint applications_decision_state_check
      check (decision_state in ('unreviewed','needs_info','pursue','hold','declined'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'applications_application_state_check') then
    alter table public.applications add constraint applications_application_state_check
      check (application_state in ('not_started','preparing','ready','submitting','submission_uncertain','submitted','screen','interview','offer','accepted','declined_offer','rejected','withdrawn'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'applications_outreach_state_check') then
    alter table public.applications add constraint applications_outreach_state_check
      check (outreach_state in ('not_planned','drafting','approved','sent','replied','failed','closed'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'applications_reconciliation_state_check') then
    alter table public.applications add constraint applications_reconciliation_state_check
      check (reconciliation_state in ('pending','reconciled','conflict','ignored'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'applications_data_confidence_check') then
    alter table public.applications add constraint applications_data_confidence_check
      check (data_confidence in ('verified','user_asserted','inferred','unknown','conflict'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'applications_bridge_fit_check') then
    alter table public.applications add constraint applications_bridge_fit_check
      check (bridge_fit is null or bridge_fit between 0 and 10);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'applications_workflow_version_check') then
    alter table public.applications add constraint applications_workflow_version_check
      check (workflow_version > 0);
  end if;
end $$;

create index if not exists applications_due_at_idx
  on public.applications(person, due_at)
  where due_at is not null
    and application_state not in ('accepted','declined_offer','rejected','withdrawn');

create index if not exists applications_reconciliation_idx
  on public.applications(person, reconciliation_state, updated_at desc);

create index if not exists applications_dedupe_key_idx
  on public.applications(person, dedupe_key)
  where dedupe_key is not null;

create unique index if not exists applications_external_job_uq
  on public.applications(person, source_provider, external_job_id)
  where source_provider is not null and external_job_id is not null;

update public.applications
set
  listing_state = case
    when coalesce(verification_status, '') ~* 'location blocked' then 'location_blocked'
    when coalesce(verification_status, '') ~* 'expired' then 'expired'
    when coalesce(verification_status, '') ~* 'removed' then 'removed'
    when coalesce(verification_status, '') ~* 'filled' then 'filled'
    when status = 'Closed' or coalesce(verification_status, '') ~* '(closed|no longer available)' then 'closed'
    when coalesce(verification_status, '') ~* 'verified live' then 'live'
    else listing_state
  end,
  decision_state = case
    when status in ('Resume needed','Ready to apply','Outreach sent','Applied','Recruiter screen','Interviewing','Offer','Waiting','Rejected','Withdrawn') then 'pursue'
    when status in ('On hold','Optional stretch','Watchlist - location blocked') then 'hold'
    when status = 'Closed' and applied_at is null then 'declined'
    when status = 'Researching' then 'needs_info'
    else decision_state
  end,
  application_state = case
    when status = 'Resume needed' then 'preparing'
    when status = 'Ready to apply' then 'ready'
    when status in ('Applied','Waiting') then 'submitted'
    when status = 'Recruiter screen' then 'screen'
    when status = 'Interviewing' then 'interview'
    when status = 'Offer' then 'offer'
    when status = 'Rejected' then 'rejected'
    when status = 'Withdrawn' then 'withdrawn'
    else application_state
  end,
  outreach_state = case
    when status = 'Outreach sent' then 'sent'
    when nullif(trim(coalesce(outreach_message, '')), '') is not null then 'drafting'
    else outreach_state
  end,
  next_action_owner = coalesce(next_action_owner, person),
  reconciliation_state = 'pending',
  data_confidence = case
    when data_confidence = 'unknown' then 'inferred'
    else data_confidence
  end
where true;

-- ---------------------------------------------------------------------------
-- Immutable, versioned application packages
-- ---------------------------------------------------------------------------

create table if not exists public.application_packages (
  id uuid primary key default gen_random_uuid(),
  application_id text not null references public.applications(id) on delete cascade,
  version integer not null check (version > 0),
  package_state text not null default 'draft'
    check (package_state in ('draft','ready','submitted')),
  supersedes_id uuid references public.application_packages(id) on delete restrict,
  resume_key text,
  resume_filename text,
  resume_sha256 text,
  answers jsonb not null default '[]'::jsonb check (jsonb_typeof(answers) = 'array'),
  salary_response text,
  availability_response text,
  attachments jsonb not null default '[]'::jsonb check (jsonb_typeof(attachments) = 'array'),
  job_snapshot jsonb not null default '{}'::jsonb check (jsonb_typeof(job_snapshot) = 'object'),
  job_posting_hash text,
  package_hash text,
  created_by_email text,
  created_at timestamptz not null default now(),
  finalized_at timestamptz,
  submitted_at timestamptz,
  unique (application_id, version),
  check (package_state = 'draft' or (package_hash is not null and finalized_at is not null))
);

create unique index if not exists application_packages_hash_uq
  on public.application_packages(application_id, package_hash)
  where package_hash is not null;

create index if not exists application_packages_application_idx
  on public.application_packages(application_id, version desc);

create or replace function public.prevent_finalized_package_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and old.finalized_at is not null then
    raise exception 'Finalized application packages are immutable';
  end if;

  if tg_op = 'UPDATE' and old.finalized_at is not null then
    if row(
      new.application_id, new.version, new.supersedes_id, new.resume_key,
      new.resume_filename, new.resume_sha256, new.answers, new.salary_response,
      new.availability_response, new.attachments, new.job_snapshot,
      new.job_posting_hash, new.package_hash, new.created_by_email,
      new.created_at, new.finalized_at
    ) is distinct from row(
      old.application_id, old.version, old.supersedes_id, old.resume_key,
      old.resume_filename, old.resume_sha256, old.answers, old.salary_response,
      old.availability_response, old.attachments, old.job_snapshot,
      old.job_posting_hash, old.package_hash, old.created_by_email,
      old.created_at, old.finalized_at
    ) then
      raise exception 'Finalized application package content is immutable';
    end if;
    if new.package_state is distinct from old.package_state
       and not (
         old.package_state = 'ready'
         and new.package_state = 'submitted'
         and new.submitted_at is not null
       ) then
      raise exception 'A finalized package may only move from ready to submitted';
    end if;
    if old.package_state = 'submitted'
       and new.submitted_at is distinct from old.submitted_at then
      raise exception 'Submitted application packages are immutable';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.prevent_finalized_package_mutation() from public, anon, authenticated;

drop trigger if exists application_packages_immutable_update on public.application_packages;
create trigger application_packages_immutable_update
before update on public.application_packages
for each row execute function public.prevent_finalized_package_mutation();

drop trigger if exists application_packages_immutable_delete on public.application_packages;
create trigger application_packages_immutable_delete
before delete on public.application_packages
for each row execute function public.prevent_finalized_package_mutation();

-- ---------------------------------------------------------------------------
-- Scoped approvals and idempotent submission intents
-- ---------------------------------------------------------------------------

create table if not exists public.application_approvals (
  id uuid primary key default gen_random_uuid(),
  application_id text not null references public.applications(id) on delete cascade,
  package_id uuid references public.application_packages(id) on delete restrict,
  approval_type text not null check (approval_type in ('pursue','submit','send')),
  approval_state text not null default 'approved'
    check (approval_state in ('approved','consumed','revoked','expired')),
  scope jsonb not null default '{}'::jsonb check (jsonb_typeof(scope) = 'object'),
  job_posting_hash text,
  package_hash text,
  approved_by_email text not null,
  approved_at timestamptz not null default now(),
  expires_at timestamptz,
  consumed_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  check (
    (approval_type = 'submit'
      and package_id is not null
      and package_hash is not null
      and job_posting_hash is not null)
    or
    (approval_type <> 'submit' and package_id is null and package_hash is null)
  ),
  check (expires_at is null or expires_at > approved_at)
);

create unique index if not exists application_approvals_active_uq
  on public.application_approvals(
    application_id,
    approval_type,
    coalesce(package_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where approval_state = 'approved';

create index if not exists application_approvals_application_idx
  on public.application_approvals(application_id, approved_at desc);

create or replace function public.protect_application_approval()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if row(
    new.application_id, new.package_id, new.approval_type, new.scope,
    new.job_posting_hash, new.package_hash, new.approved_by_email,
    new.approved_at, new.expires_at, new.created_at
  ) is distinct from row(
    old.application_id, old.package_id, old.approval_type, old.scope,
    old.job_posting_hash, old.package_hash, old.approved_by_email,
    old.approved_at, old.expires_at, old.created_at
  ) then
    raise exception 'Approval scope and identity are immutable';
  end if;

  if old.approval_state <> 'approved'
     and new.approval_state is distinct from old.approval_state then
    raise exception 'Finalized approvals cannot change state';
  end if;

  if old.approval_state = 'approved'
     and new.approval_state not in ('approved','consumed','revoked','expired') then
    raise exception 'Invalid approval transition';
  end if;

  if new.approval_state = 'revoked' and new.revoked_at is null then
    new.revoked_at := now();
  elsif new.approval_state = 'consumed' and new.consumed_at is null then
    new.consumed_at := now();
  end if;

  return new;
end;
$$;

revoke all on function public.protect_application_approval() from public, anon, authenticated;

drop trigger if exists application_approvals_protect on public.application_approvals;
create trigger application_approvals_protect
before update on public.application_approvals
for each row execute function public.protect_application_approval();

create or replace function private.expire_stale_application_approvals()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.application_approvals
  set approval_state = 'expired'
  where application_id = new.application_id
    and approval_type = new.approval_type
    and approval_state = 'approved'
    and expires_at is not null
    and expires_at <= now();
  return new;
end;
$$;

revoke all on function private.expire_stale_application_approvals() from public, anon, authenticated;

drop trigger if exists application_approvals_expire_stale on public.application_approvals;
create trigger application_approvals_expire_stale
before insert on public.application_approvals
for each row execute function private.expire_stale_application_approvals();

create table if not exists public.submission_intents (
  id uuid primary key default gen_random_uuid(),
  application_id text not null references public.applications(id) on delete cascade,
  package_id uuid not null references public.application_packages(id) on delete restrict,
  approval_id uuid not null references public.application_approvals(id) on delete restrict,
  idempotency_key text not null unique,
  intent_state text not null default 'prepared'
    check (intent_state in ('prepared','executing','confirmed','uncertain','failed','cancelled')),
  executor text,
  destination text,
  requested_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  external_reference text,
  confirmation_url text,
  confirmation_email_id text,
  evidence jsonb not null default '[]'::jsonb check (jsonb_typeof(evidence) = 'array'),
  error_detail text,
  created_at timestamptz not null default now(),
  check (
    intent_state <> 'confirmed'
    or external_reference is not null
    or confirmation_url is not null
    or confirmation_email_id is not null
    or jsonb_array_length(evidence) > 0
  )
);

create index if not exists submission_intents_application_idx
  on public.submission_intents(application_id, created_at desc);

create or replace function public.validate_submission_intent()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.application_approvals ap
    join public.application_packages p on p.id = new.package_id
    where ap.id = new.approval_id
      and ap.approval_type = 'submit'
      and ap.approval_state = 'approved'
      and (ap.expires_at is null or ap.expires_at > now())
      and ap.application_id = new.application_id
      and ap.package_id = new.package_id
      and ap.package_hash = p.package_hash
      and ap.job_posting_hash = p.job_posting_hash
      and p.application_id = new.application_id
      and p.package_state = 'ready'
      and p.finalized_at is not null
  ) then
    raise exception 'Submission intent requires a current SUBMIT approval for the exact ready package';
  end if;
  return new;
end;
$$;

revoke all on function public.validate_submission_intent() from public, anon, authenticated;

drop trigger if exists submission_intents_validate_insert on public.submission_intents;
create trigger submission_intents_validate_insert
before insert on public.submission_intents
for each row execute function public.validate_submission_intent();

create or replace function public.protect_submission_intent()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if row(
    new.application_id, new.package_id, new.approval_id, new.idempotency_key,
    new.executor, new.destination, new.requested_at, new.created_at
  ) is distinct from row(
    old.application_id, old.package_id, old.approval_id, old.idempotency_key,
    old.executor, old.destination, old.requested_at, old.created_at
  ) then
    raise exception 'Submission intent identity is immutable';
  end if;

  if new.intent_state is distinct from old.intent_state and not (
    (old.intent_state = 'prepared' and new.intent_state in ('executing','cancelled'))
    or (old.intent_state = 'executing' and new.intent_state in ('confirmed','uncertain','failed'))
    or (old.intent_state = 'uncertain' and new.intent_state in ('confirmed','failed','cancelled'))
  ) then
    raise exception 'Invalid submission-intent transition from % to %', old.intent_state, new.intent_state;
  end if;

  if new.intent_state = 'executing' and new.started_at is null then
    new.started_at := now();
  end if;
  if new.intent_state in ('confirmed','failed','cancelled') and new.completed_at is null then
    new.completed_at := now();
  end if;

  return new;
end;
$$;

revoke all on function public.protect_submission_intent() from public, anon, authenticated;

drop trigger if exists submission_intents_protect_update on public.submission_intents;
create trigger submission_intents_protect_update
before update on public.submission_intents
for each row execute function public.protect_submission_intent();

create or replace function private.consume_submission_approval()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  consumed_id uuid;
begin
  update public.application_approvals
  set approval_state = 'consumed', consumed_at = now()
  where id = new.approval_id and approval_state = 'approved'
  returning id into consumed_id;

  if consumed_id is null then
    raise exception 'SUBMIT approval was already consumed or is no longer active';
  end if;
  return new;
end;
$$;

revoke all on function private.consume_submission_approval() from public, anon, authenticated;

drop trigger if exists submission_intents_consume_approval on public.submission_intents;
create trigger submission_intents_consume_approval
after insert on public.submission_intents
for each row execute function private.consume_submission_approval();

create or replace function private.sync_submission_intent_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.intent_state = 'executing' then
    update public.applications
    set application_state = 'submitting'
    where id = new.application_id;
  elsif new.intent_state = 'uncertain' then
    update public.applications
    set application_state = 'submission_uncertain'
    where id = new.application_id;
  elsif new.intent_state = 'confirmed' then
    update public.application_packages
    set package_state = 'submitted', submitted_at = coalesce(submitted_at, new.completed_at, now())
    where id = new.package_id;

    update public.applications
    set application_state = 'submitted'
    where id = new.application_id;
  elsif new.intent_state in ('failed','cancelled') then
    update public.applications
    set application_state = 'ready'
    where id = new.application_id
      and application_state in ('submitting','submission_uncertain');
  end if;
  return new;
end;
$$;

revoke all on function private.sync_submission_intent_state() from public, anon, authenticated;

drop trigger if exists submission_intents_sync_state on public.submission_intents;
create trigger submission_intents_sync_state
after update of intent_state on public.submission_intents
for each row
when (old.intent_state is distinct from new.intent_state)
execute function private.sync_submission_intent_state();

-- ---------------------------------------------------------------------------
-- Evidence, truth claims, reconciliation and communications
-- ---------------------------------------------------------------------------

create table if not exists public.application_evidence (
  id uuid primary key default gen_random_uuid(),
  application_id text not null references public.applications(id) on delete cascade,
  package_id uuid references public.application_packages(id) on delete restrict,
  submission_intent_id uuid references public.submission_intents(id) on delete restrict,
  evidence_type text not null
    check (evidence_type in ('listing_snapshot','approval','confirmation_page','confirmation_email','ats_status','sent_message','interview_booking','offer','rejection','other')),
  storage_locator text not null,
  sha256 text,
  source text,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  captured_at timestamptz not null default now(),
  created_by_email text,
  created_at timestamptz not null default now()
);

create index if not exists application_evidence_application_idx
  on public.application_evidence(application_id, captured_at desc);

create table if not exists public.candidate_truth_claims (
  id uuid primary key default gen_random_uuid(),
  person text not null,
  claim_key text not null,
  category text not null,
  claim_text text not null,
  confidence text not null default 'unknown'
    check (confidence in ('verified','user_asserted','inferred','unknown','conflict','retired')),
  sensitivity text not null default 'private'
    check (sensitivity in ('public','private','never_upload')),
  source_type text,
  source_ref text,
  evidence_notes text,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (person, claim_key)
);

create index if not exists candidate_truth_claims_person_idx
  on public.candidate_truth_claims(person, category, confidence);

create table if not exists public.reconciliation_items (
  id uuid primary key default gen_random_uuid(),
  batch_id text not null,
  person text not null,
  application_id text references public.applications(id) on delete cascade,
  source_type text not null,
  source_ref text,
  item_type text not null,
  summary text not null,
  confidence text not null default 'unknown'
    check (confidence in ('verified','user_asserted','inferred','unknown','conflict')),
  reconciliation_state text not null default 'pending'
    check (reconciliation_state in ('pending','reconciled','conflict','ignored')),
  resolution_notes text,
  next_action_owner text,
  due_at timestamptz,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists reconciliation_items_queue_idx
  on public.reconciliation_items(person, reconciliation_state, due_at, created_at);

create table if not exists public.application_communications (
  id uuid primary key default gen_random_uuid(),
  application_id text not null references public.applications(id) on delete cascade,
  direction text not null check (direction in ('incoming','outgoing')),
  channel text not null check (channel in ('email','linkedin','ats','phone','meeting','other')),
  provider_message_id text,
  occurred_at timestamptz not null,
  counterparty text,
  subject text,
  body_excerpt text,
  classification text,
  requires_action boolean not null default false,
  source_ref text,
  created_at timestamptz not null default now()
);

create unique index if not exists application_communications_provider_uq
  on public.application_communications(channel, provider_message_id)
  where provider_message_id is not null;

create index if not exists application_communications_application_idx
  on public.application_communications(application_id, occurred_at desc);

-- Extend the existing append-only activity table with provenance and evidence.
alter table public.application_activity
  add column if not exists actor_email text,
  add column if not exists source text,
  add column if not exists source_ref text,
  add column if not exists original_happened_at timestamptz,
  add column if not exists idempotency_key text,
  add column if not exists payload jsonb not null default '{}'::jsonb,
  add column if not exists evidence_url text;

create unique index if not exists application_activity_idempotency_uq
  on public.application_activity(idempotency_key)
  where idempotency_key is not null;

create index if not exists cockpit_feedback_application_id_idx
  on public.cockpit_feedback(application_id)
  where application_id is not null;

-- ---------------------------------------------------------------------------
-- Workflow compatibility and audit triggers
-- ---------------------------------------------------------------------------

create or replace function public.sync_application_legacy_status()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.status := case
    when new.application_state = 'accepted' then 'Offer'
    when new.application_state in ('offer','declined_offer') then 'Offer'
    when new.application_state = 'interview' then 'Interviewing'
    when new.application_state = 'screen' then 'Recruiter screen'
    when new.application_state in ('submitted','submission_uncertain','submitting') then 'Applied'
    when new.application_state = 'rejected' then 'Rejected'
    when new.application_state = 'withdrawn' then 'Withdrawn'
    when new.application_state = 'ready' then 'Ready to apply'
    when new.application_state = 'preparing' then 'Resume needed'
    when new.outreach_state in ('sent','replied') then 'Outreach sent'
    when new.decision_state = 'hold' then 'On hold'
    when new.listing_state in ('closed','expired','removed','filled') then 'Closed'
    else 'Researching'
  end;
  new.workflow_version := coalesce(old.workflow_version, new.workflow_version, 0) + 1;
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.sync_application_legacy_status() from public, anon, authenticated;

drop trigger if exists applications_sync_legacy_status on public.applications;
create trigger applications_sync_legacy_status
before update of listing_state, decision_state, application_state, outreach_state
on public.applications
for each row
when (
  row(old.listing_state, old.decision_state, old.application_state, old.outreach_state)
  is distinct from
  row(new.listing_state, new.decision_state, new.application_state, new.outreach_state)
)
execute function public.sync_application_legacy_status();

create or replace function private.guard_application_state_claims()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.application_state = 'submitting'
     and new.application_state is distinct from old.application_state
     and not exists (
       select 1 from public.submission_intents si
       where si.application_id = new.id and si.intent_state = 'executing'
     ) then
    raise exception 'Submitting state requires an executing submission intent';
  end if;

  if new.application_state = 'submission_uncertain'
     and new.application_state is distinct from old.application_state
     and not exists (
       select 1 from public.submission_intents si
       where si.application_id = new.id and si.intent_state = 'uncertain'
     ) then
    raise exception 'Uncertain state requires an uncertain submission intent';
  end if;

  if new.application_state in ('submitted','screen','interview','offer','accepted','declined_offer','rejected')
     and new.application_state is distinct from old.application_state
     and old.application_state not in ('submitted','screen','interview','offer','accepted','declined_offer','rejected')
     and not exists (
       select 1 from public.submission_intents si
       where si.application_id = new.id and si.intent_state = 'confirmed'
     ) then
    raise exception 'Confirmed application progress requires a confirmed submission intent';
  end if;

  return new;
end;
$$;

revoke all on function private.guard_application_state_claims() from public, anon, authenticated;

drop trigger if exists applications_guard_state_claims on public.applications;
create trigger applications_guard_state_claims
before update of application_state on public.applications
for each row execute function private.guard_application_state_claims();

create or replace function public.guard_legacy_status_updates()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'applications.status is a compatibility summary; update the workflow state lanes instead';
end;
$$;

revoke all on function public.guard_legacy_status_updates() from public, anon, authenticated;

drop trigger if exists applications_guard_legacy_status on public.applications;
create trigger applications_guard_legacy_status
before update of status on public.applications
for each row execute function public.guard_legacy_status_updates();

create or replace function public.track_application_applied_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.applied_at is null
     and (
       new.application_state in ('submitted','screen','interview','offer','accepted','declined_offer','rejected')
       or new.status in ('Applied','Recruiter screen','Interviewing','Offer','Waiting','Rejected')
     ) then
    new.applied_at := now();
  end if;
  return new;
end;
$$;

revoke all on function public.track_application_applied_at() from public, anon, authenticated;

drop trigger if exists applications_track_applied_at on public.applications;
create trigger applications_track_applied_at
before insert or update of status, application_state on public.applications
for each row execute function public.track_application_applied_at();

create or replace function private.sync_application_dashboard_visibility()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  should_hide boolean;
begin
  should_hide := new.applied_at is null
    and (
      new.listing_state in ('closed','expired','removed','filled')
      or new.status = 'Closed'
      or coalesce(new.verification_status, '') ~* '(closed|expired|removed|filled|no longer available)'
    );

  if should_hide and not new.dashboard_hidden then
    update public.applications set dashboard_hidden = true where id = new.id;
  elsif not should_hide and new.dashboard_hidden then
    update public.applications set dashboard_hidden = false where id = new.id;
  end if;

  return new;
end;
$$;

revoke all on function private.sync_application_dashboard_visibility() from public, anon, authenticated;

drop trigger if exists applications_sync_dashboard_visibility_insert on public.applications;
create trigger applications_sync_dashboard_visibility_insert
after insert on public.applications
for each row execute function private.sync_application_dashboard_visibility();

drop trigger if exists applications_sync_dashboard_visibility_update on public.applications;
create trigger applications_sync_dashboard_visibility_update
after update of status, verification_status, applied_at, listing_state, application_state
on public.applications
for each row execute function private.sync_application_dashboard_visibility();

drop function if exists public.sync_application_dashboard_visibility();

create or replace function private.log_application_workflow_state_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if row(new.listing_state, new.decision_state, new.application_state, new.outreach_state)
     is distinct from
     row(old.listing_state, old.decision_state, old.application_state, old.outreach_state) then
    insert into public.application_activity(
      application_id, activity_type, detail, actor_email, source, payload
    ) values (
      new.id,
      'workflow_state_changed',
      'Workflow state updated',
      coalesce(auth.jwt() ->> 'email', current_user),
      'database_trigger',
      jsonb_build_object(
        'before', jsonb_build_object(
          'listing', old.listing_state,
          'decision', old.decision_state,
          'application', old.application_state,
          'outreach', old.outreach_state
        ),
        'after', jsonb_build_object(
          'listing', new.listing_state,
          'decision', new.decision_state,
          'application', new.application_state,
          'outreach', new.outreach_state
        )
      )
    );
  end if;
  return new;
end;
$$;

revoke all on function private.log_application_workflow_state_change() from public, anon, authenticated;

drop trigger if exists applications_workflow_activity on public.applications;
create trigger applications_workflow_activity
after update of listing_state, decision_state, application_state, outreach_state
on public.applications
for each row execute function private.log_application_workflow_state_change();

-- ---------------------------------------------------------------------------
-- RLS and grants. The public schema is exposed, so every new table is locked.
-- ---------------------------------------------------------------------------

alter table public.application_packages enable row level security;
alter table public.application_approvals enable row level security;
alter table public.submission_intents enable row level security;
alter table public.application_evidence enable row level security;
alter table public.candidate_truth_claims enable row level security;
alter table public.reconciliation_items enable row level security;
alter table public.application_communications enable row level security;

revoke all on table public.application_packages from anon, authenticated;
revoke all on table public.application_approvals from anon, authenticated;
revoke all on table public.submission_intents from anon, authenticated;
revoke all on table public.application_evidence from anon, authenticated;
revoke all on table public.candidate_truth_claims from anon, authenticated;
revoke all on table public.reconciliation_items from anon, authenticated;
revoke all on table public.application_communications from anon, authenticated;

grant select on table public.application_packages to authenticated;
grant select, insert on table public.application_approvals to authenticated;
grant update (approval_state, revoked_at) on table public.application_approvals to authenticated;
grant select on table public.submission_intents to authenticated;
grant select, insert on table public.application_evidence to authenticated;
grant select on table public.candidate_truth_claims to authenticated;
grant select on table public.reconciliation_items to authenticated;
grant select on table public.application_communications to authenticated;

grant all on table public.application_packages to service_role;
grant all on table public.application_approvals to service_role;
grant all on table public.submission_intents to service_role;
grant all on table public.application_evidence to service_role;
grant all on table public.candidate_truth_claims to service_role;
grant all on table public.reconciliation_items to service_role;
grant all on table public.application_communications to service_role;

-- Replace the legacy policies so exposed tables call only non-exposed helper
-- functions. View-all members remain read-only outside their own profile.
drop policy if exists applications_member_select on public.applications;
create policy applications_member_select
on public.applications for select to authenticated
using (
  private.can_view_cockpit_person(person)
  and dashboard_hidden = false
);

drop policy if exists applications_member_update on public.applications;
create policy applications_member_update
on public.applications for update to authenticated
using (private.can_edit_cockpit_person(person))
with check (private.can_edit_cockpit_person(person));

drop policy if exists activity_member_select on public.application_activity;
create policy activity_member_select
on public.application_activity for select to authenticated
using (exists (
  select 1 from public.applications a
  where a.id = application_activity.application_id
    and private.can_view_cockpit_person(a.person)
));

drop policy if exists activity_member_insert on public.application_activity;
create policy activity_member_insert
on public.application_activity for insert to authenticated
with check (exists (
  select 1 from public.applications a
  where a.id = application_activity.application_id
    and private.can_edit_cockpit_person(a.person)
));

drop policy if exists feedback_member_select on public.cockpit_feedback;
create policy feedback_member_select
on public.cockpit_feedback for select to authenticated
using (private.can_view_cockpit_person(person));

drop policy if exists resume_configs_member_select on public.cockpit_resume_configs;
create policy resume_configs_member_select
on public.cockpit_resume_configs for select to authenticated
using (private.can_view_cockpit_person(person));

drop policy if exists application_packages_member_select on public.application_packages;
create policy application_packages_member_select
on public.application_packages for select to authenticated
using (exists (
  select 1 from public.applications a
  where a.id = application_packages.application_id
    and private.can_view_cockpit_person(a.person)
));

drop policy if exists application_approvals_member_select on public.application_approvals;
create policy application_approvals_member_select
on public.application_approvals for select to authenticated
using (exists (
  select 1 from public.applications a
  where a.id = application_approvals.application_id
    and private.can_view_cockpit_person(a.person)
));

drop policy if exists application_approvals_member_insert on public.application_approvals;
create policy application_approvals_member_insert
on public.application_approvals for insert to authenticated
with check (
  lower(approved_by_email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
  and exists (
    select 1 from public.applications a
    where a.id = application_approvals.application_id
      and private.can_edit_cockpit_person(a.person)
  )
  and (
    package_id is null
    or exists (
      select 1 from public.application_packages p
      where p.id = application_approvals.package_id
        and p.application_id = application_approvals.application_id
        and (
          application_approvals.approval_type <> 'submit'
          or (
            p.package_state = 'ready'
            and p.finalized_at is not null
            and p.job_posting_hash = application_approvals.job_posting_hash
          )
        )
        and (
          application_approvals.package_hash is null
          or p.package_hash = application_approvals.package_hash
        )
    )
  )
);

drop policy if exists application_approvals_member_revoke on public.application_approvals;
create policy application_approvals_member_revoke
on public.application_approvals for update to authenticated
using (
  approval_state = 'approved'
  and lower(approved_by_email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
  and exists (
    select 1 from public.applications a
    where a.id = application_approvals.application_id
      and private.can_edit_cockpit_person(a.person)
  )
)
with check (
  approval_state = 'revoked'
  and lower(approved_by_email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
);

drop policy if exists submission_intents_member_select on public.submission_intents;
create policy submission_intents_member_select
on public.submission_intents for select to authenticated
using (exists (
  select 1 from public.applications a
  where a.id = submission_intents.application_id
    and private.can_view_cockpit_person(a.person)
));

drop policy if exists application_evidence_member_select on public.application_evidence;
create policy application_evidence_member_select
on public.application_evidence for select to authenticated
using (exists (
  select 1 from public.applications a
  where a.id = application_evidence.application_id
    and private.can_view_cockpit_person(a.person)
));

drop policy if exists application_evidence_member_insert on public.application_evidence;
create policy application_evidence_member_insert
on public.application_evidence for insert to authenticated
with check (
  lower(coalesce(created_by_email, '')) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
  and exists (
    select 1 from public.applications a
    where a.id = application_evidence.application_id
      and private.can_edit_cockpit_person(a.person)
  )
  and (
    package_id is null
    or exists (
      select 1 from public.application_packages p
      where p.id = application_evidence.package_id
        and p.application_id = application_evidence.application_id
    )
  )
  and (
    submission_intent_id is null
    or exists (
      select 1 from public.submission_intents si
      where si.id = application_evidence.submission_intent_id
        and si.application_id = application_evidence.application_id
    )
  )
);

drop policy if exists candidate_truth_claims_member_select on public.candidate_truth_claims;
create policy candidate_truth_claims_member_select
on public.candidate_truth_claims for select to authenticated
using (private.can_view_cockpit_person(person));

drop policy if exists reconciliation_items_member_select on public.reconciliation_items;
create policy reconciliation_items_member_select
on public.reconciliation_items for select to authenticated
using (private.can_view_cockpit_person(person));

drop policy if exists application_communications_member_select on public.application_communications;
create policy application_communications_member_select
on public.application_communications for select to authenticated
using (exists (
  select 1 from public.applications a
  where a.id = application_communications.application_id
    and private.can_view_cockpit_person(a.person)
));

-- Existing exposed-table privileges were broader than the UI needs.
revoke all on table public.cockpit_members from anon, authenticated;
grant select on table public.cockpit_members to authenticated;

revoke all on table public.cockpit_feedback from anon, authenticated;
grant select, insert on table public.cockpit_feedback to authenticated;

revoke all on table public.cockpit_resume_configs from anon, authenticated;
grant select on table public.cockpit_resume_configs to authenticated;

-- Scope the currently unused resume_assets table so future rows are private.
alter table public.resume_assets
  add column if not exists person text not null default 'Jakkie';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'resume_assets_person_check') then
    alter table public.resume_assets add constraint resume_assets_person_check
      check (person in ('Jakkie','Maryka'));
  end if;
end $$;

drop policy if exists resume_assets_member_select on public.resume_assets;
create policy resume_assets_member_select
on public.resume_assets for select to authenticated
using (private.can_view_cockpit_person(person));

revoke all on table public.resume_assets from anon, authenticated;
grant select on table public.resume_assets to authenticated;

-- Eliminate anonymous access to security-definer membership helpers. They
-- remain executable by authenticated users because RLS policies call them.
revoke all on function public.can_edit_cockpit_person(text) from public, anon, authenticated;
revoke all on function public.can_view_cockpit_person(text) from public, anon, authenticated;
revoke all on function public.is_cockpit_member() from public, anon, authenticated;
revoke all on function public.get_cockpit_member() from public, anon, authenticated;
grant execute on function public.can_edit_cockpit_person(text) to service_role;
grant execute on function public.can_view_cockpit_person(text) to service_role;
grant execute on function public.is_cockpit_member() to service_role;
grant execute on function public.get_cockpit_member() to service_role;

-- Use init-plan-friendly JWT access in policies that read it directly.
drop policy if exists members_self_select on public.cockpit_members;
create policy members_self_select
on public.cockpit_members for select to authenticated
using (
  lower(email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
  and active = true
);

drop policy if exists feedback_member_insert on public.cockpit_feedback;
create policy feedback_member_insert
on public.cockpit_feedback for insert to authenticated
with check (
  private.is_cockpit_member()
  and lower(author_email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
);

-- Recompute visibility from the new listing lane without discarding history.
update public.applications
set dashboard_hidden = (
  applied_at is null
  and listing_state in ('closed','expired','removed','filled')
);
