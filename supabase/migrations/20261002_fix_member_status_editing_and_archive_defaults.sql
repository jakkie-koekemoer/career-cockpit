-- Restore member-owned manual status changes while preserving evidence rules for automated actors.
-- Applied to production Career Supabase on 2026-10-02.

create or replace function private.guard_application_state_claims()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.application_state = 'submitting'
     and new.application_state is distinct from old.application_state
     and not exists (
       select 1
       from public.submission_intents si
       where si.application_id = new.id
         and si.intent_state = 'executing'
     ) then
    raise exception 'Submitting state requires an executing submission intent';
  end if;

  if new.application_state = 'submission_uncertain'
     and new.application_state is distinct from old.application_state
     and not exists (
       select 1
       from public.submission_intents si
       where si.application_id = new.id
         and si.intent_state = 'uncertain'
     ) then
    raise exception 'Uncertain state requires an uncertain submission intent';
  end if;

  -- Automated/external actors still need confirmed submission evidence before
  -- advancing an application. The owner may, however, manually assert their
  -- own real-world progress from the cockpit; those changes are marked as
  -- user_asserted instead of being blocked.
  if new.application_state in ('submitted','screen','interview','offer','accepted','declined_offer','rejected')
     and new.application_state is distinct from old.application_state
     and old.application_state not in ('submitted','screen','interview','offer','accepted','declined_offer','rejected')
     and not exists (
       select 1
       from public.submission_intents si
       where si.application_id = new.id
         and si.intent_state = 'confirmed'
     ) then
    if private.can_edit_cockpit_person(new.person) then
      new.data_confidence := 'user_asserted';
    else
      raise exception 'Confirmed application progress requires a confirmed submission intent';
    end if;
  end if;

  return new;
end;
$function$;
