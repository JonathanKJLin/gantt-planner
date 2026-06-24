-- Allow the on-demand rebuild (frontend "立即同步", run as anon) to finish.
--
-- sync_gantt_from_notion() rebuilds gantt_state from the full notion_page_cache
-- (thousands of rows + recursive WBS chains). That can take longer than the
-- short per-role statement_timeout applied to anon/authenticated, producing
-- "canceling statement due to statement timeout". The GitHub Action worker runs
-- as service_role and is unaffected; this only raises the ceiling for this one
-- function so manual refreshes from the browser succeed too.

alter function public.sync_gantt_from_notion() set statement_timeout = '120s';
