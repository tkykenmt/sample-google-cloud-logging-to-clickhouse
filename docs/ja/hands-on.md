# ハンズオン

[English](../en/hands-on.md) | 日本語

どの部も、最後に作ったものを削除して終わります。

- **第 1 部（ローカル環境、約 10 分）**：`clickhouse local` だけで、L0 から L1、L2、L3 までの SQL を動かし、日本語の検索とノイズの除外条件を確かめます。
  クラウドのリソースは作りません。
- **第 2 部（実環境、約 60 分）**：検証用の Google Cloud プロジェクトと ClickHouse Cloud のサービスに Terraform で環境を構築し、合成ログを送信して ClickStack で検索します。
- **第 3 部（実環境、約 30 分）**：第 2 部で Terraform が作ったものを、`gcloud` と `clickhousectl` で 1 つずつ作り、それぞれの役割を確かめます。
  導入の手順ではありません。
  導入には [導入](setup.md) の Terraform を使います。

設計の背景は [設計](design.md)、本番向けの導入手順は [導入](setup.md) にあります。

## 第 1 部：ローカル環境で SQL を実行する

### 1-1. 準備

- ClickHouse の単体実行バイナリ（`curl https://clickhouse.com/ | sh` でインストールする `clickhouse`）
- `python3`（標準ライブラリだけを使う）
- リポジトリの最上位のディレクトリで実行します。

### 1-2. SQL 一式を実行して確認する

```bash
WORKDIR=/tmp/gcl-handson verify/local_e2e.sh 20000
```

このスクリプトは次のことを行います。

1. `loadgen/gen_logentry.py` で、Cloud Logging のシンクが送る形の LogEntry を 2 万件ずつ 2 回生成する。
   1 回目には Kubernetes の Lease の更新（ノイズの例）を 2 割混ぜる。
2. `sql/10`〜`sql/50` で L0、L1、L3（分単位の件数）、ノイズの集計テーブルと、それらを作る MV を作る。
3. 1 回目の分を、ClickPipe と同じ形（生メッセージと Pub/Sub の仮想列）で L0 に入れる。
4. 境界時刻 T を決めて L2 の例（`sql/examples/l2_audit_events_v1.sql`）の MV を作り、2 回目の分を入れる。
   T より前の 1 回目の分は `sql/examples/l2_audit_events_v1_backfill.sql` で L0 からバックフィルする。
5. 件数を突き合わせる。

結果は次のように表示されます（件数は乱数で変わります）。

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
10. │ Stuck-row check ignores noise   │ 0        │      0 │ PASS   │
11. │ GCE ServiceName is the VM name  │ 0        │      0 │ PASS   │
   └─────────────────────────────────┴──────────┴────────┴────────┘
```

- 2 と 3：Lease の更新は L1 に入らず、件数だけがノイズの集計テーブルに残ります。
- 4：L3 の合計は L1 の行数と一致します。
- 5 と 6：L2 は、MV で入った分とバックフィルの分を合わせて L1 の監査ログと同じ件数になり、重複もありません。
- 9：2 文字ずつの全文検索インデックスで「タイムアウト」を探した件数が、LIKE で数えた件数と一致します。
  合成ログには、別の並びで同じ 2 文字の断片を含む本文がないためです（[設計](design.md) の「日本語の検索」）。
- 10：`verify/checks.sql` の 2 番（L1 に届いていない行）は、ノイズとして外した行を数えません。
- 11：Compute Engine のログの ServiceName は、VM の名前になります。

### 1-3. データとクエリを確認する

`WORKDIR` を指定して実行すると、データベースが残ります。

```bash
q() { TZ=UTC clickhouse local --path /tmp/gcl-handson/db -q "$1"; }
```

**L1 の ServiceName**：ログの種類ごとに、定義した規則に従って設定されます。

```bash
q "SELECT ResourceType, ServiceName, count() FROM gcl.gcl_logs_v1 GROUP BY ALL ORDER BY 3 DESC LIMIT 10"
```

**日本語の検索**：ClickStack が検索窓の語から作る条件と同じ形です。

```bash
q "SELECT Body FROM gcl.gcl_logs_v1 WHERE hasAllTokens(lower(Body), lower('タイムアウト')) LIMIT 3"
q "EXPLAIN indexes = 1 SELECT count() FROM gcl.gcl_logs_v1 WHERE hasAllTokens(lower(Body), 'タイムアウト')"
```

EXPLAIN の Skip 欄に `idx_lower_body` と、2 文字ずつに分けた語（`タイ`、`イム` など）が出ます。

**L1 で値を取り出す**：型付きテーブルを作らなくても、属性と列から表を作れます。

```bash
q "SELECT ServiceName, round(quantile(0.95)(HttpLatencySeconds), 3) AS p95_s, countIf(HttpStatus >= 500) AS errors
   FROM gcl.gcl_logs_v1 WHERE HttpMethod != '' GROUP BY ALL ORDER BY p95_s DESC"
