-- Fix member status editing and closed/unapplied dashboard visibility.
-- Applied to the Career Supabase project on 2026-08-30.

alter table public.applications
  add column if not exists applied_at timestamptz,
  add column if not exists dashboard_hidden boolean not null default false;

-- RLS policies already limit members to their own person. These grants allow
-- the browser client to perform the operations those policies permit.
grant update on table public.applications to authenticated;
grant insert on table public.application_activity to authenticated;

-- Preserve application history independently of the current status.
update public.applications
set applied_at = coalesce(applied_at, updated_at)
where applied_at is null
  and status in ('Applied','Recruiter screen','Interviewing','Offer','Waiting','Rejected');

create or replace function public.track_application_applied_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.applied_at is null
     and new.status in ('Applied','Recruiter screen','Interviewing','Offer','Waiting','Rejected') then
    new.applied_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists applications_track_applied_at on public.applications;
create trigger applications_track_applied_at
before insert or update of status on public.applications
for each row
execute function public.track_application_applied_at();

-- Hide closed/unavailable roles only when there is no evidence the member
-- applied. An AFTER trigger is used so changing a visible role to Closed still
-- succeeds under RLS; the row is hidden immediately afterwards.
create or replace function public.sync_application_dashboard_visibility()
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
      new.status = 'Closed'
      or coalesce(new.verification_status, '') ~* '(closed|expired|removed|filled|no longer available)'
    );

  if should_hide and not new.dashboard_hidden then
    update public.applications
       set dashboard_hidden = true
     where id = new.id;
  elsif not should_hide and new.dashboard_hidden then
    update public.applications
       set dashboard_hidden = false
     where id = new.id;
  end if;

  return new;
end;
$$;

revoke all on function public.sync_application_dashboard_visibility() from public, anon, authenticated;

drop trigger if exists applications_sync_dashboard_visibility_insert on public.applications;
create trigger applications_sync_dashboard_visibility_insert
after insert on public.applications
for each row
execute function public.sync_application_dashboard_visibility();

drop trigger if exists applications_sync_dashboard_visibility_update on public.applications;
create trigger applications_sync_dashboard_visibility_update
after update of status, verification_status, applied_at on public.applications
for each row
execute function public.sync_application_dashboard_visibility();

update public.applications
set dashboard_hidden = (
  applied_at is null
  and (
    status = 'Closed'
    or coalesce(verification_status, '') ~* '(closed|expired|removed|filled|no longer available)'
  )
);

-- Keep the ownership boundary in RLS, and remove rows that are intentionally
-- archived from the browser-visible dashboard.
drop policy if exists applications_member_select on public.applications;
create policy applications_member_select
on public.applications
for select
to authenticated
using (
  public.can_view_cockpit_person(person)
  and dashboard_hidden = false
);
