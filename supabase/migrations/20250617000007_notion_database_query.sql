-- Notion Database Query API via synchronous http extension
-- (pg_net requires COMMIT, which fails with SECURITY DEFINER / SET / SQL Editor)

create extension if not exists http with schema extensions;

create table if not exists public.notion_page_cache (
  page_id   text primary key,
  url       text,
  attrs     jsonb not null,
  fetched_at timestamptz not null default now()
);

create or replace function public.notion_uuid_dashed(p_id text)
returns text
language plpgsql
immutable
as $$
declare
  s text := replace(coalesce(p_id, ''), '-', '');
begin
  if length(s) <> 32 then
    return p_id;
  end if;
  if p_id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-' then
    return lower(p_id);
  end if;
  return lower(
    substr(s, 1, 8) || '-' || substr(s, 9, 4) || '-' || substr(s, 13, 4)
    || '-' || substr(s, 17, 4) || '-' || substr(s, 21, 12)
  );
end;
$$;

-- From 004; required at CREATE time by notion_resolve_parent_id (SQL body validation)
create or replace function public.notion_parent_id(p_props jsonb, p_prop_name text)
returns text
language sql
immutable
as $$
  select replace(
    coalesce(
      p_props->p_prop_name->'relation'->0->>'id',
      (
        select rel->>'id'
        from jsonb_array_elements(coalesce(p_props->p_prop_name->'relation', '[]'::jsonb)) rel
        limit 1
      )
    ),
    '-', ''
  );
$$;

create or replace function public.notion_resolve_parent_id(
  p_attrs jsonb,
  p_props jsonb,
  p_prop_parent text
)
returns text
language sql
immutable
as $$
  select nullif(
    coalesce(
      nullif(public.notion_parent_id(p_props, p_prop_parent), ''),
      case
        when coalesce(p_attrs->'parent'->>'type', '') = 'page_id'
          then replace(coalesce(p_attrs->'parent'->>'page_id', ''), '-', '')
        else null
      end
    ),
    ''
  );
$$;

-- ── Self-contained helpers (from 003/004; ensure present even if earlier migrations skipped) ──
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

create or replace function public.notion_tag_name(p_prop jsonb)
returns text
language sql
immutable
as $$
  select coalesce(
    nullif(p_prop->'select'->>'name', ''),
    (
      select t->>'name'
      from jsonb_array_elements(coalesce(p_prop->'multi_select', '[]'::jsonb)) t
      limit 1
    )
  );
$$;

create or replace function public.notion_get_tag(p_props jsonb, p_prop_name text)
returns text
language sql
immutable
as $$
  select public.notion_tag_name(p_props->p_prop_name);
$$;

create or replace function public.notion_tag_is(p_props jsonb, p_prop_name text, p_expected text)
returns boolean
language sql
immutable
as $$
  select case coalesce(p_props->p_prop_name->>'type', '')
    when 'select' then lower(coalesce(p_props->p_prop_name->'select'->>'name', '')) = lower(p_expected)
    when 'multi_select' then exists (
      select 1
      from jsonb_array_elements(coalesce(p_props->p_prop_name->'multi_select', '[]'::jsonb)) t
      where lower(t->>'name') = lower(p_expected)
    )
    else false
  end;
$$;

create or replace function public.notion_person_slug(p_name text)
returns text
language sql
immutable
as $$
  select 'na_' || substr(md5(lower(trim(coalesce(p_name, '')))), 1, 12);
$$;

create or replace function public.notion_tag_matches(p_tag text, p_expected text)
returns boolean
language sql
immutable
as $$
  select coalesce(lower(trim(p_tag)), '') = lower(trim(p_expected));
$$;

create or replace function public.notion_extract_assignees(p_props jsonb, p_prop_name text)
returns table(display_name text, notion_user_id text)
language plpgsql
stable
set search_path = public, notion
as $$
declare
  v_prop jsonb;
  v_type text;
  v_person jsonb;
  v_item jsonb;
  v_rel_id text;
  v_name text;
