-- Pull by "Ultimate Parent" formula instead of BFS.
--
-- The company Notion database is too large for full pulls, and BFS via
-- Parent-task expands too many intermediate nodes. Since "Ultimate Parent" is
-- a formula, we use Notion's formula string filter:
--
--   Ultimate Parent formula string contains '<root title>'
--
-- This function performs exactly ONE Notion HTTP request per call. Call it
-- repeatedly until status = 'done'. The frontend "立即同步" loop already does
-- this automatically.

insert into public.sync_config (key, value) values
  ('prop_ultimate_parent', 'Ultimate Parent')
on conflict (key) do update set value = excluded.value;

create table if not exists public.notion_pull_progress (
  root_title        text primary key,
  root_page_id      text not null,
  strategy          text not null default 'ultimate_parent_formula',
  next_cursor       text,
  bfs_queue         jsonb not null default '[]'::jsonb,
  bfs_active_parent text,
  done              boolean not null default false,
  pages_fetched     int not null default 0,
  updated_at        timestamptz not null default now()
);

create table if not exists public.notion_pull_seen (
  root_title text not null,
  page_id    text not null,
  primary key (root_title, page_id)
);

create or replace function public.notion_pull_step(
  p_root_title text,
  p_reset boolean default false,
  p_clear_cache boolean default false
)
returns jsonb
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
  v_post_body text;
  v_body_obj jsonb;
  v_prop_title text;
  v_prop_ultimate text;
  v_root_page_id text;
  v_filter jsonb;
  v_page jsonb;
  v_page_id text;
  v_added int := 0;
  v_new_rows int;
  v_prog record;
