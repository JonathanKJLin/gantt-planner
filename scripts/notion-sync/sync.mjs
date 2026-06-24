// Incremental Notion -> Supabase sync worker.
//
// Strategy (stable regardless of database size):
//   1. Read checkpoint `last_edited_synced` from public.notion_sync_cursor.
//   2. Query the Notion database ordered by last_edited_time ASC, filtered to
//      rows edited on/after the checkpoint (no filter on first/full run).
//   3. Page through with cursors (100 rows/page), upserting each page into
//      public.notion_page_cache. Archived/trashed rows are deleted from cache.
//   4. Advance the checkpoint to the max last_edited_time ingested.
//   5. Call sync_gantt_from_notion() so gantt_state is rebuilt from the cache.
//
// First run pulls the whole database (one-time, runs fine in CI). Every run
// after that only fetches what changed -> tiny, fast, never times out.
//
// Env vars required:
//   SUPABASE_URL                 e.g. https://xxxx.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY    service_role key (bypasses RLS; CI secret only)
//   NOTION_TOKEN                 Notion internal integration secret (ntn_...)
// Optional:
//   NOTION_DATABASE_ID           overrides sync_config.notion_database_id
//   FULL_RESYNC=true             reset checkpoint and clear cache before syncing
//   NOTION_PAGE_SIZE             default 100
//   NOTION_VERSION               default 2022-06-28

import { createClient } from '@supabase/supabase-js';

const {
  SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY,
  NOTION_TOKEN,
  NOTION_DATABASE_ID,
  FULL_RESYNC,
  NOTION_PAGE_SIZE,
  NOTION_VERSION,
} = process.env;

const NOTION_TOKEN_CLEAN = String(NOTION_TOKEN || '').trim();
const PAGE_SIZE = Number(NOTION_PAGE_SIZE) || 100;
const API_VERSION = NOTION_VERSION || '2022-06-28';
const NOTION_API = 'https://api.notion.com/v1';
const RATE_LIMIT_DELAY_MS = 350; // ~3 req/s ceiling

function requireEnv(name, value) {
  if (!value || !String(value).trim()) {
    console.error(`Missing required env var: ${name}`);
    process.exit(1);
  }
}
requireEnv('SUPABASE_URL', SUPABASE_URL);
requireEnv('SUPABASE_SERVICE_ROLE_KEY', SUPABASE_SERVICE_ROLE_KEY);
requireEnv('NOTION_TOKEN', NOTION_TOKEN);

// Trim whitespace/newlines and any trailing slash — a trailing "/" produces
// "//rest/v1/..." which Supabase rejects with "Invalid path specified in request URL".
const SUPABASE_URL_CLEAN = String(SUPABASE_URL).trim().replace(/\/+$/, '');
const SERVICE_KEY_CLEAN = String(SUPABASE_SERVICE_ROLE_KEY).trim();

try {
  const u = new URL(SUPABASE_URL_CLEAN);
  console.log(`Supabase target: host=${u.host} path="${u.pathname}"`);
  if (!u.host.endsWith('.supabase.co') || (u.pathname && u.pathname !== '/')) {
    console.warn('⚠ SUPABASE_URL looks wrong. Expected exactly https://<project-ref>.supabase.co (no path).');
  }
} catch {
  console.error(`SUPABASE_URL is not a valid URL: "${SUPABASE_URL_CLEAN.slice(0, 60)}"`);
}

