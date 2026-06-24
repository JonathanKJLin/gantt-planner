-- Align sync_config with company Notion "Task Overview" database schema.
-- Property names discovered via Notion GET /v1/databases/{id} (2025-06).

update public.sync_config set value = 'Task Name'   where key = 'prop_title';
update public.sync_config set value = 'Parent-task' where key = 'prop_parent';
update public.sync_config set value = 'Tag'         where key = 'prop_tag';
update public.sync_config set value = 'Assignee'    where key = 'prop_assignee';

-- Verify:
-- select key, value from public.sync_config
-- where key in ('prop_title','prop_parent','prop_tag','prop_assignee','prop_date','pull_mode')
-- order by key;
