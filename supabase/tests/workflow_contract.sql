-- Read-only post-migration contract checks. Run against an isolated branch
-- after 20260920_safe_application_workflow.sql has been applied.

do $$
declare
  missing text;
begin
  select string_agg(required.name, ', ')
  into missing
  from (values
    ('application_packages'),
    ('application_approvals'),
    ('submission_intents'),
    ('application_evidence'),
    ('candidate_truth_claims'),
    ('reconciliation_items'),
    ('application_communications')
  ) as required(name)
  where to_regclass('public.' || required.name) is null;

  if missing is not null then
    raise exception 'Missing workflow tables: %', missing;
  end if;
end $$;

do $$
declare
  missing text;
begin
  select string_agg(required.name, ', ')
  into missing
  from (values
    ('listing_state'),
    ('decision_state'),
    ('application_state'),
    ('outreach_state'),
    ('next_action_owner'),
    ('due_at'),
    ('reconciliation_state'),
    ('data_confidence'),
    ('job_posting_hash'),
    ('dedupe_key'),
    ('workflow_version')
  ) as required(name)
  where not exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = 'applications'
      and c.column_name = required.name
  );

  if missing is not null then
    raise exception 'Missing application workflow columns: %', missing;
  end if;
end $$;

do $$
declare
  unsecured text;
begin
  select string_agg(c.relname, ', ')
  into unsecured
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in (
      'application_packages','application_approvals','submission_intents',
      'application_evidence','candidate_truth_claims','reconciliation_items',
      'application_communications'
    )
    and not c.relrowsecurity;

  if unsecured is not null then
    raise exception 'RLS is disabled on: %', unsecured;
  end if;
end $$;

do $$
begin
  if has_table_privilege('anon', 'public.application_packages', 'select')
     or has_table_privilege('anon', 'public.application_approvals', 'select')
     or has_table_privilege('anon', 'public.submission_intents', 'select') then
    raise exception 'Anonymous workflow-table access is broader than intended';
  end if;

  if has_function_privilege('anon', 'public.can_edit_cockpit_person(text)', 'execute')
     or has_function_privilege('anon', 'public.can_view_cockpit_person(text)', 'execute')
     or has_function_privilege('anon', 'public.is_cockpit_member()', 'execute')
     or has_function_privilege('anon', 'public.get_cockpit_member()', 'execute')
     or has_function_privilege('authenticated', 'public.can_edit_cockpit_person(text)', 'execute')
     or has_function_privilege('authenticated', 'public.can_view_cockpit_person(text)', 'execute')
     or has_function_privilege('authenticated', 'public.is_cockpit_member()', 'execute')
     or has_function_privilege('authenticated', 'public.get_cockpit_member()', 'execute') then
    raise exception 'Exposed membership-helper execution is still enabled';
  end if;

  if has_schema_privilege('anon', 'private', 'usage')
     or has_function_privilege('anon', 'private.can_edit_cockpit_person(text)', 'execute')
     or has_function_privilege('anon', 'private.can_view_cockpit_person(text)', 'execute')
     or has_function_privilege('anon', 'private.is_cockpit_member()', 'execute') then
    raise exception 'Anonymous access to private membership helpers is enabled';
  end if;

  if not has_schema_privilege('authenticated', 'private', 'usage')
     or not has_function_privilege('authenticated', 'private.can_edit_cockpit_person(text)', 'execute')
     or not has_function_privilege('authenticated', 'private.can_view_cockpit_person(text)', 'execute')
     or not has_function_privilege('authenticated', 'private.is_cockpit_member()', 'execute') then
    raise exception 'Authenticated policies cannot execute private membership helpers';
  end if;
end $$;

select 'Career Cockpit workflow contract: OK' as result;
