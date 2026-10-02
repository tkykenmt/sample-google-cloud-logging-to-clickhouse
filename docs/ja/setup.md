# 導入

[English](../en/setup.md) | 日本語

Terraform で Google Cloud 側のリソース、ClickHouse のテーブルと MV、ClickPipe、ClickStack のソースとダッシュボードを作ります。
Terraform を使えない環境では、同じ構成を `cli/deploy.sh`（gcloud と clickhousectl）で構築できます（「clickhousectl と gcloud で構築する」を参照）。
設計の理由は [設計](design.md)、動作を確認する手順は [ハンズオン](hands-on.md) にあります。

## 作成するリソース

| 場所 | リソース | 役割 | 定義 |
|---|---|---|---|
| Google Cloud | Pub/Sub トピック | シンクの送信先。メッセージ保持は設定しない | `terraform/gcp.tf` |
| Google Cloud | Log Router のシンク | プロジェクトの全ログをトピックへ送る | `terraform/gcp.tf` |
| Google Cloud | トピックの IAM | シンクの書き込み用 ID にメッセージの公開権限を付与する | `terraform/gcp.tf` |
| Google Cloud | カスタムロールとサービスアカウント、鍵 | ClickPipes がトピックを読み、管理サブスクリプションを作る | `terraform/gcp.tf` |
| ClickHouse Cloud | データベース `gcl` のテーブルと MV | L0、L1、MV1、L3（分単位の件数）、ノイズの件数 | `sql/10`〜`sql/50` |
| ClickHouse Cloud | ClickPipe | トピックを L0 に取り込む | `terraform/clickhouse.tf` |
| ClickStack | ログソースとダッシュボード | L1 を検索・可視化する（任意） | `terraform/clickstack.tf` |

テーブルと MV は、Terraform から `tools/chq.py` を呼び出し、`sql/` のファイルを実行して作成します。
ClickHouse の Terraform プロバイダには DDL を実行するリソースがないためです。
どの文も `CREATE ... IF NOT EXISTS` なので、再実行しても既存のテーブルは変わりません。

## 前提

- ClickHouse Cloud のサービス（26.6 以降）。トピックのメッセージを保存するリージョンと同じリージョンに置きます。
- ClickHouse Cloud の API キー（書き込みができる権限）と組織 ID。
- Google Cloud のプロジェクトで、トピック、シンク、サービスアカウント、カスタムロール、IAM を作れる権限。
- ローカル環境に Terraform 1.5 以降、`gcloud`、`python3`、`clickhousectl`。
- サービスアカウントの鍵の作成を組織のポリシー（`iam.disableServiceAccountKeyCreation`）で禁止している場合は、許可された手順で作った鍵ファイルを用意します（`service_account_key_file`）。

## 手順

### 1. 認証

```bash
gcloud auth application-default login

# Terraform の ClickHouse プロバイダと clickhousectl が同じ変数を読む
export CLICKHOUSE_ORG_ID=<organization id>
export CLICKHOUSE_CLOUD_API_KEY=<key id>
export CLICKHOUSE_CLOUD_API_SECRET=<key secret>
```

### 2. 変数

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

主な変数です。
すべての変数と既定値は `terraform/variables.tf` にあります。

| 変数 | 既定値 | 決め方 |
|---|---|---|
| `gcp_project_id` | ― | ログを送るプロジェクト |
| `clickhouse_service_id` | ― | 取り込み先のサービス |
| `sink_filter` | プロジェクトの全ログ | 種類の絞り込みは ClickHouse 側で行うので、通常は変えない |
| `sink_exclusions` | なし | 量が多く ClickHouse で検索しないノイズを、シンクで除外する場合 |
| `topic_storage_regions` | 制限なし | ClickHouse Cloud と同じリージョンに固定するとき |
| `landing_ttl_days` | 7 | 取り込みの遅延、切り替えとバックフィル、照合とロールバックに必要な期間に余裕を加える |
| `logs_ttl_days` | 400 | ログの保持要件 |
| `pipe_replicas` など | 1 レプリカ、最小サイズ | 取り込み量と遅延を測って増やす |
| `clickstack_connection_id` | なし | ClickStack のソースとダッシュボードを作るとき（下の 4） |

### 3. 適用

```bash
terraform init
terraform plan
terraform apply
```

適用の順番は次のとおりです。

