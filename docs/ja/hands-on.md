# ハンズオン

[English](../en/hands-on.md) | 日本語

2 部構成です。

- **第 1 部（手元、約 10 分）**：`clickhouse local` だけで、L0 から L1、L2、L3 までの SQL を動かし、日本語の検索とノイズの規則を確かめます。クラウドのリソースは作りません。
- **第 2 部（実環境、約 60 分）**：検証用の Google Cloud プロジェクトと ClickHouse Cloud のサービスに Terraform で構成を作り、合成ログを流して ClickStack で検索します。最後に片付けます。

設計の背景は [設計](design.md)、本番向けの導入手順は [導入](setup.md) にあります。

## 第 1 部：手元で SQL を動かす

### 1-1. 準備

- ClickHouse の単体実行（`curl https://clickhouse.com/ | sh` で入る `clickhouse`）
- `python3`（標準ライブラリだけを使う）

### 1-2. 一式を流して確かめる

```bash
WORKDIR=/tmp/gcl-handson verify/local_e2e.sh 20000
```

このスクリプトは次のことを行います。

1. `loadgen/gen_logentry.py` で、Cloud Logging のシンクが送る形の LogEntry を 2 万件ずつ 2 回作る。1 回目には Kubernetes の Lease の更新（ノイズの例）を 2 割混ぜる。
2. `sql/10`〜`sql/50` で L0、L1、MV1、L3（分単位の件数）、ノイズの件数を作る。
3. 1 回目の分を、ClickPipe と同じ形（生メッセージと Pub/Sub の仮想列）で L0 に入れる。
4. 境界時刻 T を決めて L2 の例（`sql/examples/l2_audit_events_v1.sql`）の MV を作り、2 回目の分を入れる。T より前の 1 回目の分は `sql/examples/l2_audit_events_v1_backfill.sql` で L0 からバックフィルする。
5. 件数を突き合わせる。

結果は次のように出ます（件数は乱数で変わります）。

```text
   ┌─check───────────────────────────┬─expected─┬─actual─┬─result─┐
1. │ L0 rows = generated             │ 40000    │  40000 │ PASS   │
2. │ L1 rows = L0 rows - noise       │ 35985    │  35985 │ PASS   │
3. │ Noise counts = noise rows in L0 │ 4015     │   4015 │ PASS   │
4. │ L3 rollup total = L1 rows       │ 35985    │  35985 │ PASS   │
5. │ L2 audit rows = L1 audit rows   │ 3559     │   3559 │ PASS   │
6. │ L2 has no duplicates            │ 3559     │   3559 │ PASS   │
7. │ ServiceName/Body never empty    │ 0        │      0 │ PASS   │
8. │ No 1970 timestamps              │ 0        │      0 │ PASS   │
9. │ Japanese search (index) = LIKE  │ 3079     │   3079 │ PASS   │
   └─────────────────────────────────┴──────────┴────────┴────────┘
```

- 2 と 3：Lease の更新は L1 に入らず、件数だけがノイズの表に残ります。
- 4：L3 の合計は L1 の行数と一致します。
- 5 と 6：L2 は、MV で入った分とバックフィルの分を合わせて L1 の監査ログと同じ件数になり、重複もありません。
- 9：2 文字ずつの全文検索インデックスで「タイムアウト」を探した件数が、LIKE で数えた件数と一致します。

### 1-3. 中を見る

`WORKDIR` を付けて流すと、データベースが残ります。

```bash
q() { TZ=UTC clickhouse local --path /tmp/gcl-handson/db -q "$1"; }
```

**L1 の ServiceName**：ログの種類ごとに、決まった規則で埋まります。

```bash
q "SELECT ResourceType, ServiceName, count() FROM gcl.gcl_logs_v1 GROUP BY ALL ORDER BY 3 DESC LIMIT 10"
```

**日本語の検索**：ClickStack が検索窓の語から作る条件と同じ形です。

```bash
q "SELECT Body FROM gcl.gcl_logs_v1 WHERE hasAllTokens(lower(Body), lower('タイムアウト')) LIMIT 3"
q "EXPLAIN indexes = 1 SELECT count() FROM gcl.gcl_logs_v1 WHERE hasAllTokens(lower(Body), 'タイムアウト')"
```

EXPLAIN の Skip の欄に `idx_lower_body` と、2 文字ずつに分けた語（`タイ`、`イム` など）が出ます。

**L1 で値を取り出す**：型付きテーブルを作らなくても、属性と列から表を作れます。

```bash
q "SELECT ServiceName, round(quantile(0.95)(HttpLatencySeconds), 3) AS p95_s, countIf(HttpStatus >= 500) AS errors
   FROM gcl.gcl_logs_v1 WHERE HttpMethod != '' GROUP BY ALL ORDER BY p95_s DESC"
q "SELECT LogAttributes['audit.principalEmail'] AS who, LogAttributes['audit.methodName'] AS what, count()
   FROM gcl.gcl_logs_v1 WHERE mapContains(LogAttributes, 'audit.methodName') GROUP BY ALL ORDER BY 3 DESC"
```

**L2 との比較**：同じ問いに L2 から答えると、操作者の順に並んでいるので読む量が減ります。

```bash
q "SELECT Principal, MethodName, count() FROM gcl.audit_events_v1 GROUP BY ALL ORDER BY 3 DESC"
```

