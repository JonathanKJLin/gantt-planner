-- Align sync_config with actual Notion workspace (Tag / Assignee columns from screenshot)

update public.sync_config set value = 'Tag' where key = 'prop_tag';
update public.sync_config set value = 'Assignee' where key = 'prop_assignee';
update public.sync_config set value = 'Parent item' where key = 'prop_parent';
update public.sync_config set value = 'Date' where key = 'prop_date';

update public.sync_config set value = 'Landscape' where key = 'tag_landscape';
update public.sync_config set value = 'Ultimate(Proj)' where key = 'tag_project';
update public.sync_config set value = 'Parent' where key = 'tag_parent';
update public.sync_config set value = 'Task' where key = 'tag_task';

-- Case-insensitive match; Ultimate(Proj) / Ultimate(Project) / ultimate(proj) all match
create or replace function public.notion_tag_matches(p_tag text, p_expected text)
returns boolean
language sql
immutable
as $$
  select
    coalesce(lower(trim(p_tag)), '') = lower(trim(p_expected))
    or (
      lower(trim(coalesce(p_expected, ''))) like 'ultimate(%'
      and coalesce(lower(trim(p_tag)), '') like 'ultimate(%'
    );
$$;

create or replace function public.notion_tag_is(p_props jsonb, p_prop_name text, p_expected text)
returns boolean
language sql
immutable
as $$
  select case coalesce(p_props->p_prop_name->>'type', '')
    when 'select' then public.notion_tag_matches(p_props->p_prop_name->'select'->>'name', p_expected)
    when 'multi_select' then exists (
      select 1
      from jsonb_array_elements(coalesce(p_props->p_prop_name->'multi_select', '[]'::jsonb)) t
      where public.notion_tag_matches(t->>'name', p_expected)
    )
    else false
  end;
$$;
