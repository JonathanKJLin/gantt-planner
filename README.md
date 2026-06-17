# Resource Gantt Planner — 多專案人力排程工具

解決多專案同時進行時的人天安排困擾：誰在什麼時候有空？誰被分配過多？任務之間是否真的有時間衝突？

**Live Site**: https://jonathankjlin.github.io/gantt-planner/

---

## 架構（Notion 版）

```
Notion 任務資料庫 (Title / Date / Assignee / Tag / Parent item)
        ↓  notion_pull_database_pages() — Notion Database Query API (http extension)
   notion_page_cache (原始頁面 JSON 快取)
        ↓  sync_gantt_from_notion() — 解析 WBS、單向
   gantt_state (JSON)
        ↓  Realtime / 重新載入
   index.html 甘特圖（唯讀）
```

- **任務維護**：團隊在 Notion 編輯
- **甘特圖**：自動反映 Notion 資料，此頁面不提供回寫
- **同步方式**：前端「**立即同步**」按鈕一鍵觸發（pull + sync），或在 SQL Editor 手動執行
- **為何用 http extension 而非 FDW**：Notion FDW 的 `notion.pages` 只有在 `WHERE id = ...` 時可靠；用 database / parent 篩選會掃不到列。改用 Notion Database Query API 把整個 database（含 sub-items）抓進 `notion_page_cache`，再從快取解析 WBS。

---

## 這個系統做什麼

在顧問業、專案管理、或任何需要跨專案調度人力的場景中，常見的問題是：

- 同一個人被安排到多個專案，但不確定時間是否真的衝突
- 用 Excel 排人力，無法即時看到全局甘特圖
- 團隊成員變動（入職 / 離職）時，排程需要重新調整

這個工具提供一個**即時同步的甘特圖介面**，讓你可以：

- 一眼看出每個人在什麼時段有哪些任務
- 自動偵測真正的時間重疊（以天為最小單位，不是只看同一週）
- 標記人力超載（同時 >3 個任務）
- 追蹤成員的入職 / 離職日，在甘特圖上自動標示不可用時段

---

## 功能一覽

### 甘特圖

- **三種檢視**：日 / 週 / 月，隨時切換
- **凍結窗格**：捲動時人名和日期標頭固定不動
- **多人負責**：一個任務可指派多位負責人，會出現在每個人的時間軸上
- **重疊偵測**：同一人同時超過 3 個任務時，自動標紅框 + 斜紋底色
- **入職 / 離職標記**：設定後甘特圖顯示灰色斜線區域，分配任務時自動警告

### 專案總覽

- 每個專案的任務明細表（負責人、日期、天數）
- 人員參與度長條圖（每人投入幾天、佔比多少）
- 跨專案人力分配矩陣（人 × 專案 的天數交叉表）

### Notion 同步

- 使用 Notion 既有欄位：**Title**、**Date**、**Assignee**、**Tag**、**Parent item**（sub-items）
- 透過 Notion Database Query API（Supabase `http` extension）抓進 `notion_page_cache`
- 解析 WBS 後同步至 `gantt_state`，前端重新載入後更新
- 前端 banner 的「**立即同步**」按鈕可一鍵觸發，不需進 SQL Editor
- 甘特圖 **唯讀**；編輯請回 Notion

### 匯出

- **JSON**：完整資料備份（唯讀模式下仍可匯出）

### 即時同步

- 透過 Supabase 即時同步，多人打開同一網址看到同一份資料
- 點「立即同步」完成後，頁面即更新；其他開著的頁面透過 Realtime 自動更新
- 離線時自動 fallback 到本地快取

---

## Notion 任務階層（WBS）

同一個 Notion database 內以 **Parent item** 串起 5 層結構：

| 層級 | Tag | 範例 | 甘特圖 |
|------|-----|------|--------|
| 1 | `Landscape` | go-to-market、project - on-going (manager 1) | 不顯示（僅分類） |
| 2 | `Ultimate(Proj)` | 統一超商股份有限公司 | → **專案**（顏色圖例） |
| 3 | `Parent` | Phase 1 ~ cooking & identifying | 若無子項 → 可顯示 |
| 4 | `Parent` | Prospecting & Preparation | 若無子項 → 可顯示 |
| 5 | `Task` | 確認範疇和客戶起案意願… | 可顯示 |

**同步規則（leaf）：** 只匯入「沒有更下層 sub-item」的節點——不論 tag 是 `Parent` 或 `Task`，只要沒有人把它當 parent，就會出現在甘特圖。

**負責人：** `Assignee` 欄位（支援 People / Select / Multi-select）→ 甘特圖橫軸人員。

