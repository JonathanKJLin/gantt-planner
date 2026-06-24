-- Pull one Landscape root subtree per invocation (separate SQL/RPC calls avoid cumulative timeouts).
-- Usage (run each line separately in SQL Editor):
--   select public.notion_pull_landscape_root('Go-to-Market', true);
--   select public.notion_pull_landscape_root('Sprint/Pipelines', false);
--   ... (remaining roots)
--   select public.sync_gantt_from_notion();

create or replace function public.notion_pull_landscape_root(
  p_root_title text,
  p_clear_cache boolean default false
)
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
  v_body_obj jsonb;
  v_prop_title text;
  v_prop_parent text;
  v_parent_id text;
  v_page_id text;
  v_filter jsonb;
  v_roots_found int;
  v_new_rows int;
begin
  perform set_config('http.timeout_msec', '180000', true);

  if p_root_title is null or trim(p_root_title) = '' then
    raise exception 'p_root_title is required';
  end if;

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

  v_prop_title := coalesce(nullif(trim(public.notion_cfg('prop_title')), ''), 'Task Name');
  v_prop_parent := coalesce(nullif(trim(public.notion_cfg('prop_parent')), ''), 'Parent-task');

  if p_clear_cache then
    delete from public.notion_page_cache where true;
  end if;

  create temp table _pull_queue (page_id text primary key) on commit drop;
  create temp table _pull_seen (page_id text primary key) on commit drop;

  -- Step 1: find this single root page by exact Task Name
  v_filter := jsonb_build_object(
    'property', v_prop_title,
    'title', jsonb_build_object('equals', trim(p_root_title))
  );

  v_cursor := null;
  loop
    v_body_obj := jsonb_build_object('filter', v_filter, 'page_size', 50);
    if v_cursor is not null then
      v_body_obj := v_body_obj || jsonb_build_object('start_cursor', v_cursor);
    end if;
    v_post_body := v_body_obj::text;

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
      raise exception 'Notion API error % (root %, prop_title=%): %',
        v_status, p_root_title, v_prop_title, v_content;
    end if;

    v_body := v_content::jsonb;
    v_results := coalesce(v_body->'results', '[]'::jsonb);

    for v_page in select value from jsonb_array_elements(v_results) loop
      if coalesce(v_page->>'archived', 'false') = 'true' then
        continue;
      end if;
      v_page_id := replace(v_page->>'id', '-', '');
      insert into public.notion_page_cache (page_id, url, attrs)
      values (v_page_id, v_page->>'url', v_page)
      on conflict (page_id) do update set
        url = excluded.url,
        attrs = excluded.attrs,
        fetched_at = now();
      v_count := v_count + 1;
      insert into _pull_seen (page_id) values (v_page_id) on conflict do nothing;
      insert into _pull_queue (page_id) values (v_page_id) on conflict do nothing;
    end loop;

    exit when coalesce(v_body->>'has_more', 'false')::boolean = false;
    v_cursor := nullif(v_body->>'next_cursor', '');
    if v_cursor is null then
      exit;
    end if;
  end loop;

  select count(*) into v_roots_found from _pull_seen;
  if v_roots_found = 0 then
    raise exception
      'Root not found: "%". Check prop_title (%) and exact spelling in Notion.',
      p_root_title, v_prop_title;
  end if;

  -- Step 2: BFS — fetch descendants via Parent-task relation
  while exists (select 1 from _pull_queue) loop
    select q.page_id into v_parent_id from _pull_queue q limit 1;
    delete from _pull_queue where page_id = v_parent_id;

    v_filter := jsonb_build_object(
      'property', v_prop_parent,
      'relation', jsonb_build_object('contains', public.notion_uuid_dashed(v_parent_id))
    );

    v_cursor := null;
    loop
      v_body_obj := jsonb_build_object('filter', v_filter, 'page_size', 50);
      if v_cursor is not null then
        v_body_obj := v_body_obj || jsonb_build_object('start_cursor', v_cursor);
      end if;
      v_post_body := v_body_obj::text;

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
        raise exception 'Notion API error % (child of % under "%", prop_parent=%): %',
          v_status, v_parent_id, p_root_title, v_prop_parent, v_content;
      end if;

      v_body := v_content::jsonb;
      v_results := coalesce(v_body->'results', '[]'::jsonb);

      for v_page in select value from jsonb_array_elements(v_results) loop
        if coalesce(v_page->>'archived', 'false') = 'true' then
          continue;
        end if;
        v_page_id := replace(v_page->>'id', '-', '');
        insert into public.notion_page_cache (page_id, url, attrs)
        values (v_page_id, v_page->>'url', v_page)
        on conflict (page_id) do update set
          url = excluded.url,
          attrs = excluded.attrs,
          fetched_at = now();
        v_count := v_count + 1;

        insert into _pull_seen (page_id) values (v_page_id) on conflict do nothing;
        get diagnostics v_new_rows = row_count;
        if v_new_rows > 0 then
          insert into _pull_queue (page_id) values (v_page_id) on conflict do nothing;
        end if;
      end loop;

      exit when coalesce(v_body->>'has_more', 'false')::boolean = false;
      v_cursor := nullif(v_body->>'next_cursor', '');
      if v_cursor is null then
        exit;
      end if;
    end loop;
  end loop;

  return v_count;
end;
$$;

-- Legacy entry point: still tries all roots in one call (may timeout on large DB).
-- Prefer notion_pull_landscape_root() per root from SQL Editor or frontend.
create or replace function public.notion_pull_database_pages()
returns integer
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_root text;
  v_roots jsonb;
  v_total int := 0;
  v_first boolean := true;
  v_n int;
begin
  v_roots := coalesce(nullif(trim(public.notion_cfg('pull_landscape_roots')), ''), '[]')::jsonb;

  if jsonb_array_length(v_roots) = 0 then
    raise exception 'pull_landscape_roots is empty — use notion_pull_landscape_root(title, clear) for each root';
  end if;

  for v_root in
    select jsonb_array_elements_text(v_roots)
  loop
    v_n := public.notion_pull_landscape_root(v_root, v_first);
    v_total := v_total + v_n;
    v_first := false;
  end loop;

  return v_total;
end;
$$;

revoke all on function public.notion_pull_landscape_root(text, boolean) from public;
grant execute on function public.notion_pull_landscape_root(text, boolean) to service_role, postgres, anon, authenticated;

revoke all on function public.notion_pull_database_pages() from public;
grant execute on function public.notion_pull_database_pages() to service_role, postgres, anon, authenticated;