begin
  v_prop := p_props->p_prop_name;
  if v_prop is null then
    if p_prop_name <> 'People' and p_props ? 'People' then
      return query select * from public.notion_extract_assignees(p_props, 'People');
    end if;
    return;
  end if;

  v_type := coalesce(v_prop->>'type', '');

  if v_type = 'people' then
    for v_person in select * from jsonb_array_elements(coalesce(v_prop->'people', '[]'::jsonb)) loop
      v_name := trim(coalesce(v_person->>'name', ''));
      if v_name <> '' then
        display_name := v_name;
        notion_user_id := v_person->>'id';
        return next;
      end if;
    end loop;
    return;
  end if;

  if v_type = 'select' then
    v_name := trim(coalesce(v_prop->'select'->>'name', ''));
    if v_name <> '' then
      display_name := v_name;
      notion_user_id := null;
      return next;
    end if;
    return;
  end if;

  if v_type = 'multi_select' then
    for v_item in select * from jsonb_array_elements(coalesce(v_prop->'multi_select', '[]'::jsonb)) loop
      v_name := trim(coalesce(v_item->>'name', ''));
      if v_name <> '' then
        display_name := v_name;
        notion_user_id := null;
        return next;
      end if;
    end loop;
    return;
  end if;

  if v_type = 'relation' then
    for v_rel_id in
      select replace(rel->>'id', '-', '')
      from jsonb_array_elements(coalesce(v_prop->'relation', '[]'::jsonb)) rel
    loop
      select coalesce(public.notion_page_title(c.attrs), 'Assignee')
      into v_name
      from public.notion_page_cache c
      where c.page_id = v_rel_id
      limit 1;

      if v_name is not null and trim(v_name) <> '' then
        display_name := trim(v_name);
        notion_user_id := v_rel_id;
        return next;
      end if;
    end loop;
    return;
  end if;

  if p_prop_name <> 'People' and p_props ? 'People' then
    return query select * from public.notion_extract_assignees(p_props, 'People');
  end if;
end;
$$;

-- Pull all database rows (incl. sub-items) into notion_page_cache
-- drop routine handles either prior procedure or function form
drop routine if exists public.notion_pull_database_pages();

create or replace function public.notion_pull_database_pages()
returns integer
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_db_id text;
  v_db_uuid text;
  v_token text;
  v_status int;
  v_content text;
  v_body jsonb;
  v_results jsonb;
  v_cursor text := null;
  v_page jsonb;
  v_count int := 0;
  v_post_body text;
begin
  perform set_config('http.timeout_msec', '30000', true);

  v_db_id := replace(public.notion_cfg('notion_database_id'), '-', '');
  v_db_uuid := public.notion_uuid_dashed(v_db_id);

  if v_db_id is null or v_db_id = '' or v_db_id = 'REPLACE_WITH_NOTION_DATABASE_ID' then
    raise exception 'sync_config.notion_database_id is not configured';
  end if;

  select decrypted_secret into v_token
  from vault.decrypted_secrets
  where name = 'notion'
  order by created_at desc
  limit 1;

  if v_token is null or v_token = '' then
    raise exception 'Notion token not found in vault (name=notion)';
  end if;

  -- "where true" required: API roles block unqualified DELETE (safeupdate)
  delete from public.notion_page_cache where true;

  loop
    v_post_body := case
      when v_cursor is null then '{}'
      else json_build_object('start_cursor', v_cursor)::text
    end;

    select r.status, r.content
    into v_status, v_content
    from extensions.http((
      'POST'::extensions.http_method,
      'https://api.notion.com/v1/databases/' || v_db_uuid || '/query',
      array[
        extensions.http_header('Authorization', 'Bearer ' || v_token),
        extensions.http_header('Notion-Version', '2022-06-28'),
        extensions.http_header('Content-Type', 'application/json')
      ]::extensions.http_header[],
      'application/json',
      v_post_body
    )::extensions.http_request) r;

    if v_status >= 400 then
      raise exception 'Notion API error %: %', v_status, v_content;
    end if;

    v_body := v_content::jsonb;
    v_results := coalesce(v_body->'results', '[]'::jsonb);

    for v_page in select value from jsonb_array_elements(v_results) loop
      if coalesce(v_page->>'archived', 'false') = 'true' then
        continue;
      end if;
      insert into public.notion_page_cache (page_id, url, attrs)
      values (
        replace(v_page->>'id', '-', ''),
        v_page->>'url',
        v_page
      )
      on conflict (page_id) do update set
        url = excluded.url,
        attrs = excluded.attrs,
        fetched_at = now();
      v_count := v_count + 1;
    end loop;

    exit when coalesce(v_body->>'has_more', 'false')::boolean = false;
    v_cursor := nullif(v_body->>'next_cursor', '');
    if v_cursor is null then
      exit;
    end if;
  end loop;

  return v_count;
