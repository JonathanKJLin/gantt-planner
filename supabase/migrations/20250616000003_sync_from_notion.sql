-- One-way Notion → gantt_state sync (scheduled via pg_cron)

-- ── Config (edit values after deploy) ──────────────────────────────────────
create table if not exists public.sync_config (
  key   text primary key,
  value text not null
);

insert into public.sync_config (key, value) values
  ('notion_database_id', 'REPLACE_WITH_NOTION_DATABASE_ID'),
  ('prop_title',         'Title'),
  ('prop_date',          'Date'),
  ('prop_people',        'People'),
  ('prop_project',       '專案'),
  ('default_person_role','正職'),
  ('default_hire_date',  '2026-01-01'),
  ('sync_interval_min',  '15')
on conflict (key) do nothing;

create table if not exists public.sync_log (
  id           bigint generated always as identity primary key,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  status       text not null default 'running',
  task_count   integer,
  project_count integer,
  people_count integer,
  error_message text
);

create or replace view public.gantt_sync_status as
select
  id,
  started_at  as last_sync_at,
  finished_at,
  status,
  task_count,
  project_count,
  people_count,
  error_message
from public.sync_log
order by id desc
limit 1;

grant select on public.sync_log to anon, authenticated;
grant select on public.gantt_sync_status to anon, authenticated;

-- ── Notion JSON helpers ─────────────────────────────────────────────────────
create or replace function public.notion_cfg(p_key text)
returns text
language sql
stable
as $$
  select value from public.sync_config where key = p_key;
$$;

create or replace function public.notion_page_title(p_attrs jsonb)
returns text
language sql
immutable
as $$
  select coalesce(
    (
      select elem->'title'->0->>'plain_text'
      from jsonb_each(coalesce(p_attrs->'properties', '{}'::jsonb)) as t(_k, elem)
      where elem->>'type' = 'title'
      limit 1
    ),
    'Untitled'
  );
$$;

create or replace function public.notion_prop_text(p_props jsonb, p_name text)
returns text
language sql
immutable
as $$
  select case coalesce(p_props->p_name->>'type', '')
    when 'title' then p_props->p_name->'title'->0->>'plain_text'
    when 'rich_text' then p_props->p_name->'rich_text'->0->>'plain_text'
    else null
  end;
$$;

create or replace function public.notion_prop_date_start(p_props jsonb, p_name text)
returns text
language sql
immutable
as $$
  select nullif(p_props->p_name->'date'->>'start', '');
$$;

create or replace function public.notion_prop_date_end(p_props jsonb, p_name text)
returns text
language sql
immutable
as $$
  select coalesce(
    nullif(p_props->p_name->'date'->>'end', ''),
    nullif(p_props->p_name->'date'->>'start', '')
  );
$$;

-- ── Main sync ───────────────────────────────────────────────────────────────
create or replace function public.sync_gantt_from_notion()
returns jsonb
language plpgsql
security definer
set search_path = public, notion
as $$
declare
  v_log_id bigint;
  v_db_id text;
  v_prop_title text;
  v_prop_date text;
  v_prop_people text;
  v_prop_project text;
  v_default_role text;
  v_default_hire text;
  v_existing jsonb;
  v_roles jsonb;
  v_start_date text;
  v_end_date text;
  v_projects jsonb := '[]'::jsonb;
  v_people jsonb := '[]'::jsonb;
  v_tasks jsonb := '[]'::jsonb;
  v_project_map jsonb := '{}'::jsonb; -- notion page id -> gantt project id
  v_person_map jsonb := '{}'::jsonb;  -- notion user id -> gantt person id
  v_project_colors text[] := array[
    '#3b82f6','#10b981','#f59e0b','#ef4444','#8b5cf6','#ec4899',
    '#06b6d4','#84cc16','#f97316','#6366f1','#14b8a6','#e11d48'
  ];
  v_color_idx integer := 1;
  v_page record;
  v_props jsonb;
  v_title text;
  v_date_start text;
  v_date_end text;
  v_proj_rel_id text;
  v_proj_page_id text;
  v_project_name text;
  v_project_gantt_id text;
  v_person jsonb;
  v_person_notion_id text;
  v_person_name text;
  v_person_gantt_id text;
  v_assignee_ids jsonb;
  v_task jsonb;
  v_min_date date;
  v_max_date date;
  v_existing_person jsonb;
  v_notion_source jsonb;
