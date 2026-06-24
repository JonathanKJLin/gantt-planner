-- Reduce Notion pull volume: only fetch pages under configured Landscape root titles.
-- Avoids full-database query timeout on large workspaces.
--
-- sync_config:
--   pull_mode            = 'landscape_roots' | 'full'  (default landscape_roots)
--   pull_landscape_roots = JSON array of exact Title / Task Name strings
--   prop_title           = Notion title property name (e.g. 'Task Name')
--
-- After applying, tune titles to match your Notion database exactly:
--   update public.sync_config set value = 'Task Name' where key = 'prop_title';

insert into public.sync_config (key, value) values
  ('pull_mode', 'landscape_roots'),
  ('pull_landscape_roots', '[
    "Go-to-Market",
    "Sprint/Pipelines",
    "Projects - Mtel2",
    "Projects - On-going ( BIA & DMG )",
    "Projects - On-going ( AiLab & RA )"
  ]'),
  ('prop_title', 'Task Name')
on conflict (key) do update set value = excluded.value
where public.sync_config.value is distinct from excluded.value;

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
  v_body_obj jsonb;
  v_pull_mode text;
  v_root_titles jsonb;
  v_prop_title text;
  v_prop_parent text;
  v_parent_id text;
  v_page_id text;
  v_filter jsonb;
  v_roots_found int;
  v_new_rows int;
begin
  -- 2 min per HTTP call (large pages still paginate at 100 rows)
  perform set_config('http.timeout_msec', '120000', true);

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

  v_pull_mode := coalesce(nullif(trim(public.notion_cfg('pull_mode')), ''), 'landscape_roots');
  v_root_titles := coalesce(nullif(trim(public.notion_cfg('pull_landscape_roots')), ''), '[]')::jsonb;
  v_prop_title := coalesce(nullif(trim(public.notion_cfg('prop_title')), ''), 'Title');
  v_prop_parent := coalesce(nullif(trim(public.notion_cfg('prop_parent')), ''), 'Parent-task');

  delete from public.notion_page_cache where true;

  -- ── Full pull (legacy; may timeout on very large databases) ───────────────
  if v_pull_mode = 'full' or jsonb_array_length(v_root_titles) = 0 then
    loop
      v_body_obj := '{}'::jsonb;
      if v_cursor is not null then
        v_body_obj := jsonb_build_object('start_cursor', v_cursor);
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
  end if;

  -- ── Landscape-root subtree pull (BFS by Parent item) ───────────────────────
  create temp table _pull_queue (page_id text primary key) on commit drop;
  create temp table _pull_seen (page_id text primary key) on commit drop;

  -- Step 1: find root pages by exact title match (OR filter)
  v_filter := jsonb_build_object(
    'or',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'property', v_prop_title,
          'title', jsonb_build_object('equals', t)
        )
      )
      from jsonb_array_elements_text(v_root_titles) t
    ), '[]'::jsonb)
  );

  v_cursor := null;
  loop
    v_body_obj := jsonb_build_object('filter', v_filter);
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
      raise exception 'Notion API error % (root lookup): %', v_status, v_content;
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
      'No root pages matched pull_landscape_roots. Check prop_title (%) and title spellings in sync_config.',
      v_prop_title;
  end if;

  -- Step 2: BFS — for each seen parent, fetch direct children via Parent item relation
  while exists (select 1 from _pull_queue) loop
    select q.page_id into v_parent_id from _pull_queue q limit 1;
    delete from _pull_queue where page_id = v_parent_id;

    v_filter := jsonb_build_object(
      'property', v_prop_parent,
      'relation', jsonb_build_object('contains', public.notion_uuid_dashed(v_parent_id))
    );

    v_cursor := null;
    loop
      v_body_obj := jsonb_build_object('filter', v_filter);
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
        raise exception 'Notion API error % (child of %): %', v_status, v_parent_id, v_content;
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

revoke all on function public.notion_pull_database_pages() from public;
grant execute on function public.notion_pull_database_pages() to service_role, postgres, anon, authenticated;