end;
$$;

revoke all on function public.notion_pull_database_pages() from public;
grant execute on function public.notion_pull_database_pages() to service_role, postgres;

-- Run in SQL Editor:
--   SELECT public.notion_pull_database_pages();
--   SELECT public.sync_gantt_from_notion();

drop procedure if exists public.notion_sync_full();

-- Replace sync: read from notion_page_cache instead of FDW scan
create or replace function public.sync_gantt_from_notion()
returns jsonb
language plpgsql
security definer
set search_path = public, notion
as $$
declare
  v_log_id bigint;
  v_db_id text;
  v_prop_date text;
  v_prop_tag text;
  v_prop_parent text;
  v_prop_assignee text;
  v_tag_landscape text;
  v_tag_project text;
  v_default_role text;
  v_default_hire text;
  v_existing jsonb;
  v_roles jsonb;
  v_start_date text;
  v_end_date text;
  v_projects jsonb := '[]'::jsonb;
  v_people jsonb := '[]'::jsonb;
  v_tasks jsonb := '[]'::jsonb;
  v_project_map jsonb := '{}'::jsonb;
  v_person_map jsonb := '{}'::jsonb;
  v_project_colors text[] := array[
    '#3b82f6','#10b981','#f59e0b','#ef4444','#8b5cf6','#ec4899',
    '#06b6d4','#84cc16','#f97316','#6366f1','#14b8a6','#e11d48'
  ];
  v_color_idx integer := 1;
  v_page record;
  v_props jsonb;
  v_leaf record;
  v_person_name text;
  v_person_notion_id text;
  v_person_gantt_id text;
  v_existing_person jsonb;
  v_assignee_ids jsonb;
  v_project_gantt_id text;
  v_project_notion_id text;
  v_project_name text;
  v_landscape_name text;
  v_wbs_path text;
  v_task jsonb;
  v_min_date date;
  v_max_date date;
  v_notion_source jsonb;
  v_assignee record;
  v_cache_count int;