**ノイズの件数**：L1 から外したログは、規則ごとの分単位の件数として残ります。

```bash
q "SELECT Rule, Principal, sum(Cnt) FROM gcl.gcl_noise_1m_v1 GROUP BY ALL ORDER BY 3 DESC"
```

終わったら `rm -rf /tmp/gcl-handson` で消します。

## 第 2 部：実環境で動かす

検証用のプロジェクトとサービスで行います。
本番のプロジェクトで行うと、そのプロジェクトの全ログがトピックに送られ、Pub/Sub の料金がかかります。

### 2-1. 準備

- 検証用の Google Cloud プロジェクトと、ClickHouse Cloud のサービス（26.6 以降）
- [導入](setup.md) の「前提」と「1. 認証」

### 2-2. 構成を作る

```bash
cd terraform
cat > terraform.tfvars <<'EOF'
gcp_project_id        = "<sandbox project>"
clickhouse_service_id = "<service id>"
EOF
terraform init
terraform apply
terraform output clickpipe_state   # Running
```

Terraform を使えないときは、`cli/.env` に同じ 2 つの値を入れて `cli/deploy.sh` を流します。片付けは `DROP_DATABASE=1 cli/destroy.sh` です。

### 2-3. 合成ログを流す

ハンズオンでは、シンクが送る実際のログに加えて、合成ログをトピックに直接公開します。
`--ids-out` に、公開したメッセージの ID が残ります。

```bash
cd ..
python3 loadgen/gen_logentry.py --publish projects/<sandbox project>/topics/gcl-to-clickhouse \
  --rate 50 --duration 300 --lease-rate 0.2 --dup-rate 0.01 --ids-out sent_ids.txt
```

### 2-4. 欠損と重複を確かめる

```bash
export CH_SERVICE_ID=<service id>
verify/completeness.sh sent_ids.txt
```

`missing_in_l0` が 0 なら、公開したメッセージはすべて L0 に届いています。
`missing_in_l1` は、L1 に入れない Lease の更新の件数になります。
Lease の更新を混ぜずに確かめるときは、`--lease-rate` を付けずに流し、`missing_in_l1` が 0 になることを見ます。
`--dup-rate` で同じ内容を再送した分は、Pub/Sub が別の `MessageId` を付けるので、`dup_ids_*` には数えません。

### 2-5. ClickStack で検索する

[導入](setup.md) の「4. ClickStack のソース」でソースとダッシュボードを作り、ClickStack を開きます。

1. ソース「Cloud Logging」を選び、検索窓に `タイムアウト` と入れる。本文にその語を含むログが出る。
2. 左のフィルタで ServiceName を `web-frontend` に絞る。
3. Event Patterns に切り替え、本文の形ごとの件数を見る。Lease の更新は L1 に入っていないので、上位に出ない。
4. ダッシュボード「Cloud Logging overview」を開く。

### 2-6. L2 を足す

監査ログの操作者で絞る表を、L2 として足します。
境界時刻 T は数分先にします。

```bash
T=$(date -u -v+3M +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u -d '+3 min' +"%Y-%m-%d %H:%M:%S")
python3 tools/chq.py --var LOGS_TTL_DAYS=400 --var MV_DEFINER=default --var T="$T" sql/examples/l2_audit_events_v1.sql
```

T 以降に公開された監査ログは、MV が L2 に入れます。
T を過ぎてから、T より前の分を L0 からバックフィルします。
同じファイルの末尾で、L2 と L1 の集計を並べて出します。

```bash
python3 tools/chq.py --var T="$T" sql/examples/l2_audit_events_v1_backfill.sql
python3 tools/chq.py -q "SELECT
  (SELECT count() FROM gcl.audit_events_v1) AS l2,
  (SELECT count() FROM gcl.gcl_logs_v1 WHERE mapContains(LogAttributes, 'audit.methodName')) AS l1_audit"
```

手順の詳細と作り替えの方法は [運用](operations.md) の「L2 の新規作成と作り替え」にあります。

### 2-7. L3 を足す

ログ名ごとの分単位の件数を、L3 として足します。
L2 と同じく、MV を作ってから T を過ぎるのを待ち、T より前の分を埋めます。

```bash
T=$(date -u -v+3M +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u -d '+3 min' +"%Y-%m-%d %H:%M:%S")
python3 tools/chq.py --var L3=logs_by_logid_1m_v1 --var L3_TTL_DAYS=400 --var T="$T" sql/runbooks/09_add_l3.sql
# after T has passed
python3 tools/chq.py --var L3=logs_by_logid_1m_v1 --var T="$T" --var CHECK_TO="$(date -u +'%Y-%m-%d %H:%M:00')" \
  sql/runbooks/09_add_l3_backfill.sql
```

最後の 2 つの数（L3 の合計と L1 の行数）が一致します。
手順は [運用](operations.md) の「L3 の追加」にあります。

### 2-8. 片付け

```bash
python3 tools/chq.py -q "DROP DATABASE IF EXISTS gcl SYNC"
cd terraform && terraform destroy
rm -f ../sent_ids.txt
```

ClickPipe を削除すると管理サブスクリプションも消えます。
シンクを消すと、トピックへの送出も止まります。
