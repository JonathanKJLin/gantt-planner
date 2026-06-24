-- Checkpoint table for incremental Notion sync (driven by an external GitHub Action worker).
--
-- The worker pulls Notion rows ordered by last_edited_time ascending and only fetches
-- rows changed since `last_edited_synced`. First run (null checkpoint) = full sync;
-- subsequent runs = small deltas. This is what keeps sync stable regardless of DB size.

create table if not exists public.notion_sync_cursor (
  id                 integer primary key default 1 check (id = 1),
  last_edited_synced timestamptz,            -- max last_edited_time successfully ingested
  full_sync_done     boolean not null default false,
  last_run_at        timestamptz,
  last_status        text,                   -- 'ok' | 'error' | 'running'
  last_error         text,
  rows_upserted      bigint not null default 0,  -- cumulative
  rows_last_run      integer,
  updated_at         timestamptz not null default now()
);

insert into public.notion_sync_cursor (id) values (1)
on conflict (id) do nothing;

alter table public.notion_sync_cursor enable row level security;

-- Frontend (anon) may read sync status to display "上次同步".
drop policy if exists "anon read notion_sync_cursor" on public.notion_sync_cursor;
create policy "anon read notion_sync_cursor"
  on public.notion_sync_cursor for select to anon, authenticated
  using (true);

grant select on public.notion_sync_cursor to anon, authenticated;
grant all on public.notion_sync_cursor to service_role, postgres;