1. トピック、シンク、IAM、サービスアカウントを作る。
2. `sql/10`〜`sql/50` を実行し、テーブルと MV を作成する（`apply_schema = false` の場合はスキップする）。
3. 既存の L0 を宛先にして ClickPipe を作る。

サービスアカウントの鍵を Terraform で作ると、鍵は Terraform の state に保存されます。
state も鍵と同等の機密情報として保管します。

### 4. ClickStack のソース（任意）

ClickStack の Team Settings の Connections で、このサービスへの接続の ID を調べます。
`terraform.tfvars` に `clickstack_connection_id` を入れて、もう一度適用すると、L1 のログソースとサンプルのダッシュボードが作成されます。

```bash
terraform apply -var clickstack_connection_id=<connection id>
```

### 5. 動作を確認する

```bash
terraform output clickpipe_state   # Running

# 遅延、詰まったバッチ、重複、遅延到着、解析の状態など（tools/chq.py は CH_SERVICE_ID を読む）
export CH_SERVICE_ID=<service id>
python3 tools/chq.py verify/checks.sql
```

シンクから届いたログが L0 と L1 に入っていれば、取り込みは動いています。
定期的な確認項目は [運用](operations.md) の「日常の確認」にあります。

## 本番ログへ切り替える流れ

Pub/Sub へのシンクを追加し、並走させてから `_Default` への保存を止めます。

1. 並走：Pub/Sub へのシンクを追加し、`_Default` への保存も続ける。
2. 突き合わせ：シンクの送出件数と ClickHouse の取り込み件数を比べ、ClickStack で日常の検索ができることを確かめる。
3. 棚卸し：`_Default` に保存されたログを利用する機能を洗い出し、ClickStack へ移すか、そのログだけ `_Default` に残すかを決める（[設計](design.md) の「_Default バケットへの保存を止めると変わるもの」）。
4. 切り替え：`_Default` のシンクに除外フィルタを入れるか、シンクを無効にして、新しいログを `_Default` に入れないようにする。フィルタを外せば戻せる。

`_Default` のシンクは、このリポジトリの Terraform では管理しません。
切り替えは利用者の環境で定めた手順で行います。

## clickhousectl と gcloud で構築する（Terraform を使わない場合）

Terraform を使えない環境では、`cli/deploy.sh` が `gcloud` と `clickhousectl` で同じ構成を作ります。
リソースの名前と既定値は Terraform と同じです。
各手順では、既存のリソースの作成をスキップします。
途中で失敗しても、原因を解消してから同じコマンドを再実行できます。

```bash
cp cli/env.example cli/.env      # GCP_PROJECT_ID と CH_SERVICE_ID を入れる
gcloud auth login
export CLICKHOUSE_CLOUD_API_KEY=<key id> CLICKHOUSE_CLOUD_API_SECRET=<key secret>

DRY_RUN=1 cli/deploy.sh          # 変更するコマンドを表示するだけ
cli/deploy.sh
```

スクリプトは次の順に進み、最後にパイプが Running になるのを待ちます。

1. Pub/Sub トピック（メッセージ保持なし）
2. Log Router のシンクと、その書き込み用 ID に対するトピックへのメッセージ公開権限
3. ClickPipes 用のカスタムロール、サービスアカウント、鍵ファイル（`KEY_FILE` が既にあれば作らない）
4. `sql/10`〜`sql/50` のテーブルと MV（`tools/chq.py`）
5. ClickPipe（既存の L0 を宛先にする）

- 鍵ファイルは、トピックの読み取りに使う認証情報です。パスワードと同等の機密情報として保管します。
- 組織のポリシーで鍵の作成が禁止されている場合は、許可された手順で作った鍵を `KEY_FILE` に指定します。
- ClickStack のソースは、下の「ClickStack のソース」の項目を画面で設定します（入力は 1 画面です）。
- 削除は `cli/destroy.sh` です。ClickHouse のデータベースは `DROP_DATABASE=1` を指定した場合にのみ削除します。削除したカスタムロールの ID は数週間再利用できないので、`cli/deploy.sh` は削除済みのロールを復元して使います。

スクリプトが実行するコマンドは、次の節のとおりです。

## 個々のコマンドと設定

値は Terraform の既定値に合わせています。

### シンク、トピック、権限