**WBS 路徑：** 同步後 task 帶 `wbsPath`（例：`Phase 1 › Prospecting & Preparation`），hover 任務條可見。

### sync_config 欄位

| key | 預設值 | 說明 |
|-----|--------|------|
| `notion_database_id` | （必填） | 任務 database ID |
| `prop_tag` | Tag | 階層 tag 欄位 |
| `prop_parent` | Parent item | 指向父項目的 relation |
| `prop_assignee` | Assignee | 負責人 |
| `prop_date` | Date | 起迄日期 |
| `tag_landscape` | Landscape | 第 1 層 tag 值 |
| `tag_project` | Ultimate(Proj) | 第 2 層 → 甘特專案（`Ultimate(...)` 開頭皆可匹配） |
| `tag_parent` | Parent | 中間層 tag |
| `tag_task` | Task | 最底層 tag |

若 Notion 欄位名稱不同，在 Supabase 更新 `sync_config` 即可。

---

## Notion + Supabase 設定步驟

### 1. Notion

1. 建立 Internal Integration：https://www.notion.so/profile/integrations
2. 複製 Integration Secret（`ntn_...`）
3. 在任務 database 按 **⋯ → Connections**，連接該 integration
4. 確認 database 有以下欄位（名稱可於 `sync_config` 調整）：
   - **Title**（標題）
   - **Date**（日期區間）
   - **People**（人員）
   - **專案**（Relation 至專案 database）
5. 從 database URL 複製 **Database ID**

### 2. Supabase

先在 **Database → Extensions** 啟用 **`http`** extension。

在 SQL Editor 依序執行：

1. `supabase/manual/setup_notion_credentials.sql`（把 Notion token 存入 Vault，`name = 'notion'`）
2. 套用 migrations（Dashboard → SQL 或 `supabase db push`）：
   - `20250616000001_baseline.sql`
   - `20250616000002_notion_fdw.sql`
   - `20250616000003_sync_from_notion.sql`
   - `20250616000004_wbs_hierarchy_sync.sql`
   - `20250616000005_notion_schema_from_workspace.sql`
   - `20250617000006_notion_page_discovery.sql`
   - `20250617000007_notion_database_query.sql` ← http extension 快取式 pull + sync（自含 helper）
   - `20250617000008_sync_rpc_grants.sql` ← 授權 anon 觸發「立即同步」
3. 設定 database id：

```sql
update public.sync_config
set value = 'YOUR_NOTION_DATABASE_ID'
where key = 'notion_database_id';
```

4. 手動執行首次同步（兩步；注意是 `SELECT` 不是 `CALL`）：

```sql
select public.notion_pull_database_pages() as cached_pages;  -- 抓 Notion → 快取
select public.sync_gantt_from_notion();                      -- 快取 → gantt_state
select * from public.gantt_sync_status;
```

之後每次要從 Notion 更新，重跑上面前兩行即可，或直接在前端點「**立即同步**」。

### 3. 欄位對照（`sync_config`）

見上方 **Notion 任務階層（WBS）** 表格。舊版 `prop_people` / `prop_project` 已由 WBS 同步取代。

### 4. 前端

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

1. 打開 https://jonathankjlin.github.io/gantt-planner/（或本地預覽）
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

- 權威來源：**Notion 任務 database**
- 甘特圖狀態快取於 Supabase `gantt_state` 與瀏覽器 localStorage
- 同步為**單向**（Notion → Supabase），甘特圖上的修改不會回寫

### 安全性

- 此工具使用 Supabase **anon key**（公開金鑰），適合團隊內部使用
- Notion API key 存於 Supabase Vault，**不可**放入 `index.html`
- 如需存取控制，可在 Supabase 設定 Row Level Security

### 技術架構

- 前端：原生 HTML / CSS / JavaScript（`index.html`）
- 資料庫：Supabase PostgreSQL + `http` extension（Notion Database Query API）+ `notion_page_cache`
- 同步：`notion_pull_database_pages()` + `sync_gantt_from_notion()`（前端「立即同步」按鈕觸發）
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

Repository migrations 目錄：

```
supabase/
├── config.toml
├── manual/setup_notion_credentials.sql
└── migrations/
    ├── 20250616000001_baseline.sql
    ├── 20250616000002_notion_fdw.sql
    ├── 20250616000003_sync_from_notion.sql
    ├── 20250616000004_wbs_hierarchy_sync.sql
    ├── 20250616000005_notion_schema_from_workspace.sql
    ├── 20250617000006_notion_page_discovery.sql
    ├── 20250617000007_notion_database_query.sql   # http extension 快取式 pull + sync
    └── 20250617000008_sync_rpc_grants.sql          # 授權 anon 觸發立即同步
```
