-- Baseline schema for Resource Gantt Planner (document store + version history)

create table if not exists public.gantt_state (
  id         integer primary key default 1 check (id = 1),
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

insert into public.gantt_state (id, data)
values (1, '{}'::jsonb)
on conflict (id) do nothing;

create table if not exists public.gantt_history (
  id       bigint generated always as identity primary key,
  data     jsonb not null,
  label    text,
  saved_at timestamptz not null default now()
);

create index if not exists gantt_history_saved_at_idx
  on public.gantt_history (saved_at desc);

alter table public.gantt_state enable row level security;
alter table public.gantt_history enable row level security;

drop policy if exists "anon read gantt_state" on public.gantt_state;
create policy "anon read gantt_state"
  on public.gantt_state for select to anon, authenticated
  using (true);

drop policy if exists "anon update gantt_state" on public.gantt_state;
create policy "anon update gantt_state"
  on public.gantt_state for update to anon, authenticated
  using (true)
  with check (true);

drop policy if exists "anon read gantt_history" on public.gantt_history;
create policy "anon read gantt_history"
  on public.gantt_history for select to anon, authenticated
  using (true);

drop policy if exists "anon insert gantt_history" on public.gantt_history;
create policy "anon insert gantt_history"
  on public.gantt_history for insert to anon, authenticated
  with check (true);

drop policy if exists "anon delete gantt_history" on public.gantt_history;
create policy "anon delete gantt_history"
  on public.gantt_history for delete to anon, authenticated
  using (true);

-- Realtime (enable in dashboard if not already): publication supabase_realtime add table gantt_state;