q "SELECT LogAttributes['audit.principalEmail'] AS who, LogAttributes['audit.methodName'] AS what, count()
   FROM gcl.gcl_logs_v1 WHERE mapContains(LogAttributes, 'audit.methodName') GROUP BY ALL ORDER BY 3 DESC"
```

**L2 との比較**：L2 から同じ情報を取り出す例です。
L2 は操作者の順に並んでいるため、操作者で絞り込むクエリでは読み取り量を減らせます。

```bash
q "SELECT Principal, MethodName, count() FROM gcl.audit_events_v1 GROUP BY ALL ORDER BY 3 DESC"
```

**ノイズの件数**：L1 から外したログは、規則ごとの分単位の件数として残ります。

```bash
q "SELECT Rule, Principal, sum(Cnt) FROM gcl.gcl_noise_1m_v1 GROUP BY ALL ORDER BY 3 DESC"
```

終わったら `rm -rf /tmp/gcl-handson` で削除します。

## 第 2 部：実環境で動かす

検証用のプロジェクトとサービスで行います。
本番のプロジェクトで行うと、そのプロジェクトの全ログがトピックに送られ、Pub/Sub の料金がかかります。

### 2-1. 準備

- 検証用の Google Cloud プロジェクトと、ClickHouse Cloud のサービス（26.6 以降）
- [導入](setup.md) の「前提」と「1. 認証」
- 第 1 部の `clickhouse`（`verify/completeness.sh` が使う）
- 合成ログを公開するアカウントに、トピックへの公開権限（`roles/pubsub.publisher`。プロジェクトのオーナーや編集者なら付いている）。
  `loadgen/gen_logentry.py` は `gcloud auth application-default print-access-token` のトークン（導入の「1. 認証」の ADC）を使います。

### 2-2. 環境を構築する

```bash
cd terraform
cat > terraform.tfvars <<'EOF'
gcp_project_id        = "<sandbox project>"
clickhouse_service_id = "<service id>"
topic_storage_regions = ["<service region, e.g. asia-northeast1>"]
EOF
terraform init
terraform apply
terraform output clickpipe_state   # Running
```

### 2-3. 合成ログを送信する

ハンズオンでは、シンクが送る実際のログに加えて、合成ログをトピックに直接公開します。
`--ids-out` に、公開したメッセージの ID が残ります。

```bash
cd ..
python3 loadgen/gen_logentry.py --publish projects/<sandbox project>/topics/gcl-to-clickhouse \
  --rate 50 --duration 300 --lease-rate 0.2 --dup-rate 0.01 --ids-out sent_ids.txt
