create table if not exists public.applications (
  id text primary key,
  company text not null,
  role text not null,
  fit numeric(3,1),
  priority integer,
  status text not null default 'Researching',
  location text,
  compensation text,
  salary_ask text,
  application_url text,
  contact_name text,
  contact_url text,
  contact_note text,
  outreach_time text,
  outreach_message text,
  next_action text,
  gaps text,
  prep text,
  notes text default '',
  resume_url text,
  resume_alt_url text,
  updated_at timestamptz not null default now()
);

create table if not exists public.application_activity (
  id bigint generated always as identity primary key,
  application_id text not null references public.applications(id) on delete cascade,
  happened_at timestamptz not null default now(),
  activity_type text not null,
  detail text not null
);

alter table public.applications enable row level security;
alter table public.application_activity enable row level security;

create index if not exists application_activity_application_id_idx
  on public.application_activity(application_id, happened_at desc);