begin
  insert into public.sync_log (status) values ('running')
  returning id into v_log_id;

  v_db_id := replace(public.notion_cfg('notion_database_id'), '-', '');
  v_prop_title := public.notion_cfg('prop_title');
  v_prop_date := public.notion_cfg('prop_date');
  v_prop_people := public.notion_cfg('prop_people');
  v_prop_project := public.notion_cfg('prop_project');
  v_default_role := public.notion_cfg('default_person_role');
  v_default_hire := public.notion_cfg('default_hire_date');

  if v_db_id is null or v_db_id = 'REPLACE_WITH_NOTION_DATABASE_ID' then
    raise exception 'sync_config.notion_database_id is not configured';
  end if;

  select data into v_existing from public.gantt_state where id = 1;
  v_existing := coalesce(v_existing, '{}'::jsonb);

  v_roles := coalesce(v_existing->'roles', jsonb_build_array(
    jsonb_build_object('name', '正職', 'color', '#f59e0b'),
    jsonb_build_object('name', '實習生', 'color', '#9ca3af')
  ));
  v_start_date := v_existing->>'startDate';
  v_end_date := v_existing->>'endDate';

  -- Pass 1: collect project relation IDs from task pages
  for v_page in
    select p.id, p.attrs
    from notion.pages p
    where coalesce(p.archived, false) = false
      and replace(coalesce(p.attrs->'parent'->>'database_id', ''), '-', '') = v_db_id
  loop
    v_props := coalesce(v_page.attrs->'properties', '{}'::jsonb);
    for v_proj_rel_id in
      select replace(rel->>'id', '-', '')
      from jsonb_array_elements(coalesce(v_props->v_prop_project->'relation', '[]'::jsonb)) rel
    loop
      if v_project_map ? v_proj_rel_id then
        continue;
      end if;

      select public.notion_page_title(attrs), replace(id, '-', '')
      into v_project_name, v_proj_page_id
      from notion.pages
      where replace(id, '-', '') = v_proj_rel_id
      limit 1;

      v_project_gantt_id := 'np_' || v_proj_rel_id;
      v_project_map := v_project_map || jsonb_build_object(
        v_proj_rel_id,
        jsonb_build_object(
          'id', v_project_gantt_id,
          'name', coalesce(v_project_name, '專案'),
          'color', v_project_colors[1 + ((v_color_idx - 1) % array_length(v_project_colors, 1))],
          'notionId', v_proj_rel_id
        )
      );
      v_color_idx := v_color_idx + 1;
    end loop;
  end loop;

  -- Build projects array
  select coalesce(jsonb_agg(value order by value->>'name'), '[]'::jsonb)
  into v_projects
  from jsonb_each(v_project_map);

  -- Pass 2: people + tasks
  for v_page in
    select p.id, p.url, p.attrs
    from notion.pages p
    where coalesce(p.archived, false) = false
      and replace(coalesce(p.attrs->'parent'->>'database_id', ''), '-', '') = v_db_id
  loop
    v_props := coalesce(v_page.attrs->'properties', '{}'::jsonb);
    v_title := coalesce(
      public.notion_prop_text(v_props, v_prop_title),
      public.notion_page_title(v_page.attrs)
    );
    v_date_start := public.notion_prop_date_start(v_props, v_prop_date);
    v_date_end := public.notion_prop_date_end(v_props, v_prop_date);
    v_assignee_ids := '[]'::jsonb;

    for v_person in
      select * from jsonb_array_elements(coalesce(v_props->v_prop_people->'people', '[]'::jsonb))
    loop
      v_person_notion_id := replace(v_person->>'id', '-', '');
      v_person_name := coalesce(v_person->>'name', 'Unknown');

      if v_person_map ? v_person_notion_id then
        v_person_gantt_id := v_person_map->>v_person_notion_id;
      else
        v_person_gantt_id := 'nu_' || v_person_notion_id;

        v_existing_person := (
          select elem
          from jsonb_array_elements(coalesce(v_existing->'people', '[]'::jsonb)) elem
          where replace(coalesce(elem->>'notionId', ''), '-', '') = v_person_notion_id
             or elem->>'id' = v_person_gantt_id
          limit 1
        );

        v_person_map := v_person_map || jsonb_build_object(v_person_notion_id, v_person_gantt_id);
        v_people := v_people || jsonb_build_array(jsonb_build_object(
          'id', v_person_gantt_id,
          'name', coalesce(v_existing_person->>'name', v_person_name),
          'role', coalesce(v_existing_person->>'role', v_default_role),
          'hireDate', coalesce(v_existing_person->>'hireDate', v_default_hire),
          'leaveDate', v_existing_person->'leaveDate',
          'notionId', v_person_notion_id
        ));
      end if;

      v_assignee_ids := v_assignee_ids || to_jsonb(v_person_gantt_id);
    end loop;

    v_project_gantt_id := null;
    select replace(rel->>'id', '-', '')
    into v_proj_rel_id
    from jsonb_array_elements(coalesce(v_props->v_prop_project->'relation', '[]'::jsonb)) rel
    limit 1;

    if v_proj_rel_id is not null and v_project_map ? v_proj_rel_id then
      v_project_gantt_id := v_project_map->v_proj_rel_id->>'id';
    end if;

    if v_project_gantt_id is null and jsonb_array_length(v_projects) > 0 then
      v_project_gantt_id := v_projects->0->>'id';
    end if;

    v_task := jsonb_build_object(
      'id', 'nt_' || replace(v_page.id, '-', ''),
      'notionId', replace(v_page.id, '-', ''),
      'notionUrl', v_page.url,
      'name', v_title,
      'projectId', v_project_gantt_id,
      'assigneeIds', v_assignee_ids,
      'start', v_date_start,
      'end', v_date_end
    );
    v_tasks := v_tasks || jsonb_build_array(v_task);

    if v_date_start is not null then
      begin
        if v_min_date is null or v_date_start::date < v_min_date then
          v_min_date := v_date_start::date;
        end if;
      exception when others then null;
      end;
    end if;
    if v_date_end is not null then
      begin
        if v_max_date is null or v_date_end::date > v_max_date then
          v_max_date := v_date_end::date;
        end if;
      exception when others then null;
      end;
    end if;
  end loop;

  if v_start_date is null and v_min_date is not null then
    v_start_date := to_char(date_trunc('month', v_min_date)::date, 'YYYY-MM-DD');
  end if;
  if v_end_date is null and v_max_date is not null then
    v_end_date := to_char((date_trunc('month', v_max_date) + interval '1 month' - interval '1 day')::date, 'YYYY-MM-DD');
  end if;
  if v_start_date is null then v_start_date := '2026-01-01'; end if;
  if v_end_date is null then v_end_date := '2026-12-31'; end if;

  v_notion_source := jsonb_build_object(
    'projects', v_projects,
    'people', v_people,
    'roles', v_roles,
    'tasks', v_tasks,
    'startDate', v_start_date,
    'endDate', v_end_date,
    'source', 'notion',
    'lastNotionSync', now()
  );

  update public.gantt_state
  set data = v_notion_source,
      updated_at = now()
  where id = 1;

  update public.sync_log
  set finished_at = now(),
      status = 'ok',
      task_count = jsonb_array_length(v_tasks),
      project_count = jsonb_array_length(v_projects),
      people_count = jsonb_array_length(v_people)
  where id = v_log_id;

  return v_notion_source;

exception when others then
  update public.sync_log
  set finished_at = now(),
      status = 'error',
      error_message = sqlerrm
  where id = v_log_id;
  raise;
end;
$$;

revoke all on function public.sync_gantt_from_notion() from public;
grant execute on function public.sync_gantt_from_notion() to service_role;

-- ── Scheduled sync (pg_cron — enable extension in Supabase dashboard first) ─
create extension if not exists pg_cron with schema pg_catalog;

do $$
declare
  v_job_name constant text := 'sync-gantt-from-notion';
  v_interval text;
  v_schedule text;
begin
  select coalesce(public.notion_cfg('sync_interval_min'), '15') into v_interval;
  v_schedule := '*/' || v_interval || ' * * * *';

  if exists (select 1 from cron.job where jobname = v_job_name) then
    perform cron.unschedule(v_job_name);
  end if;

  perform cron.schedule(
    v_job_name,
    v_schedule,
    $cron$select public.sync_gantt_from_notion();$cron$
  );
exception
  when undefined_table then
    raise notice 'pg_cron not available — run sync_gantt_from_notion() manually or via Edge Function cron';
  when others then
    raise notice 'Could not schedule pg_cron job: %', sqlerrm;
end $$;