```

### 2-4. 欠損と重複を確認する

```bash
export CH_SERVICE_ID=<service id>
verify/completeness.sh sent_ids.txt
```

`missing_in_l0` が 0 なら、公開したメッセージはすべて L0 に届いています。
`missing_in_l1` は、L1 に入れない Lease の更新の件数になります。
Lease の更新を混ぜずに確かめるときは、`--lease-rate` を指定せずに送信し、`missing_in_l1` が 0 になることを確認します。
`--dup-rate` で同じ内容を再送した分は、Pub/Sub が別の `MessageId` を付けるので、`dup_ids_*` には数えません。
`dup_ids_*` は、Pub/Sub の再配信（同じ `MessageId` が 2 回届く）の件数です。
再配信は起きることがあり（検証では 0〜3%）、0 にならなくても欠損ではありません。

### 2-5. ClickStack で検索する

[導入](setup.md) の「4. ClickStack のソースを作る（任意）」でソースとダッシュボードを作り、ClickStack を開きます。

1. ソース「Cloud Logging」を選び、検索窓に `タイムアウト` と入れる。
   本文にその語を含むログが出る。
2. 左のフィルタで ServiceName を `web-frontend` に絞る。
3. Event Patterns に切り替え、本文の形ごとの件数を見る。
   Lease の更新は L1 に入っていないので、上位に出ない。
4. ダッシュボード「Cloud Logging overview」を開く。

### 2-6. L2 を追加する

監査ログの操作者で絞る表を、L2 として追加します。
境界時刻 T は作業時刻の数分先に設定します。

```bash
T=$(date -u -v+3M +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u -d '+3 min' +"%Y-%m-%d %H:%M:%S")
python3 tools/chq.py --var LOGS_TTL_DAYS=400 --var MV_DEFINER=default --var T="$T" sql/examples/l2_audit_events_v1.sql
```

T 以降に公開された監査ログは、MV が L2 に書き込みます。
T を過ぎてから、T より前の分を L0 からバックフィルします。
同じファイルの末尾で、L2 と L1 の集計を並べて出します。

```bash
while [[ "$(date -u +"%Y-%m-%d %H:%M:%S")" < "$T" ]]; do sleep 10; done   # T を過ぎるまで待つ
python3 tools/chq.py --var T="$T" sql/examples/l2_audit_events_v1_backfill.sql
python3 tools/chq.py -q "SELECT
  (SELECT uniqExact(MessageId) FROM gcl.audit_events_v1) AS l2,
  (SELECT uniqExact(MessageId) FROM gcl.gcl_logs_v1 WHERE mapContains(LogAttributes, 'audit.methodName')) AS l1_audit"
```

Pub/Sub の再配信で L1 に同じ `MessageId` の行が入ることがあるので、行数ではなく `MessageId` の種類の数で比べます。

手順の詳細と作り替えの方法は [運用](operations.md) の「L2 の新規作成と作り替え」にあります。

### 2-7. L3 を追加する

ログ ID（`LogId`）ごとの分単位の件数を、L3 として追加します。
L2 と同じく、MV を作ってから T を過ぎるのを待ち、T より前のデータをバックフィルします。

```bash
T=$(date -u -v+3M +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u -d '+3 min' +"%Y-%m-%d %H:%M:%S")
python3 tools/chq.py --var L3=logs_by_logid_1m_v1 --var L3_TTL_DAYS=400 --var MV_DEFINER=default --var T="$T" sql/runbooks/09_add_l3.sql
while [[ "$(date -u +"%Y-%m-%d %H:%M:%S")" < "$T" ]]; do sleep 10; done   # T を過ぎるまで待つ
python3 tools/chq.py --var L3=logs_by_logid_1m_v1 --var T="$T" --var CHECK_TO="$(date -u +'%Y-%m-%d %H:%M:00')" \
  sql/runbooks/09_add_l3_backfill.sql
```

最後に表示される 2 つの値（L3 の合計と L1 の行数）が一致します。
手順は [運用](operations.md) の「L3 の追加」にあります。

### 2-8. リソースを削除する

```bash
cd terraform && terraform destroy && cd ..
python3 tools/chq.py -q "DROP DATABASE IF EXISTS gcl SYNC"
rm -f sent_ids.txt
```

先にパイプを削除してから、データベースを削除します。
`terraform destroy` は、ClickPipes が管理サブスクリプションを削除し終えるのを待ってから、鍵と権限を削除します。
シンクを削除すると、トピックへの送出も止まります。
続けて第 3 部を行う場合も、ここで削除してから始めます（第 3 部も同じデータベース `gcl` を使います）。


## 第 3 部：gcloud と clickhousectl で 1 つずつ作る

第 2 部で Terraform が作ったものを、コマンドで 1 つずつ作ります。
各手順で、何をなぜ作るのかを確かめます。
導入には、このコマンドではなく [導入](setup.md) の Terraform を使います。
Terraform は作ったものを state で管理するので、削除のときに作ったものだけを消せます。

リソースの名前には `handson` を付け、第 2 部や既存のリソースと重ならないようにします。
第 2 部のリソースは、2-8 で削除してから始めます。

### 3-1. 準備

第 2 部の 2-1 と同じです。
加えて、`gcloud auth login` で gcloud にログインします（Terraform が使う ADC とは別の認証です）。

```bash
P=<sandbox project>
export CH_SERVICE_ID=<service id>
TOPIC=gcl-handson
SINK=gcl-handson
SA=clickpipes-handson
SA_EMAIL=$SA@$P.iam.gserviceaccount.com
ROLE=clickpipesHandson
KEY=handson-key.json
REGION=asia-northeast1   # ClickHouse Cloud のサービスのリージョン
```

### 3-2. トピック

```bash
gcloud pubsub topics create $TOPIC --project $P --message-storage-policy-allowed-regions=$REGION
```

シンクの送信先です。
メッセージ保持は設定せず、保存先は ClickHouse Cloud のサービスと同じリージョンに限定します。
再処理の元データは ClickHouse の L0 に残すためです（[設計](design.md) の「Pub/Sub と ClickPipes」）。

### 3-3. シンクと公開権限

```bash
gcloud logging sinks create $SINK pubsub.googleapis.com/projects/$P/topics/$TOPIC \
  --project $P --log-filter="logName:\"projects/$P/logs/\""
