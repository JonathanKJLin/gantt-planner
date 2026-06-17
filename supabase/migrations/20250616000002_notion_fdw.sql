-- Notion FDW: extensions, schema, foreign tables
-- Prerequisite: run supabase/manual/setup_notion_credentials.sql first (Vault + notion_server)

create extension if not exists wrappers with schema extensions;

do $$
begin
  if not exists (
    select 1 from pg_foreign_data_wrapper where fdwname = 'wasm_wrapper'
  ) then
    create foreign data wrapper wasm_wrapper
      handler extensions.wasm_fdw_handler
      validator extensions.wasm_fdw_validator;
  end if;
end $$;

create schema if not exists notion;

-- Foreign tables (require notion_server from manual setup)
create foreign table if not exists notion.pages (
  id text,
  url text,
  created_time timestamp,
  last_edited_time timestamp,
  archived boolean,
  attrs jsonb
)
server notion_server
options (object 'page');

create foreign table if not exists notion.users (
  id text,
  name text,
  type text,
  avatar_url text,
  attrs jsonb
)
server notion_server
options (object 'user');

create foreign table if not exists notion.databases (
  id text,
  url text,
  created_time timestamp,
  last_edited_time timestamp,
  archived boolean,
  attrs jsonb
)
server notion_server
options (object 'database');

grant usage on schema notion to postgres, service_role;
grant select on all tables in schema notion to postgres, service_role;
