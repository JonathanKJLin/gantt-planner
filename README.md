# Resource Gantt Planner

多專案人力排程與甘特圖檢視工具。任務資料由公司 Notion database 維護，網站本身為唯讀視覺化工具，透過 GitHub Action 定時同步到 Supabase，再由前端讀取 Supabase 狀態呈現。

現行版本：[https://jonathankjlin.github.io/gantt-planner/](https://jonathankjlin.github.io/gantt-planner/)

> Notion integration secret 不用更改，之後把程式碼移轉到公司 GitHub 帳號時，**不需要因為 GitHub 轉移而更換 Notion database 或 Notion token**。需要重新設定的是新的 Supabase 專案與 GitHub Actions secrets。

---

## Part 1. 架構與功能

### 系統架構

```text
公司 Notion 任務 database
  └─ GitHub Action worker（每 15 分鐘）
      └─ scripts/notion-sync/sync.mjs
          └─ 依 last_edited_time 增量分頁拉取
              └─ Supabase notion_page_cache
                  └─ sync_gantt_from_notion()
                      └─ Supabase gantt_state
                          └─ index.html 前端甘特圖（唯讀）
```

### 核心設計

- **Notion 是資料來源**：任務、負責人、階層、排程日期都在公司 Notion database 維護。
- **前端唯讀**：網站不回寫 Notion，角色顏色、專案顏色、排序等網頁偏好存到 Supabase `_overrides`。
- **GitHub Action 增量同步**：第一次 full resync 會抓完整 database，之後只抓 `last_edited_time` 之後有變動的頁面，避免資料量變大後同步崩潰。
- **Supabase 快取與狀態**：`notion_page_cache` 保存 Notion 原始 JSON；`sync_gantt_from_notion()` 解析 WBS、套用篩選，產生前端使用的 `gantt_state`。
- **本地端篩選**：Landscape allow-list 與日期要求在 Supabase 端處理，不要求 Notion 額外加 select / multi-select，避免干擾既有 automation。

### 功能一覽

#### 甘特圖

- 日 / 週 / 月檢視切換。
- 今日標記、時間軸橫向延展。
- 依人員顯示任務條，一個任務可有多人負責。
- 重疊任務提示與視覺標示。
- 專案篩選：Landscape → Ultimate(Proj) 階層式篩選。
- 專案顏色可在網頁端調整，作為 web override 保存。

#### 專案總覽

- 每個專案的任務明細、負責人、日期、天數。
- Landscape → 專案篩選。
- 任務名稱搜尋。
- 人員參與度長條圖。
- 跨專案人力分配矩陣。
- 任務排序可在網頁端拖曳調整，作為 web override 保存。

#### Notion 同步

- 使用公司 Notion database 既有欄位：`Task Name`、`Tag`、`Parent-task`、`Assignee`、`Ultimate Parent` 等。
- 排程時間建議使用一個 Notion `Date` 屬性，開啟 End date，在同一欄填起始與結束。
- GitHub Action worker 每 15 分鐘同步一次。
- 前端「立即同步」只做 Supabase 端重建與重新讀取，不直接呼叫 Notion API。

### Notion WBS 階層

同一個 Notion database 內用 `Parent-task` 串起階層：


| 層級  | Tag              | 角色                            | 甘特圖行為       |
| --- | ---------------- | ----------------------------- | ----------- |
| 1   | `Landscape`      | 大分類，如 Go-to-Market / On-going | 不直接顯示，用於篩選  |
| 2   | `Ultimate(Proj)` | 專案                            | 顯示為專案       |
| 3   | `Parent`         | 中間階層                          | 若是 leaf 可顯示 |
| 4   | `Parent`         | 中間階層                          | 若是 leaf 可顯示 |
| 5   | `Task`           | 實際任務                          | 顯示為甘特圖任務    |


同步規則：只匯入沒有更下層 sub-task 的 leaf node。若 `gantt_require_dates = 'both'`，還必須有排程 Date 的 start + end 才會出現在甘特圖。

### 重要設定：`sync_config`

Supabase 的 `public.sync_config` 控制 Notion 欄位名稱與甘特圖篩選。


| key                     | 說明                              |
| ----------------------- | ------------------------------- |
| `notion_database_id`    | 公司 Notion 任務 database ID        |
| `prop_title`            | 任務標題欄位，通常是 `Task Name`          |
| `prop_parent`           | 父任務 relation，現在是 `Parent-task`  |
| `prop_tag`              | 階層 tag 欄位，通常是 `Tag`             |
| `prop_assignee`         | 負責人欄位，通常是 `Assignee`            |
| `prop_date`             | 甘特圖排程 Date 欄位；轉移後請指到公司實際欄位名     |
| `gantt_require_dates`   | `both`、`start` 或 `off`          |
| `gantt_landscape_allow` | 允許顯示的 Landscape JSON 陣列；空字串代表全部 |
| `tag_landscape`         | Landscape tag 名稱                |
| `tag_project`           | Ultimate project tag 名稱         |
| `tag_parent`            | Parent tag 名稱                   |
| `tag_task`              | Task tag 名稱                     |


---

## Part 2. 公司 GitHub + 新 Supabase 移轉指南

這一段用於把目前程式碼移轉到公司 GitHub 帳號，並切換到公司新開的 Supabase 專案。

### 移轉後哪些東西會變、哪些不會變

#### 不需要改

- **公司 Notion database**：已經是公司 Notion database，保持不變。
- **Notion integration secret (`ntn_...`)**：由 admin 提供，轉移 GitHub repo 不會讓 token 失效。
- **Notion database 權限**：只要該 integration 仍連接在 database 的 Connections 裡即可。
- **Notion database ID**：除非公司換 database，否則不變。

#### 需要改

- **GitHub repo 位置**：從個人帳號 repo 轉到公司 GitHub 帳號 repo。
- **GitHub Pages 設定**：公司 repo 需要重新啟用 Pages。
- **GitHub Actions secrets**：公司 repo 需要重新建立 secrets。
- **Supabase 專案**：公司會新開 Supabase project，所以 database schema、RLS、資料、API key 都要重新設定。
- **前端 Supabase 設定**：`index.html` 內的 `SUPABASE_URL`、`SUPABASE_ANON_KEY` 要改成新 Supabase project 的值。
- **GitHub Action Supabase secrets**：`SUPABASE_URL`、`SUPABASE_SERVICE_ROLE_KEY` 要改成新 Supabase project 的值。

### Step 1. 移轉程式碼到公司 GitHub

建議流程：

```bash
git clone https://github.com/JonathanKJLin/gantt-planner.git
cd gantt-planner
git remote remove origin
git remote add origin https://github.com/<company-org>/<company-repo>.git
git push -u origin main
git push origin 1.0        # optional：保留舊版備份分支
```

也可以在 GitHub UI 使用 Import repository 或 Transfer ownership。無論使用哪種方式，請確認公司 repo 內有這些目錄：

```text
.github/workflows/notion-sync.yml
scripts/notion-sync/
supabase/migrations/
index.html
README.md
```

### Step 2. 啟用公司 GitHub Pages

在公司 repo：

1. 進入 **Settings → Pages**。
2. Source 選 **Deploy from a branch**。
3. Branch 選 `main`，folder 選 `/root`。
4. 儲存後等待部署完成。
5. 記下新的 GitHub Pages URL，之後給團隊使用。

### Step 3. 新建公司 Supabase project

在公司 Supabase 帳號：

1. 建立新 project。
2. 記下 Project URL：格式必須是 `https://<project-ref>.supabase.co`，**不要包含 `/rest/v1/`**。
3. 記下 API keys：
  - `anon public`：放到 `index.html`，前端可公開使用。
  - `service_role`：只放 GitHub Actions secret，不可放進前端、不應 commit。

### Step 4. 套用公司版 Supabase setup SQL

公司移轉時**不要逐一手動執行 `supabase/migrations/` 內所有歷史 migration**。那些 migration 包含開發過程中排查 Notion API timeout 的舊方案（例如 `notion_pull_*`、Vault/http pull、stepwise pull），目前正式同步主力已改為 GitHub Action worker。

請在新 Supabase project 的 **SQL Editor** 執行：

```text
supabase/manual/company_setup.sql
```

這個檔案是公司移轉用的一次性 setup，已整理成新 Supabase project 必要且最新的 schema / function / policy / grant，不包含歷史實驗函式。

執行完成後，至少要確認以下核心物件存在：

- `public.gantt_state`
- `public.sync_config`
- `public.sync_log`
- `public.notion_page_cache`
- `public.notion_sync_cursor`
- `public.sync_gantt_from_notion()`
- `public.gantt_sync_status`

> 注意：新 Supabase 專案是空的。即使 Notion 不變，也必須重新建立 schema、設定 `sync_config`、跑第一次 full resync。
>
> 補充：`supabase/migrations/` 仍保留作為開發歷史與增量變更紀錄；公司新帳號初始化請以 `company_setup.sql` 為主。

### Step 5. 設定 `sync_config`

在新 Supabase SQL Editor 設定公司 Notion database 與欄位對照。

```sql
update public.sync_config
set value = 'YOUR_COMPANY_NOTION_DATABASE_ID'
where key = 'notion_database_id';

update public.sync_config set value = 'Task Name' where key = 'prop_title';
update public.sync_config set value = 'Parent-task' where key = 'prop_parent';
update public.sync_config set value = 'Tag' where key = 'prop_tag';
update public.sync_config set value = 'Assignee' where key = 'prop_assignee';
```

如果公司已新增甘特圖排程 Date 欄位，例如 `Gantt Date`：

```sql
update public.sync_config set value = 'Gantt Date' where key = 'prop_date';
update public.sync_config set value = 'both' where key = 'gantt_require_dates';
```

如果 Date 欄位尚未準備好，先關閉日期篩選，避免頁面顯示 0 任務：

```sql
update public.sync_config set value = 'off' where key = 'gantt_require_dates';
```

設定允許顯示的 Landscape：

```sql
update public.sync_config
set value = '["Go-to-Market","Sprint/Pipelines","Projects - Mtel2","Projects - On-going ( BIA & DMG )","Projects - On-going ( AiLab & RA )"]'
where key = 'gantt_landscape_allow';
```

若要全部顯示：

```sql
update public.sync_config
set value = ''
where key = 'gantt_landscape_allow';
```

### Step 6. 更新前端 Supabase 設定

在 `index.html` 修改：

```js
const SUPABASE_URL = 'https://<new-project-ref>.supabase.co';
const SUPABASE_ANON_KEY = '<new-supabase-anon-key>';
```

請使用新 Supabase project 的：

- Project URL：`https://<project-ref>.supabase.co`
- `anon public` key

改完 commit 並 push 到公司 repo：

```bash
git add index.html
git commit -m "chore: point frontend to company Supabase project"
git push origin main
```

### Step 7. 設定公司 GitHub Actions secrets

在公司 GitHub repo：

**Settings → Secrets and variables → Actions → New repository secret**

建立三個 secrets：


| Secret name                 | Secret value                                                                 |
| --------------------------- | ---------------------------------------------------------------------------- |
| `SUPABASE_URL`              | 新 Supabase Project URL，格式 `https://<project-ref>.supabase.co`，不要 `/rest/v1/` |
| `SUPABASE_SERVICE_ROLE_KEY` | 新 Supabase project 的 `service_role` key                                      |
| `NOTION_TOKEN`              | 公司 admin 提供的 Notion integration secret (`ntn_...`)                           |


> `NOTION_TOKEN` 可沿用公司 admin 提供的 token；移轉 GitHub repo 不會要求更換。真正需要換的是 Supabase 相關兩個值，因為 Supabase project 會重建。

### Step 8. 跑第一次 full resync

在公司 GitHub repo：

1. 進入 **Actions**。
2. 點選 **Notion -> Supabase sync**。
3. 點 **Run workflow**。
4. 勾選 `full_resync = true`。
5. 等待 run 成功。

### Step 9. 驗證 Supabase 資料

在新 Supabase SQL Editor：

```sql
select last_status, last_error, rows_last_run, full_sync_done, last_edited_synced
from public.notion_sync_cursor;

select count(*) from public.notion_page_cache;

select status, task_count, project_count, people_count, error_message
from public.gantt_sync_status;
```

預期：

- `last_status = 'ok'`
- `full_sync_done = true`
- `notion_page_cache` count 大於 0
- `gantt_sync_status.status = 'ok'`

若 task count 是 0，優先檢查：

- `gantt_require_dates` 是否設為 `both` 但 Notion 還沒填 Date。
- `prop_date` 是否指到錯誤欄位。
- `gantt_landscape_allow` 是否沒有包含實際 Landscape 名稱。
- `prop_parent` / `prop_tag` / `prop_assignee` 是否與 Notion 欄位名稱不一致。

### Step 10. 驗證 Landscape 名稱

第一次 full resync 後，查實際 Landscape：

```sql
select distinct public.notion_page_title(attrs) as landscape
from public.notion_page_cache
where public.notion_tag_is(
        coalesce(attrs->'properties','{}'::jsonb),
        coalesce(public.notion_cfg('prop_tag'),'Tag'),
        coalesce(public.notion_cfg('tag_landscape'),'Landscape'))
order by 1;
```

把查到的名稱精準填入 `gantt_landscape_allow`。名稱需完全一致。

### Step 11. 驗證前端

1. 開啟公司 GitHub Pages URL。
2. 重新整理：`Cmd + Shift + R`。
3. 確認右上角顯示 Notion 已同步。
4. 確認甘特圖與專案總覽有資料。
5. 測試「專案篩選」、「專案總覽搜尋」、「匯出 JSON」。
6. 若剛更改 `sync_config`，可按「立即同步」或等下一次 Action。

### 日常維運

- GitHub Action 每 15 分鐘自動同步。
- Notion 欄位名稱若改變，需更新 `sync_config`。
- Notion integration 若被移除 database connection，Action 會失敗並出現 Notion 404/permission error。
- Supabase service_role key 若 rotate，需更新 GitHub secret `SUPABASE_SERVICE_ROLE_KEY`。
- 前端若顯示舊資料，先硬重新整理，再檢查 `gantt_sync_status` 與 Action log。

### 常見問題

#### GitHub Action 顯示 `Invalid path specified in request URL`

`SUPABASE_URL` 填錯。正確格式：

```text
https://<project-ref>.supabase.co
```

錯誤格式：

```text
https://<project-ref>.supabase.co/rest/v1/
```

#### 前端或 SQL 顯示 0 任務

可能是日期篩選或 Landscape 篩選造成：

```sql
update public.sync_config set value = 'off' where key = 'gantt_require_dates';
update public.sync_config set value = '' where key = 'gantt_landscape_allow';
select public.sync_gantt_from_notion();
```

確認資料回來後，再逐步打開篩選。

#### 「立即同步」出現 statement timeout

確認已套用：

```text
supabase/migrations/20250624000011_sync_statement_timeout.sql
```

也可以直接等 GitHub Action 下次同步；Action 使用 service_role，通常不受前端 anon timeout 影響。

#### Date 欄位還沒準備好

暫時關閉日期篩選：

```sql
update public.sync_config set value = 'off' where key = 'gantt_require_dates';
select public.sync_gantt_from_notion();
```

等 Notion admin 新增 Date 欄位且任務補上日期後，再設定：

```sql
update public.sync_config set value = 'Gantt Date' where key = 'prop_date';
update public.sync_config set value = 'both' where key = 'gantt_require_dates';
select public.sync_gantt_from_notion();
```

### 目錄重點

```text
.github/workflows/notion-sync.yml
scripts/notion-sync/
  sync.mjs
  package.json
  .env.example
supabase/
  config.toml
  migrations/
index.html
README.md
```