W=$(gcloud logging sinks describe $SINK --project $P --format='value(writerIdentity)')
echo $W
gcloud pubsub topics add-iam-policy-binding $TOPIC --project $P --member="$W" --role=roles/pubsub.publisher
```

シンクは、作成した時点からプロジェクトの全ログをトピックへ送ります。
シンクは書き込み用 ID（`writerIdentity`）で公開するので、その ID にトピックへの公開権限を付けます。
書き込み用 ID は、Cloud Logging がプロジェクトごとに 1 つ作り、同じプロジェクトのシンクで共有するサービスアカウントです（`service-<プロジェクト番号>@gcp-sa-logging.iam.gserviceaccount.com`）。
権限を付けるまでの間、シンクは公開に失敗し、その分のログはトピックに届きません。

### 3-4. ClickPipes 用のロール、サービスアカウント、鍵

```bash
gcloud iam roles create $ROLE --project $P --title="ClickPipes Pub/Sub ingestion (hands-on)" \
  --permissions=pubsub.topics.list,pubsub.topics.get,pubsub.topics.attachSubscription,pubsub.subscriptions.create,pubsub.subscriptions.get,pubsub.subscriptions.delete,pubsub.subscriptions.consume
gcloud iam service-accounts create $SA --project $P
gcloud projects add-iam-policy-binding $P --member="serviceAccount:$SA_EMAIL" \
  --role="projects/$P/roles/$ROLE" --condition=None
until gcloud iam service-accounts keys create $KEY --iam-account=$SA_EMAIL; do sleep 10; done   # 作った直後は NOT_FOUND になることがあるので、反映を待ってやり直す
```

サービスアカウントは、作った直後は鍵の作成から見えないことがあります（検証では `NOT_FOUND` になりました）。
最後の行は、成功するまで 10 秒おきにやり直します。

権限は公式の最小権限ロールと同じです（[Pub/Sub IAM permissions](https://clickhouse.com/docs/integrations/clickpipes/pubsub/auth)）。
ClickPipes は管理サブスクリプション（`clickpipes-<パイプ ID>`）を自分で作って消すので、サブスクリプションの作成と削除の権限が要ります。
鍵ファイルはトピックを読むための認証情報です。
パスワードと同じように扱い、Git に入れません（`.gitignore` で `*.json` を除外しています）。

### 3-5. テーブルと MV

```bash
python3 tools/chq.py --var LANDING_TTL_DAYS=7 --var LOGS_TTL_DAYS=400 --var MV_DEFINER=default \
  sql/10_landing_v1.sql sql/20_logs_v1.sql sql/30_logs_v1_mv.sql sql/40_rollup_1m_v1.sql sql/50_noise_rollup_v1.sql
```

パイプより先に作ります。
パイプは既存の L0 に書き込み、L1 以降は MV が作ります。
`tools/chq.py` は Query API を使うので、30 秒を超える文は応答が切れます（サーバー側では実行が続きます）。
大量のバックフィルは、`clickhouse client` のネイティブ接続で実行します。

### 3-6. ClickPipe

```bash
clickhousectl cloud clickpipe create pubsub "$CH_SERVICE_ID" \
  --name gcl-handson --topic $TOPIC --project-id $P --format JSONEachRow \
  --service-account-file $KEY --seek-type latest \
  --database gcl --table gcl_landing_v1 \
  --column "_raw_message:String" --column "_message_id:String" \
  --column "_publish_time:DateTime64(3)" --column "_attributes:Map(String, String)"