const sb = createClient(SUPABASE_URL_CLEAN, SERVICE_KEY_CLEAN, {
  auth: { persistSession: false },
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function dashUuid(id) {
  const s = String(id || '').replace(/-/g, '');
  if (s.length !== 32) return id;
  return [
    s.slice(0, 8), s.slice(8, 12), s.slice(12, 16), s.slice(16, 20), s.slice(20, 32),
  ].join('-').toLowerCase();
}

async function notionQuery(databaseUuid, body, attempt = 0) {
  const res = await fetch(`${NOTION_API}/databases/${databaseUuid}/query`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${NOTION_TOKEN_CLEAN}`,
      'Notion-Version': API_VERSION,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });

  if (res.status === 429) {
    const retryAfter = Number(res.headers.get('retry-after')) || 2;
    if (attempt >= 6) throw new Error('Notion rate limit: too many retries');
    console.warn(`429 rate limited; waiting ${retryAfter}s (retry ${attempt + 1})`);
    await sleep(retryAfter * 1000);
    return notionQuery(databaseUuid, body, attempt + 1);
  }

  if (res.status >= 500) {
    if (attempt >= 5) throw new Error(`Notion ${res.status} after retries`);
    const wait = 2 ** attempt;
    console.warn(`Notion ${res.status}; backoff ${wait}s (retry ${attempt + 1})`);
    await sleep(wait * 1000);
    return notionQuery(databaseUuid, body, attempt + 1);
  }

  const text = await res.text();
  if (res.status >= 400) {
    throw new Error(`Notion API error ${res.status}: ${text}`);
  }
  return JSON.parse(text);
}

async function getDatabaseId() {
  if (NOTION_DATABASE_ID && NOTION_DATABASE_ID.trim()) return NOTION_DATABASE_ID.trim();
  const { data, error } = await sb
    .from('sync_config')
    .select('value')
    .eq('key', 'notion_database_id')
    .single();
  if (error) throw new Error(`Cannot read sync_config.notion_database_id: ${error.message}`);
  if (!data?.value || data.value === 'REPLACE_WITH_NOTION_DATABASE_ID') {
    throw new Error('notion_database_id is not configured (sync_config or NOTION_DATABASE_ID env)');
  }
  return data.value;
}

async function readCheckpoint() {
  const { data, error } = await sb
    .from('notion_sync_cursor')
    .select('*')
    .eq('id', 1)
    .single();
  if (error) throw new Error(`Cannot read notion_sync_cursor: ${error.message}`);
  return data;
}

async function markRunning() {
  await sb.from('notion_sync_cursor')
    .update({ last_status: 'running', last_run_at: new Date().toISOString(), updated_at: new Date().toISOString() })
    .eq('id', 1);
}

async function upsertPages(rows) {
  if (rows.length === 0) return;
  const { error } = await sb
    .from('notion_page_cache')
    .upsert(rows, { onConflict: 'page_id' });
  if (error) throw new Error(`Cache upsert failed: ${error.message}`);
}

async function deletePages(ids) {
  if (ids.length === 0) return;
  const { error } = await sb.from('notion_page_cache').delete().in('page_id', ids);
  if (error) throw new Error(`Cache delete failed: ${error.message}`);
}

async function main() {
  const startedAt = Date.now();
  const databaseUuid = dashUuid(await getDatabaseId());
  let checkpoint = await readCheckpoint();

  let sinceIso = checkpoint.last_edited_synced;
  const fullResync = String(FULL_RESYNC || '').toLowerCase() === 'true' || !checkpoint.full_sync_done;

  if (String(FULL_RESYNC || '').toLowerCase() === 'true') {
    console.log('FULL_RESYNC=true -> clearing cache and checkpoint');
    const { error: delErr } = await sb.from('notion_page_cache').delete().neq('page_id', '');
    if (delErr) throw new Error(`Cache clear failed: ${delErr.message}`);
    sinceIso = null;
  } else if (!checkpoint.full_sync_done) {
    // Never completed a full sync yet: pull everything from scratch.
    sinceIso = null;
  }

  await markRunning();

  const baseBody = {
    page_size: PAGE_SIZE,
    sorts: [{ timestamp: 'last_edited_time', direction: 'ascending' }],
  };
  if (sinceIso) {
    baseBody.filter = {
      timestamp: 'last_edited_time',
      last_edited_time: { on_or_after: sinceIso },
    };
  }

  console.log(`Sync mode: ${sinceIso ? `incremental since ${sinceIso}` : 'FULL'}`);

  let cursor = null;
  let pageNum = 0;
  let upserted = 0;
  let deleted = 0;
  let maxEdited = sinceIso ? new Date(sinceIso).getTime() : 0;

  try {
    do {
      const body = { ...baseBody };
      if (cursor) body.start_cursor = cursor;

      const data = await notionQuery(databaseUuid, body);
      pageNum += 1;
      const results = data.results || [];

      const toUpsert = [];
      const toDelete = [];
      for (const page of results) {
        const pageId = String(page.id || '').replace(/-/g, '');
        const editedMs = new Date(page.last_edited_time || 0).getTime();
        if (editedMs > maxEdited) maxEdited = editedMs;

        if (page.archived || page.in_trash) {
          toDelete.push(pageId);
          continue;
        }
        toUpsert.push({
          page_id: pageId,
          url: page.url || null,
          attrs: page,
          fetched_at: new Date().toISOString(),
        });
      }

      await upsertPages(toUpsert);
      await deletePages(toDelete);
      upserted += toUpsert.length;
      deleted += toDelete.length;

      cursor = data.has_more ? data.next_cursor : null;
      console.log(`page ${pageNum}: +${toUpsert.length} upsert, -${toDelete.length} del (total ${upserted}/${deleted})`);

      if (cursor) await sleep(RATE_LIMIT_DELAY_MS);
    } while (cursor);

    // Rebuild gantt_state from the refreshed cache.
    console.log('Calling sync_gantt_from_notion()...');
    const { error: rpcErr } = await sb.rpc('sync_gantt_from_notion');
    if (rpcErr) throw new Error(`sync_gantt_from_notion failed: ${rpcErr.message}`);

    const newCheckpoint = maxEdited > 0 ? new Date(maxEdited).toISOString() : checkpoint.last_edited_synced;
    await sb.from('notion_sync_cursor').update({
      last_edited_synced: newCheckpoint,
      full_sync_done: true,
      last_status: 'ok',
      last_error: null,
      last_run_at: new Date().toISOString(),
      rows_upserted: (checkpoint.rows_upserted || 0) + upserted,
      rows_last_run: upserted,
      updated_at: new Date().toISOString(),
    }).eq('id', 1);

    const secs = ((Date.now() - startedAt) / 1000).toFixed(1);
    console.log(`Done in ${secs}s. upserted=${upserted} deleted=${deleted} checkpoint=${newCheckpoint}`);
  } catch (err) {
    await sb.from('notion_sync_cursor').update({
      last_status: 'error',
      last_error: String(err?.message || err),
      last_run_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    }).eq('id', 1);
    console.error('Sync failed:', err);
    process.exit(1);
  }
}

main();
