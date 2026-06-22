-- Patch sync_gantt_from_notion to preserve _overrides written by the frontend.
-- The original function did `set data = v_notion_source` which wiped _overrides.
-- This version reads the existing _overrides before the UPDATE and re-embeds them.

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
  v_overrides jsonb;          -- web-only overrides to preserve
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
  -- ── read existing overrides BEFORE we overwrite gantt_state ──────────────
  select data->'_overrides' into v_overrides
  from public.gantt_state
  where id = 1;

  -- ── Insert sync_log entry ─────────────────────────────────────────────────
  insert into public.sync_log (started_at, status) values (now(), 'running')
  returning id into v_log_id;

  -- ── Read config ───────────────────────────────────────────────────────────
  select value into v_db_id      from public.app_config where key = 'notion_database_id';
  select value into v_prop_date  from public.app_config where key = 'notion_prop_date';
  select value into v_prop_tag   from public.app_config where key = 'notion_prop_tag';
  select value into v_prop_parent from public.app_config where key = 'notion_prop_parent';
  select value into v_prop_assignee from public.app_config where key = 'notion_prop_assignee';
  select value into v_tag_landscape from public.app_config where key = 'notion_tag_landscape';
  select value into v_tag_project  from public.app_config where key = 'notion_tag_project';
  select value into v_default_role from public.app_config where key = 'default_role';
  select value into v_default_hire from public.app_config where key = 'default_hire_date';

  v_prop_date     := coalesce(v_prop_date,    'Date');
  v_prop_tag      := coalesce(v_prop_tag,     'Tag');
  v_prop_parent   := coalesce(v_prop_parent,  'Parent item');
  v_prop_assignee := coalesce(v_prop_assignee,'Assignee');
  v_tag_landscape := coalesce(v_tag_landscape,'Landscape');
  v_tag_project   := coalesce(v_tag_project,  'Ultimate(Proj)');
  v_default_role  := coalesce(v_default_role, '');
  v_default_hire  := coalesce(v_default_hire, '2024-01-01');

  -- ── Load existing gantt_state for color/role continuity ───────────────────
  select data into v_existing from public.gantt_state where id = 1;

  -- Re-use existing roles list if available
  if v_existing is not null and v_existing ? 'roles' then
    v_roles := v_existing->'roles';
  else
    v_roles := '[]'::jsonb;
  end if;

  -- ── Count cache entries ───────────────────────────────────────────────────
  select count(*) into v_cache_count from public.notion_page_cache;

  -- ── Build people & projects from cache ───────────────────────────────────
  for v_page in
    select
      page_id,
      attrs
    from public.notion_page_cache
    order by page_id
  loop
    v_props := v_page.attrs;

    -- ── Identify leaf nodes ──────────────────────────────────────────────────
    -- A leaf: has an Assignee, has a Date, has Ultimate(Proj) ancestor,
    --         is not itself a project/landscape node
    for v_leaf in
      with recursive
      page_map as (
        select page_id, attrs from public.notion_page_cache
      ),
      ancestry(page_id, attrs, root_id, depth) as (
        select p.page_id, p.attrs, p.page_id, 0 from page_map p
        union all
        select a.page_id, a.attrs, pm.page_id, a.depth + 1
        from ancestry a
        join page_map pm on pm.page_id = public.notion_uuid_dashed(
          a.attrs -> v_prop_parent -> 0 ->> 'id'
        )
        where a.depth < 10
      ),
      leaf_data as (
        select distinct on (p.page_id)
          p.page_id,
          p.attrs,
          bool_or(
            coalesce(anc.attrs -> v_prop_tag -> 'multi_select', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('name', v_tag_project))
          ) filter (where anc.page_id <> p.page_id) as has_ultimate_ancestor,
          (select attrs from page_map where page_id = public.notion_uuid_dashed(
            p.attrs -> v_prop_parent -> 0 ->> 'id'
          )) as parent_attrs,
          -- Get the project-tagged ancestor title
          (select anc2.attrs -> 'title' -> 0 ->> 'plain_text'
           from ancestry anc2
           where anc2.page_id = p.page_id
             and anc2.page_id <> p.page_id
             and coalesce(anc2.attrs -> v_prop_tag -> 'multi_select', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('name', v_tag_project))
           order by anc2.depth asc
           limit 1
          ) as project_title,
          -- Get the landscape-tagged ancestor title
          (select anc3.attrs -> 'title' -> 0 ->> 'plain_text'
           from ancestry anc3
           where anc3.page_id = p.page_id
             and anc3.page_id <> p.page_id
             and coalesce(anc3.attrs -> v_prop_tag -> 'multi_select', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('name', v_tag_landscape))
           order by anc3.depth asc
           limit 1
          ) as landscape_title,
          -- Get the project-tagged ancestor notion id
          (select anc4.page_id
           from ancestry anc4
           where anc4.page_id = p.page_id
             and anc4.page_id <> p.page_id
             and coalesce(anc4.attrs -> v_prop_tag -> 'multi_select', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('name', v_tag_project))
           order by anc4.depth asc
           limit 1
          ) as project_notion_id
        from page_map p
        left join ancestry anc on anc.page_id = p.page_id
        where
          -- has date
          p.attrs -> v_prop_date ->> 'start' is not null
          -- has assignee
          and jsonb_array_length(coalesce(p.attrs -> v_prop_assignee -> 'people', '[]'::jsonb)) > 0
          -- is not itself tagged as a project or landscape
          and not (coalesce(p.attrs -> v_prop_tag -> 'multi_select', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('name', v_tag_project)))
          and not (coalesce(p.attrs -> v_prop_tag -> 'multi_select', '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('name', v_tag_landscape)))
          -- has a parent
          and p.attrs -> v_prop_parent -> 0 ->> 'id' is not null
        group by p.page_id, p.attrs
      )
      select * from leaf_data
      where has_ultimate_ancestor
        and project_title is not null
        and page_id = v_page.page_id
    loop

      -- Project name = Ultimate(Proj) title only; Landscape kept separately (frontend badge).
      v_project_name := v_leaf.project_title;
      v_landscape_name := coalesce(v_leaf.landscape_title, '');
      v_project_notion_id := coalesce(v_leaf.project_notion_id, '');

      -- Assign or reuse project gantt id
      if v_project_map ? v_project_notion_id then
        v_project_gantt_id := v_project_map ->> v_project_notion_id;
      else
        v_project_gantt_id := 'proj-' || replace(gen_random_uuid()::text, '-', '');
        -- Reuse existing project id for same notion id
        if v_existing is not null then
          select p ->> 'id' into v_project_gantt_id
          from jsonb_array_elements(coalesce(v_existing -> 'projects', '[]'::jsonb)) p
          where coalesce(p ->> 'notionId', '') = v_project_notion_id
          limit 1;
          if v_project_gantt_id is null then
            v_project_gantt_id := 'proj-' || replace(gen_random_uuid()::text, '-', '');
          end if;
        end if;
        v_project_map := v_project_map || jsonb_build_object(v_project_notion_id, v_project_gantt_id);

        -- Lookup existing color or assign new
        declare
          v_existing_color text := null;
        begin
          if v_existing is not null then
            select p ->> 'color' into v_existing_color
            from jsonb_array_elements(coalesce(v_existing -> 'projects', '[]'::jsonb)) p
            where coalesce(p ->> 'notionId', '') = v_project_notion_id
            limit 1;
          end if;

          v_projects := v_projects || jsonb_build_array(jsonb_build_object(
            'id',         v_project_gantt_id,
            'notionId',   v_project_notion_id,
            'name',       v_project_name,
            'landscape',  v_landscape_name,
            'color',      coalesce(v_existing_color, v_project_colors[v_color_idx])
          ));
          if v_existing_color is null then
            v_color_idx := (v_color_idx % array_length(v_project_colors, 1)) + 1;
          end if;
        end;
      end if;

      -- ── Assignees → people ─────────────────────────────────────────────────
      v_assignee_ids := '[]'::jsonb;
      for v_assignee in
        select
          elem ->> 'id'   as notion_id,
          elem ->> 'name' as person_name
        from jsonb_array_elements(
          coalesce(v_leaf.attrs -> v_prop_assignee -> 'people', '[]'::jsonb)
        ) elem
      loop
        v_person_notion_id := public.notion_uuid_dashed(v_assignee.notion_id);
        v_person_name      := coalesce(v_assignee.person_name, 'Unknown');

        if v_person_map ? v_person_notion_id then
          v_person_gantt_id := v_person_map ->> v_person_notion_id;
        else
          -- Reuse existing person id
          v_person_gantt_id := null;
          if v_existing is not null then
            select p ->> 'id' into v_person_gantt_id
            from jsonb_array_elements(coalesce(v_existing -> 'people', '[]'::jsonb)) p
            where coalesce(p ->> 'notionId', '') = v_person_notion_id
            limit 1;
          end if;
          if v_person_gantt_id is null then
            v_person_gantt_id := 'person-' || replace(gen_random_uuid()::text, '-', '');
          end if;
          v_person_map := v_person_map || jsonb_build_object(v_person_notion_id, v_person_gantt_id);

          -- Look up existing person for role/hire continuity
          v_existing_person := null;
          if v_existing is not null then
            select p into v_existing_person
            from jsonb_array_elements(coalesce(v_existing -> 'people', '[]'::jsonb)) p
            where coalesce(p ->> 'notionId', '') = v_person_notion_id
            limit 1;
          end if;

          v_people := v_people || jsonb_build_array(jsonb_build_object(
            'id',        v_person_gantt_id,
            'notionId',  v_person_notion_id,
            'name',      v_person_name,
            'role',      coalesce(v_existing_person ->> 'role', v_default_role),
            'hireDate',  coalesce(v_existing_person ->> 'hireDate', v_default_hire),
            'leaveDate', coalesce(v_existing_person ->> 'leaveDate', '')
          ));
        end if;

        v_assignee_ids := v_assignee_ids || jsonb_build_array(v_person_gantt_id);
      end loop;

      -- ── Build task ────────────────────────────────────────────────────────
      v_task := jsonb_build_object(
        'id',         'task-' || replace(gen_random_uuid()::text, '-', ''),
        'name',       coalesce(v_leaf.attrs -> 'title' -> 0 ->> 'plain_text', '(無標題)'),
        'projectId',  v_project_gantt_id,
        'assignees',  v_assignee_ids,
        'start',      v_leaf.attrs -> v_prop_date ->> 'start',
        'end',        coalesce(
                        v_leaf.attrs -> v_prop_date ->> 'end',
                        v_leaf.attrs -> v_prop_date ->> 'start'
                      ),
        'wbs',        coalesce(v_leaf.attrs -> 'wbs' ->> 'formula', ''),
        'notionId',   v_leaf.page_id
      );
      v_tasks := v_tasks || jsonb_build_array(v_task);

      -- Track date range
      if v_min_date is null or (v_leaf.attrs -> v_prop_date ->> 'start')::date < v_min_date then
        v_min_date := (v_leaf.attrs -> v_prop_date ->> 'start')::date;
      end if;
      if v_max_date is null or coalesce(v_leaf.attrs -> v_prop_date ->> 'end', v_leaf.attrs -> v_prop_date ->> 'start')::date > v_max_date then
        v_max_date := coalesce(v_leaf.attrs -> v_prop_date ->> 'end', v_leaf.attrs -> v_prop_date ->> 'start')::date;
      end if;
    end loop;
  end loop;

  -- ── Compute timeline ───────────────────────────────────────────────────────
  if v_min_date is null then v_min_date := date_trunc('year', current_date)::date; end if;
  if v_max_date is null then v_max_date := (date_trunc('year', current_date) + interval '1 year' - interval '1 day')::date; end if;
  v_start_date := to_char(v_min_date - 30, 'YYYY-MM-DD');
  v_end_date   := to_char(v_max_date + 30, 'YYYY-MM-DD');

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

  -- ── Preserve web-only overrides ───────────────────────────────────────────
  -- Re-embed the _overrides that were read at the start of this function,
  -- so frontend customisations (roles, colors, task order) survive the sync.
  if v_overrides is not null then
    v_notion_source := v_notion_source || jsonb_build_object('_overrides', v_overrides);
  end if;

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
grant execute on function public.sync_gantt_from_notion() to anon, authenticated;