clickhousectl cloud clickpipe list "$CH_SERVICE_ID"
PIPE_ID=<list に出た gcl-handson の ID>
clickhousectl cloud clickpipe get "$CH_SERVICE_ID" $PIPE_ID   # state が Running になるまで待つ
```

パイプは Pub/Sub の仮想列（生メッセージ、メッセージ ID、公開時刻、属性）だけを L0 に書きます。
作成時にパイプが管理サブスクリプションを作ります。
保持 7 日、ack 期限 60 秒、順序付けが有効です。
作成が権限の不足で失敗した場合は、IAM の反映を 1〜2 分待ってから作り直します。

### 3-7. ClickStack のソース

ClickStack の Team Settings の Sources で、ログソースを作ります。
画面の項目と入れる値は、[ブラウザで導入する](setup-console.md) の「8. ClickStack のソースを作る」にあります。
次の JSON は、同じ設定を API の項目名で表したものです（`terraform/clickstack.tf` と同じ値）。
ダッシュボードは Terraform でだけ作ります（`terraform/clickstack/dashboard.json.tftpl`）。

```json
{
  "kind": "log",
  "name": "Cloud Logging (hands-on)",
  "databaseName": "gcl",
  "tableName": "gcl_logs_v1",
  "timestampValueExpression": "Timestamp",
  "displayedTimestampValueExpression": "Timestamp",
  "defaultTableSelectExpression": "Timestamp, ServiceName, SeverityText, ResourceType, Body",
  "serviceNameExpression": "ServiceName",
  "severityTextExpression": "SeverityText",
  "bodyExpression": "Body",
  "eventAttributesExpression": "LogAttributes",
  "resourceAttributesExpression": "ResourceAttributes",
  "traceIdExpression": "TraceId",
  "spanIdExpression": "SpanId",
  "implicitColumnExpression": "Body",
  "useTextIndexForImplicitColumn": "auto",
  "highlightedRowAttributeExpressions": [
    { "sqlExpression": "ResourceType", "alias": "type" },
    { "sqlExpression": "LogId", "alias": "log" },
    { "sqlExpression": "ProjectId", "alias": "project" }
  ]
}
```

`useTextIndexForImplicitColumn` を `auto` にすると、検索窓の語が `lower(Body)` のテキストインデックスを使う条件になります。
日本語の検索には、このインデックスが必要です。

### 3-8. 確かめる

第 2 部の 2-3 と 2-4 を、トピック名を `$TOPIC` に替えて実行します。

```bash
python3 loadgen/gen_logentry.py --publish projects/$P/topics/$TOPIC --rate 50 --duration 120 --ids-out sent_ids.txt
verify/completeness.sh sent_ids.txt
```

`missing_in_l0` と `missing_in_l1` が 0 になります。

### 3-9. 作ったものを削除する

第 3 部で作った名前のものだけを、作った順の逆に削除します。

```bash
clickhousectl cloud clickpipe delete "$CH_SERVICE_ID" $PIPE_ID
python3 tools/wait_subscriptions_gone.py --project $P --topic $TOPIC   # 管理サブスクリプションが消えるのを待つ
python3 tools/chq.py -q "DROP DATABASE IF EXISTS gcl SYNC"
gcloud logging sinks delete $SINK --project $P
gcloud pubsub topics delete $TOPIC --project $P
gcloud projects remove-iam-policy-binding $P --member="serviceAccount:$SA_EMAIL" \
  --role="projects/$P/roles/$ROLE" --condition=None
gcloud iam service-accounts delete $SA_EMAIL --project $P
gcloud iam roles delete $ROLE --project $P
rm -f $KEY sent_ids.txt
```

パイプの削除は即座に返り、ClickPipes はそのあとでサービスアカウントを使って管理サブスクリプションを消します。
消える前に権限やサービスアカウントを削除すると、管理サブスクリプションが削除済みのトピックを指したまま残るので、2 行目で待ちます。
ClickStack のソースは画面から削除します。
サービスアカウントを削除すると、その鍵も無効になります。
削除したカスタムロールは 7 日以内なら復元でき、完全に削除されるまで同じ ID では作り直せません。
もう一度試すときは `ROLE` の値を変えます。
