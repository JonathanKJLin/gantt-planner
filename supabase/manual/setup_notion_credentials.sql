-- Run once in Supabase SQL Editor BEFORE applying migration 20250616000002
--
-- 1. Create a Notion Internal Integration: https://www.notion.so/profile/integrations
-- 2. Copy the secret (starts with ntn_ or secret_)
-- 3. Share your task database with the integration (⋯ → Connections)
-- 4. Copy the database ID from the database URL:
--    https://www.notion.so/{workspace}/{DATABASE_ID}?v=...
--
-- Replace placeholders below, then run this entire script.

-- Store API key in Vault (returns key id — save it for the next step)
select vault.create_secret(
  '<YOUR_NOTION_INTEGRATION_SECRET>',
  'notion',
  'Notion API key for Gantt sync'
);

-- Create FDW server (paste the uuid from vault.create_secret result as api_key_id)
-- Note: omit "if not exists" — re-run only after dropping existing server
create server notion_server
  foreign data wrapper wasm_wrapper
  options (
    fdw_package_url 'https://github.com/supabase/wrappers/releases/download/wasm_notion_fdw_v0.2.0/notion_fdw.wasm',
    fdw_package_name 'supabase:notion-fdw',
    fdw_package_version '0.2.0',
    fdw_package_checksum '719910b65a049f1d9b82dc4f5f1466457582bec855e1e487d5c3cc1e6f986dc6',
    api_url 'https://api.notion.com/v1',
    api_key_id '<VAULT_KEY_UUID>'
  );

-- After migrations 002 + 003, configure the task database id:
-- update public.sync_config
-- set value = '<YOUR_NOTION_DATABASE_ID>'
-- where key = 'notion_database_id';

-- Test FDW (should return your task database metadata):
-- select id, url from notion.databases where id = '<YOUR_NOTION_DATABASE_ID>';

-- First manual sync:
-- select public.sync_gantt_from_notion();

-- Check sync status:
-- select * from public.gantt_sync_status;