begin
  perform set_config('http.timeout_msec', '120000', true);

  if p_root_title is null or trim(p_root_title) = '' then
    raise exception 'p_root_title is required';
  end if;

  v_db_id := replace(public.notion_cfg('notion_database_id'), '-', '');
  v_db_uuid := public.notion_uuid_dashed(v_db_id);
  v_prop_title := coalesce(nullif(trim(public.notion_cfg('prop_title')), ''), 'Task Name');
  v_prop_ultimate := coalesce(nullif(trim(public.notion_cfg('prop_ultimate_parent')), ''), 'Ultimate Parent');

  if v_db_id is null or v_db_id = '' then
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

  if p_clear_cache then
    delete from public.notion_page_cache where true;
    delete from public.notion_pull_progress where true;
    delete from public.notion_pull_seen where true;
  end if;

  -- Reset/init: find and cache the root row itself by exact Task Name.
  if p_reset then
    delete from public.notion_pull_progress where root_title = trim(p_root_title);
    delete from public.notion_pull_seen where root_title = trim(p_root_title);

    v_filter := jsonb_build_object(
      'property', v_prop_title,
      'title', jsonb_build_object('equals', trim(p_root_title))
    );
    v_body_obj := jsonb_build_object('filter', v_filter, 'page_size', 1);

    select r.status, r.content into v_status, v_content
    from extensions.http((
      'POST'::extensions.http_method,
      'https://api.notion.com/v1/databases/' || v_db_uuid || '/query',
      array[
        extensions.http_header('Authorization', 'Bearer ' || v_token),
        extensions.http_header('Notion-Version', '2022-06-28'),
        extensions.http_header('Content-Type', 'application/json')
      ]::extensions.http_header[],
      'application/json',
      v_body_obj::text
    )::extensions.http_request) r;

    if v_status >= 400 then
      raise exception 'Notion API error % (find root "%", prop_title=%): %',
        v_status, p_root_title, v_prop_title, v_content;
    end if;

    v_body := v_content::jsonb;
    v_results := coalesce(v_body->'results', '[]'::jsonb);
    if jsonb_array_length(v_results) = 0 then
      raise exception 'Root not found: "%" (prop_title=%)', p_root_title, v_prop_title;
    end if;

    v_page := v_results->0;
    v_root_page_id := replace(v_page->>'id', '-', '');

    insert into public.notion_page_cache (page_id, url, attrs)
    values (v_root_page_id, v_page->>'url', v_page)
    on conflict (page_id) do update set
      url = excluded.url,
      attrs = excluded.attrs,
      fetched_at = now();

    insert into public.notion_pull_seen (root_title, page_id)
    values (trim(p_root_title), v_root_page_id)
    on conflict do nothing;

    insert into public.notion_pull_progress (
      root_title, root_page_id, strategy, next_cursor, done, pages_fetched
    ) values (
      trim(p_root_title), v_root_page_id, 'ultimate_parent_formula', null, false, 1
    );

    return jsonb_build_object(
      'status', 'continue',
      'root', p_root_title,
      'strategy', 'ultimate_parent_formula',
      'pages_added', 1,
      'pages_fetched', 1,
      'message', 'Root cached. Continue with p_reset=false.'
    );
  end if;

  select * into v_prog
  from public.notion_pull_progress
  where root_title = trim(p_root_title);

  if not found then
    raise exception 'No progress for "%". Call notion_pull_step(title, true, clear_cache) first.', p_root_title;
  end if;

  if v_prog.done then
    return jsonb_build_object(
      'status', 'done',
      'root', p_root_title,
      'strategy', v_prog.strategy,
      'pages_added', 0,
      'pages_fetched', v_prog.pages_fetched,
      'message', 'Already complete.'
    );
  end if;

  -- One page of results where Ultimate Parent formula contains this root title.
  -- This assumes the formula returns a string. If Notion reports a validation
  -- error here, change the formula to return plain text or use a Gantt Scope
  -- select/multi-select column instead.
  v_filter := jsonb_build_object(
    'property', v_prop_ultimate,
    'formula', jsonb_build_object(
      'string', jsonb_build_object('contains', trim(p_root_title))
    )
  );

  v_body_obj := jsonb_build_object('filter', v_filter, 'page_size', 50);
  if v_prog.next_cursor is not null then
    v_body_obj := v_body_obj || jsonb_build_object('start_cursor', v_prog.next_cursor);
  end if;
  v_post_body := v_body_obj::text;

  select r.status, r.content into v_status, v_content
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
    raise exception 'Notion API error % (Ultimate Parent formula filter, property=%): %',
      v_status, v_prop_ultimate, v_content;
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

    insert into public.notion_pull_seen (root_title, page_id)
    values (trim(p_root_title), v_page_id)
    on conflict do nothing;
    get diagnostics v_new_rows = row_count;

    -- Count unique additions for progress; duplicates can appear if the root
    -- formula includes the root page cached during reset.
    if v_new_rows > 0 then
      v_added := v_added + 1;
    end if;
  end loop;

  if coalesce(v_body->>'has_more', 'false')::boolean
     and nullif(v_body->>'next_cursor', '') is not null then
    update public.notion_pull_progress
    set next_cursor = v_body->>'next_cursor',
        pages_fetched = pages_fetched + v_added,
        updated_at = now()
    where root_title = trim(p_root_title);

    return jsonb_build_object(
      'status', 'continue',
      'root', p_root_title,
      'strategy', 'ultimate_parent_formula',
      'pages_added', v_added,
      'pages_fetched', v_prog.pages_fetched + v_added,
      'has_more', true
    );
  end if;

  update public.notion_pull_progress
  set next_cursor = null,
      done = true,
      pages_fetched = pages_fetched + v_added,
      updated_at = now()
  where root_title = trim(p_root_title);

  return jsonb_build_object(
    'status', 'done',
    'root', p_root_title,
    'strategy', 'ultimate_parent_formula',
    'pages_added', v_added,
    'pages_fetched', v_prog.pages_fetched + v_added
  );
end;
$$;

revoke all on function public.notion_pull_step(text, boolean, boolean) from public;
grant execute on function public.notion_pull_step(text, boolean, boolean) to service_role, postgres, anon, authenticated;

grant select, insert, update, delete on public.notion_pull_progress to service_role, postgres;
grant select, insert, update, delete on public.notion_pull_seen to service_role, postgres;

-- Keep the convenience wrapper as a single-step call for compatibility.
drop function if exists public.notion_pull_landscape_root(text, boolean);

create or replace function public.notion_pull_landscape_root(
  p_root_title text,
  p_clear_cache boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.notion_pull_progress where root_title = trim(p_root_title)
  ) then
    return public.notion_pull_step(p_root_title, true, p_clear_cache);
  end if;
  return public.notion_pull_step(p_root_title, false, false);
end;
$$;

grant execute on function public.notion_pull_landscape_root(text, boolean) to service_role, postgres, anon, authenticated;
