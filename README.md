# Resource Gantt Planner — 多專案人力排程工具

解決多專案同時進行時的人天安排困擾

**Live Site**: [https://jonathankjlin.github.io/gantt-planner/](https://jonathankjlin.github.io/gantt-planner/)

---

## 架構（Notion 版）

```
Notion 任務資料庫 (Title / Date / Assignee / Tag / Parent-task)
        ↓  GitHub Action worker（scripts/notion-sync）— 依 last_edited_time 增量分頁拉取
   notion_page_cache (原始頁面 JSON 快取)
        ↓  sync_gantt_from_notion() — 解析 WBS、單向
   gantt_state (JSON)
        ↓  Realtime / 重新載入
   index.html 甘特圖（唯讀）
```

- **任務維護**：團隊在 Notion 編輯
- **甘特圖**：自動反映 Notion 資料，此頁面不提供回寫
- **同步方式**：**GitHub Action 每 15 分鐘自動增量同步**（拉取 → 快取 → 重建 gantt_state）。前端「立即同步」按鈕只重建 + 重新載入，不直接打 Notion API。

### 為什麼用 GitHub Action 增量同步？

過去在 Supabase SQL function 內用 `http` extension 直接分頁拉 Notion，資料量一大就會 `HTTP request cancelled`（SQL 有執行時間上限、無法好好處理分頁／限速／續傳）。改為外部 worker 後：

- **增量同步**：依 `last_edited_time` 只拉「上次同步後變動」的列。第一次全量（一次性），之後每次只有少量 delta → 不論資料庫多大都不會崩。
- **不動 Notion schema**：沿用既有 `Parent-task` 階層與 `Ultimate Parent`，不新增 select/multi-select，避免影響既有 automation。
- **穩定**：worker 可正確分頁、處理 429 限速、失敗重試、用 checkpoint 續傳，不受 SQL timeout 限制。

---

## 功能一覽

### 甘特圖

- **三種檢視**：日 / 週 / 月，隨時切換
- **凍結窗格**：捲動時人名和日期標頭固定不動
- **多人負責**：一個任務可指派多位負責人，會出現在每個人的時間軸上
- **重疊偵測**：同一人同時超過 3 個任務時，自動標紅框 + 斜紋底色

### 專案總覽

- 每個專案的任務明細表（負責人、日期、天數）
- 人員參與度長條圖（每人投入幾天、佔比多少）
- 跨專案人力分配矩陣（人 × 專案 的天數交叉表）

### Notion 同步

- 使用 Notion 既有欄位：**Title**、**Date**、**Assignee**、**Tag**、**Parent-task**（sub-items）
- **GitHub Action worker** 依 `last_edited_time` 增量抓進 `notion_page_cache`（見 `scripts/notion-sync`）
- 解析 WBS 後同步至 `gantt_state`，前端透過 Realtime / 重新載入更新
- 前端 banner 的「**立即同步**」按鈕會重建 gantt_state 並重新載入（拉取交給 worker）
- 甘特圖**唯讀**；編輯請回 Notion

### 匯出

- **JSON**：完整資料備份（唯讀模式下仍可匯出）

### 即時同步

- 透過 Supabase 即時同步，多人打開同一網址看到同一份資料
- 點「立即同步」完成後，頁面即更新；其他開著的頁面透過 Realtime 自動更新
- 離線時自動 fallback 到本地快取

---

## Notion 任務階層

同一個 Notion database 內以 **Parent item** 串起 5 層結構：


| 層級  | Tag              | 範例                                          | 甘特圖            |
| --- | ---------------- | ------------------------------------------- | -------------- |
| 1   | `Landscape`      | go-to-market、project - on-going (manager 1) | 不顯示（僅分類）       |
| 2   | `Ultimate(Proj)` | 統一超商股份有限公司                                  | → **專案**（顏色圖例） |
| 3   | `Parent`         | Phase 1 ~ cooking & identifying             | 若無子項 → 可顯示     |
| 4   | `Parent`         | Prospecting & Preparation                   | 若無子項 → 可顯示     |
| 5   | `Task`           | 確認範疇和客戶起案意願…                                | 可顯示            |


**同步規則（leaf）：** 只匯入「沒有更下層 sub-item」的節點——不論 tag 是 `Parent` 或 `Task`，只要沒有人把它當 parent，就會出現在甘特圖。

**負責人：** `Assignee` 欄位（支援 People / Select / Multi-select）→ 甘特圖橫軸人員。

**WBS 路徑：** 同步後 task 帶 `wbsPath`（例：`Phase 1 › Prospecting & Preparation`），hover 任務條可見。

### sync_config 欄位


| key                  | 預設值            | 說明                                   |
| -------------------- | -------------- | ------------------------------------ |
| `notion_database_id` | （必填）           | 任務 database ID                       |
| `prop_tag`           | Tag            | 階層 tag 欄位                            |
| `prop_parent`        | Parent item    | 指向父項目的 relation                      |
| `prop_assignee`      | Assignee       | 負責人                                  |
| `prop_date`          | Date           | 起迄日期                                 |
| `tag_landscape`      | Landscape      | 第 1 層 tag 值                          |
| `tag_project`        | Ultimate(Proj) | 第 2 層 → 甘特專案（`Ultimate(...)` 開頭皆可匹配） |
| `tag_parent`         | Parent         | 中間層 tag                              |
| `tag_task`           | Task           | 最底層 tag                              |
| `gantt_landscape_allow` | `[5 個 landscape]` | **只顯示這些 Landscape**（本地端篩選；空字串 = 全部顯示） |


若 Notion 欄位名稱不同，在 Supabase 更新 `sync_config` 即可。

#### 設定要顯示哪些 Landscape

worker 會把整個 Notion 庫抓進快取，但甘特圖只取 `gantt_landscape_allow` 列出的 Landscape（其餘略過）。預設已填入 5 個常用 Landscape，**名稱必須與 Notion 的 Landscape 頁面標題完全一致**。

先查目前快取裡實際的 Landscape 名稱：

```sql
select distinct public.notion_page_title(attrs) as landscape
from public.notion_page_cache
where public.notion_tag_is(
        coalesce(attrs->'properties','{}'::jsonb),
        coalesce(public.notion_cfg('prop_tag'),'Tag'),
        coalesce(public.notion_cfg('tag_landscape'),'Landscape'))
order by 1;
```

再依結果調整（JSON 陣列；設成 `''` 代表不篩選、全部顯示）：

```sql
update public.sync_config
set value = '["Go-to-Market","Sprint/Pipelines","Projects - Mtel2"]'
where key = 'gantt_landscape_allow';
```

改完按前端「立即同步」或等下次 worker 跑就會生效。

---

## Notion + Supabase 設定步驟

### 1. Notion

1. 建立 Internal Integration：[https://www.notion.so/profile/integrations](https://www.notion.so/profile/integrations)
2. 複製 Integration Secret（`ntn_...`）
3. 在任務 database 按 **⋯ → Connections**，連接該 integration
4. 確認 database 有以下欄位（名稱可於 `sync_config` 調整）：
  - **Title**（標題）
  - **Date**（日期區間）
  - **People**（人員）
  - **專案**（Relation 至專案 database）
5. 從 database URL 複製 **Database ID**

### 2. Supabase

套用 migrations（Dashboard → SQL 或 `supabase db push`），重點：

- `20250617000007_notion_database_query.sql` ← `sync_gantt_from_notion()`（快取 → gantt_state，解析 WBS）
- `20250617000008_sync_rpc_grants.sql` ← 授權 anon 觸發前端「立即同步」（重建用）
- `20250622000001_preserve_overrides_on_sync.sql` ← 同步時保留前端本地設定（角色／顏色／排序）
- `20250624000008_notion_sync_cursor.sql` ← **增量同步 checkpoint 表**（worker 用）

設定 database id（worker 會從這裡讀，不需另存）：

```sql
update public.sync_config
set value = 'YOUR_NOTION_DATABASE_ID'
where key = 'notion_database_id';
```

> 註：`http` extension 與舊的 `notion_pull_*` 函式已不再是同步主力，可保留作為手動備援。日常拉取改由下方的 GitHub Action 負責。

### 3. GitHub Action 增量同步（同步主力）

worker 位於 `scripts/notion-sync/`，由 `.github/workflows/notion-sync.yml` 每 15 分鐘排程執行。

在 GitHub repo **Settings → Secrets and variables → Actions** 設定三個 secrets：

| Secret | 說明 |
| --- | --- |
| `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase service_role key（Settings → API）。**只放在 Action secret，勿放前端** |
| `NOTION_TOKEN` | Notion internal integration secret（`ntn_...`） |

啟用後：

- **自動**：每 15 分鐘增量同步一次（第一次會全量拉取，之後只拉變動）。
- **手動**：Actions 分頁 → *Notion → Supabase sync* → *Run workflow*。需要重抓整庫時，把 `full_resync` 勾選為 true（會清快取再全量拉）。

#### 本地測試 worker

```bash
cd scripts/notion-sync
npm install
cp .env.example .env   # 填入 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / NOTION_TOKEN
node --env-file=.env sync.mjs
```

成功後可檢查同步狀態：

```sql
select * from public.notion_sync_cursor;  -- last_edited_synced / last_status / rows_last_run
select * from public.gantt_sync_status;
```

### 4. 欄位對照（`sync_config`）

見上方 **Notion 任務階層（WBS）** 表格。舊版 `prop_people` / `prop_project` 已由 WBS 同步取代。

### 5. 前端

`index.html` 中 `NOTION_READ_ONLY = true` 表示不回寫 Supabase，並隱藏新增專案／任務按鈕。部署至 GitHub Pages 後即可使用。

---

## 本地預覽

前端是單一 `index.html`，但因為要用 Supabase JS 與 fetch，需透過 http 伺服器開啟（不能直接 `file://`）：

```bash
cd gantt-planner
python3 -m http.server 8848
# 瀏覽器開 http://127.0.0.1:8848/index.html
```

頁面會讀取 Supabase `gantt_state`，點「立即同步」即可從 Notion 拉最新資料。

> **分支說明**：線上正式版部署自 `main`；Notion 唯讀同步 + 立即同步功能在 `second-version`（作為本地檢視的測試版）。切換：`git checkout second-version`。

---

## 如何使用

### 基本操作

1. 打開 [https://jonathankjlin.github.io/gantt-planner/（或本地預覽）](https://jonathankjlin.github.io/gantt-planner/（或本地預覽）)
2. 首次載入需要 1-2 秒等待 Supabase 回應
3. 在 **Notion** 新增 / 編輯任務
4. 回頁面點 banner 的「**立即同步**」按鈕（或在 SQL Editor 執行 pull + sync）
5. 使用日 / 週 / 月切換不同粒度的甘特圖

### 編輯資料

- **任務 / 專案 / 人員**：請在 **Notion** 編輯（甘特圖為唯讀）
- **檢視範圍**：仍可在頂部調整起始 / 結束日期與日週月檢視

### 備份

- **匯出 JSON**：下載目前甘特圖狀態（含 Notion 同步結果）

---

## 注意事項

### 資料儲存

- 資料來源：**Notion 任務 database**
- 甘特圖狀態快取於 Supabase `gantt_state` 與瀏覽器 localStorage
- 同步為**單向**（Notion → Supabase），甘特圖上的修改不會回寫

### 安全性

- 此工具使用 Supabase **anon key**（公開金鑰），適合團隊內部使用
- Notion API key 存於 Supabase Vault，**不可**放入 `index.html`
- 如需存取控制，可在 Supabase 設定 Row Level Security

### 技術架構

- 前端：原生 HTML / CSS / JavaScript（`index.html`）
- 資料庫：Supabase PostgreSQL + `notion_page_cache` + `notion_sync_cursor`（checkpoint）
- 同步：GitHub Action worker（`scripts/notion-sync`，增量 `last_edited_time`）→ `sync_gantt_from_notion()`
- 部署：GitHub Pages（`main` 為正式版）

---

## 開發者資訊

```bash
# 修改前端
git add index.html
git commit -m "your change description"
git push

# 修改資料庫 schema
# 編輯 supabase/migrations/ 後在 Supabase Dashboard 執行，或使用 Supabase CLI
```

Repository 目錄重點：

```
.github/workflows/notion-sync.yml   # 每 15 分鐘排程 + 手動觸發
scripts/notion-sync/                # 增量同步 worker（Node）
├── sync.mjs
├── package.json
└── .env.example
supabase/
├── config.toml
├── manual/setup_notion_credentials.sql
└── migrations/
    ├── 20250617000007_notion_database_query.sql   # sync_gantt_from_notion()（WBS 解析）
    ├── 20250617000008_sync_rpc_grants.sql          # 授權 anon 觸發立即同步
    ├── 20250622000001_preserve_overrides_on_sync.sql  # 同步時保留前端本地設定
    ├── 20250624000008_notion_sync_cursor.sql       # 增量同步 checkpoint 表
    └── 20250624000009_landscape_allow_filter.sql   # 只顯示指定 Landscape（本地端篩選）
```