begin
  insert into public.sync_log (status) values ('running')
  returning id into v_log_id;

  v_db_id := replace(public.notion_cfg('notion_database_id'), '-', '');
  v_prop_date := public.notion_cfg('prop_date');
  v_prop_tag := coalesce(public.notion_cfg('prop_tag'), 'Tag');
  v_prop_parent := coalesce(public.notion_cfg('prop_parent'), 'Parent item');
  v_prop_assignee := coalesce(nullif(public.notion_cfg('prop_assignee'), ''), 'Assignee');
  v_tag_landscape := coalesce(public.notion_cfg('tag_landscape'), 'Landscape');
  v_tag_project := coalesce(public.notion_cfg('tag_project'), 'Ultimate(Proj)');
  v_default_role := public.notion_cfg('default_person_role');
  v_default_hire := public.notion_cfg('default_hire_date');

  if v_db_id is null or v_db_id = 'REPLACE_WITH_NOTION_DATABASE_ID' then
    raise exception 'sync_config.notion_database_id is not configured';
  end if;

  select count(*) into v_cache_count from public.notion_page_cache;
  if v_cache_count = 0 then
    raise exception 'notion_page_cache is empty — run: SELECT public.notion_pull_database_pages();';
  end if;

  select data into v_existing from public.gantt_state where id = 1;
  v_existing := coalesce(v_existing, '{}'::jsonb);
  v_roles := coalesce(v_existing->'roles', jsonb_build_array(
    jsonb_build_object('name', '正職', 'color', '#f59e0b'),
    jsonb_build_object('name', '實習生', 'color', '#9ca3af')
  ));
  v_start_date := v_existing->>'startDate';
  v_end_date := v_existing->>'endDate';

  create temp table _ni (
    page_id   text primary key,
    url       text,
    title     text not null,
    tag       text,
    parent_id text,
    date_start text,
    date_end   text,
    props     jsonb not null
  ) on commit drop;

  for v_page in select page_id, url, attrs from public.notion_page_cache loop
    v_props := coalesce(v_page.attrs->'properties', '{}'::jsonb);
    insert into _ni (page_id, url, title, tag, parent_id, date_start, date_end, props)
    values (
      v_page.page_id,
      v_page.url,
      coalesce(public.notion_page_title(v_page.attrs), 'Untitled'),
      public.notion_get_tag(v_props, v_prop_tag),
      public.notion_resolve_parent_id(v_page.attrs, v_props, v_prop_parent),
      public.notion_prop_date_start(v_props, v_prop_date),
      public.notion_prop_date_end(v_props, v_prop_date),
      v_props
    );
  end loop;

  create temp table _child_ids on commit drop as
  select distinct parent_id as page_id
  from _ni
  where parent_id is not null
  union
  select distinct replace(c.attrs->'parent'->>'page_id', '-', '') as page_id
  from public.notion_page_cache c
  where coalesce(c.attrs->'parent'->>'type', '') = 'page_id'
    and nullif(replace(c.attrs->'parent'->>'page_id', '-', ''), '') is not null;

  create temp table _leaves on commit drop as
  select n.*
  from _ni n
  where n.page_id not in (select page_id from _child_ids)
    and not public.notion_tag_is(
      n.props,
      coalesce(public.notion_cfg('prop_tag'), 'Tag'),
      coalesce(public.notion_cfg('tag_landscape'), 'Landscape')
    );

  create temp table _leaf_ctx on commit drop as
  with recursive chain as (
    select
      l.page_id as leaf_id,
      l.page_id as current_id,
      l.parent_id,
      l.title,
      l.tag,
      0 as depth
    from _leaves l
    union all
    select
      c.leaf_id,
      ni.page_id,
      ni.parent_id,
      ni.title,
      ni.tag,
      c.depth + 1
    from chain c
    join _ni ni on ni.page_id = c.parent_id
    where c.parent_id is not null
  ),
  project_pick as (
    select distinct on (leaf_id)
      leaf_id,
      current_id as project_page_id,
      title as project_title
    from chain
    where public.notion_tag_matches(tag, coalesce(public.notion_cfg('tag_project'), 'Ultimate(Proj)'))
    order by leaf_id, depth asc
  ),
  landscape_pick as (
    select distinct on (leaf_id)
      leaf_id,
      title as landscape_title
    from chain
    where public.notion_tag_matches(tag, coalesce(public.notion_cfg('tag_landscape'), 'Landscape'))
    order by leaf_id, depth desc
  ),
  path_build as (
    select
      c.leaf_id,
      string_agg(c.title, ' › ' order by c.depth desc) filter (
        where c.depth > 0
          and not public.notion_tag_matches(c.tag, coalesce(public.notion_cfg('tag_landscape'), 'Landscape'))
          and not public.notion_tag_matches(c.tag, coalesce(public.notion_cfg('tag_project'), 'Ultimate(Proj)'))
      ) as wbs_path
    from chain c
    group by c.leaf_id
  )
  select
    l.page_id,
    l.url,
    l.title,
    l.tag,
    l.parent_id,
    l.date_start,
    l.date_end,
    l.props,
    pp.project_page_id,
    pp.project_title,
    lp.landscape_title,
    pb.wbs_path
  from _leaves l
  left join project_pick pp on pp.leaf_id = l.page_id
  left join landscape_pick lp on lp.leaf_id = l.page_id
  left join path_build pb on pb.leaf_id = l.page_id;

  for v_leaf in
    select distinct project_page_id, project_title, landscape_title
    from _leaf_ctx
    where project_page_id is not null
  loop
    v_project_notion_id := v_leaf.project_page_id;
    if v_project_map ? v_project_notion_id then
      continue;
    end if;

    v_project_name := v_leaf.project_title;
    if v_leaf.landscape_title is not null and v_leaf.landscape_title <> v_project_name then
      v_project_name := v_leaf.landscape_title || ' · ' || v_project_name;
    end if;

    v_project_gantt_id := 'np_' || v_project_notion_id;
    v_project_map := v_project_map || jsonb_build_object(
      v_project_notion_id,
      jsonb_build_object(
        'id', v_project_gantt_id,
        'name', v_project_name,
        'color', v_project_colors[1 + ((v_color_idx - 1) % array_length(v_project_colors, 1))],
        'notionId', v_project_notion_id,
        'landscape', v_leaf.landscape_title
      )
    );
    v_color_idx := v_color_idx + 1;
  end loop;

  select coalesce(jsonb_agg(value order by value->>'name'), '[]'::jsonb)
  into v_projects
  from jsonb_each(v_project_map);

  if jsonb_array_length(v_projects) = 0 then
    v_projects := jsonb_build_array(jsonb_build_object(
      'id', 'np_unassigned',
      'name', '未分類專案',
      'color', '#6b7280',
      'notionId', null
    ));
    v_project_map := jsonb_build_object('unassigned', v_projects->0);
  end if;

  for v_leaf in select * from _leaf_ctx loop
    v_assignee_ids := '[]'::jsonb;
    v_project_gantt_id := null;

    if v_leaf.project_page_id is not null and v_project_map ? v_leaf.project_page_id then
      v_project_gantt_id := v_project_map->v_leaf.project_page_id->>'id';
    elsif v_project_map ? 'unassigned' then
      v_project_gantt_id := 'np_unassigned';
    elsif jsonb_array_length(v_projects) > 0 then
      v_project_gantt_id := v_projects->0->>'id';
    end if;

    v_wbs_path := nullif(trim(both ' › ' from coalesce(v_leaf.wbs_path, '')), '');

    for v_assignee in
      select * from public.notion_extract_assignees(v_leaf.props, v_prop_assignee)
    loop
      v_person_name := trim(v_assignee.display_name);
      if v_person_name = '' then
        continue;
      end if;

      v_person_notion_id := coalesce(
        nullif(replace(v_assignee.notion_user_id, '-', ''), ''),
        public.notion_person_slug(v_person_name)
      );

      if v_person_map ? v_person_notion_id then
        v_person_gantt_id := v_person_map->>v_person_notion_id;
      else
        v_person_gantt_id := case
          when v_assignee.notion_user_id is not null then 'nu_' || v_person_notion_id
          else public.notion_person_slug(v_person_name)
        end;

        v_existing_person := (
          select elem
          from jsonb_array_elements(coalesce(v_existing->'people', '[]'::jsonb)) elem
          where lower(trim(elem->>'name')) = lower(v_person_name)
             or replace(coalesce(elem->>'notionId', ''), '-', '') = v_person_notion_id
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

    v_task := jsonb_build_object(
      'id', 'nt_' || v_leaf.page_id,
      'notionId', v_leaf.page_id,
      'notionUrl', v_leaf.url,
      'name', v_leaf.title,
      'wbsPath', v_wbs_path,
      'notionTag', v_leaf.tag,
      'projectId', v_project_gantt_id,
      'assigneeIds', v_assignee_ids,
      'start', v_leaf.date_start,
      'end', v_leaf.date_end
    );
    v_tasks := v_tasks || jsonb_build_array(v_task);

    if v_leaf.date_start is not null then
      begin
        if v_min_date is null or v_leaf.date_start::date < v_min_date then
          v_min_date := v_leaf.date_start::date;
        end if;
      exception when others then null;
      end;
    end if;
    if v_leaf.date_end is not null then
      begin
        if v_max_date is null or v_leaf.date_end::date > v_max_date then
          v_max_date := v_leaf.date_end::date;
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
  if v_start_date is null then v_start_date := to_char(date_trunc('year', current_date)::date, 'YYYY-MM-DD'); end if;
  if v_end_date is null then v_end_date := to_char((date_trunc('year', current_date) + interval '1 year' - interval '1 day')::date, 'YYYY-MM-DD'); end if;

  v_notion_source := jsonb_build_object(
    'projects', v_projects,
    'people', v_people,
    'roles', v_roles,
    'tasks', v_tasks,
    'startDate', v_start_date,
    'endDate', v_end_date,
    'source', 'notion',
    'syncMode', 'wbs-leaves',
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
      people_count = jsonb_array_length(v_people),
      error_message = case
        when jsonb_array_length(v_tasks) = 0 then
          format('0 tasks from %s cached pages — check Tag/Parent/leaf rules', v_cache_count)
        else null
      end
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
grant execute on function public.sync_gantt_from_notion() to service_role, postgres;

grant select on public.notion_page_cache to postgres, service_role;
