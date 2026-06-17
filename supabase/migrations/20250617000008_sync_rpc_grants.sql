-- Allow the frontend (anon key) to trigger Notion sync via the "立即同步" button.
-- Both functions are SECURITY DEFINER: the Notion token stays in vault and is never
-- exposed to the client. anon can only invoke the pull + sync, not read the secret.

grant execute on function public.notion_pull_database_pages() to anon, authenticated;
grant execute on function public.sync_gantt_from_notion() to anon, authenticated;