```bash
P=<project>; T=gcl-to-clickhouse; S=gcl-to-clickhouse

gcloud pubsub topics create $T --project $P
gcloud logging sinks create $S pubsub.googleapis.com/projects/$P/topics/$T \
  --project $P --log-filter="logName:\"projects/$P/logs/\""
W=$(gcloud logging sinks describe $S --project $P --format='value(writerIdentity)')
gcloud pubsub topics add-iam-policy-binding $T --project $P --member="$W" --role=roles/pubsub.publisher

gcloud iam roles create clickpipesPubsubIngestion --project $P --title="ClickPipes Pub/Sub ingestion" \
  --permissions=pubsub.subscriptions.consume,pubsub.subscriptions.create,pubsub.subscriptions.delete,pubsub.subscriptions.get,pubsub.topics.attachSubscription,pubsub.topics.get,pubsub.topics.list
gcloud iam service-accounts create clickpipes-gcl --project $P
gcloud projects add-iam-policy-binding $P \
  --member="serviceAccount:clickpipes-gcl@$P.iam.gserviceaccount.com" --role="projects/$P/roles/clickpipesPubsubIngestion"
gcloud iam service-accounts keys create clickpipes-key.json --iam-account="clickpipes-gcl@$P.iam.gserviceaccount.com"
```

Cloud Logging API で表したシンクは次の形です。

```json
{
  "name": "gcl-to-clickhouse",
  "destination": "pubsub.googleapis.com/projects/<project>/topics/gcl-to-clickhouse",
  "filter": "logName:\"projects/<project>/logs/\"",
  "writerIdentity": "serviceAccount:service-<project-number>@gcp-sa-logging.iam.gserviceaccount.com"
}
```

複数のプロジェクトをまとめる場合は、`organizations/<org>/sinks` または `folders/<folder>/sinks` に作り、`"includeChildren": true` を付けます。（公式資料）

### テーブルと MV

```bash
export CH_SERVICE_ID=<service id>
python3 tools/chq.py --var LANDING_TTL_DAYS=7 --var LOGS_TTL_DAYS=400 --var MV_DEFINER=default \
  sql/10_landing_v1.sql sql/20_logs_v1.sql sql/30_logs_v1_mv.sql sql/40_rollup_1m_v1.sql sql/50_noise_rollup_v1.sql
```

`tools/chq.py` は Query API を使うので、30 秒を超える文は応答がタイムアウトします（サーバー側では実行が続きます）。
大量のデータをバックフィルする場合は、`clickhouse client` のネイティブ接続で実行します。

### ClickPipe

```bash
clickhousectl cloud clickpipe create pubsub "$CH_SERVICE_ID" \
  --name gcl-v1 --topic gcl-to-clickhouse --project-id <project> --format JSONEachRow \
  --service-account-file clickpipes-key.json --seek-type latest \
  --database gcl --table gcl_landing_v1 \
  --column "_raw_message:String" --column "_message_id:String" \
  --column "_publish_time:DateTime64(3)" --column "_attributes:Map(String, String)"
```

パイプが作る管理サブスクリプションは `clickpipes-<パイプ ID>` という名前で、保持 7 日、ack 期限 60 秒、順序付けが有効です。
利用者が作成する必要はありません。

### ClickStack のソース

画面の Team Settings の Sources で、次の項目を設定します。

```json
{
  "kind": "log",
  "name": "Cloud Logging",
  "databaseName": "gcl",
  "tableName": "gcl_logs_v1",
  "timestampValueExpression": "Timestamp",
  "defaultTableSelectExpression": "Timestamp, ServiceName, SeverityText, ResourceType, Body",
  "serviceNameExpression": "ServiceName",
  "severityTextExpression": "SeverityText",
  "bodyExpression": "Body",
  "eventAttributesExpression": "LogAttributes",
  "resourceAttributesExpression": "ResourceAttributes",
  "traceIdExpression": "TraceId",
  "spanIdExpression": "SpanId",
  "implicitColumnExpression": "Body"
}
```

## リソースの削除

```bash
terraform destroy
```

- ClickPipe を削除すると、管理サブスクリプションも削除されます。
- `sql/` で作ったデータベース `gcl` は Terraform の管理外なので残ります。不要なら `DROP DATABASE gcl` で削除します。
- 止めただけのパイプは管理サブスクリプションを残し、メッセージが蓄積し続けます。使わないパイプは削除します。
