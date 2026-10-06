# 導入

[English](../en/setup.md) | 日本語

Terraform で、Google Cloud 側のリソース、ClickHouse のテーブルと MV、ClickPipe、ClickStack のソースとダッシュボードを作ります。
Terraform を使う場合は、このページの「手順」の節だけを実行します。
Terraform を使えない場合は、同じ構成を画面だけで作る [ブラウザで導入する](setup-console.md) を使います（どちらか一方だけを実行します）。
gcloud と clickhousectl で 1 つずつ作りながら仕組みを確かめる手順は、[ハンズオン](hands-on.md) の第 3 部にあります。
設計の理由は [設計](design.md) にあります。

## 始める前に

- **まず検証用のプロジェクトで試します。**
  `terraform apply` を実行した時点から、シンクはプロジェクトの全ログをトピックへ送ります。
- **Pub/Sub の料金がかかります。**
  検証環境では、Pub/Sub に送った量が Cloud Logging の課金対象の約 5 倍になりました（[検証記録](findings.md) の「Pub/Sub の課金対象量」）。
  差の大半は、Cloud Logging が課金しない `_Required` 行きの監査ログでした（課金対象のログだけなら約 1.2 倍）。
  量の多いノイズは、`sink_exclusions` でシンクから除外できます。
- **サービスアカウントの鍵は Terraform の state に保存されます。**
  state は、暗号化したリモートのバックエンドに、アクセスを絞って置きます（`terraform/terraform.tf` に例があります）。
- **ClickPipes の権限はプロジェクト全体に及びます。**
  公式の最小権限ロール（[Pub/Sub IAM permissions](https://clickhouse.com/docs/integrations/clickpipes/pubsub/auth)）は、プロジェクト内のサブスクリプションの作成、受信、削除を許します。
  範囲が広すぎる場合は、ログの送出専用のプロジェクトにトピックを置きます。
- **既存の `_Default` バケットへの保存は変わりません。**
  保存を止める作業は導入に含めず、[運用](operations.md) の「本番ログへ切り替える」で扱います。

## 作成するリソース

| 場所 | リソース | 役割 | 定義 |
|---|---|---|---|
| Google Cloud | Pub/Sub トピック | シンクの送信先。メッセージ保持は設定しない | `terraform/gcp.tf` |
| Google Cloud | Log Router のシンク | プロジェクトの全ログ（既定）をトピックへ送る | `terraform/gcp.tf` |
| Google Cloud | トピックの IAM | シンクの書き込み用 ID にメッセージの公開権限を付与する | `terraform/gcp.tf` |
| Google Cloud | カスタムロール、サービスアカウント、鍵 | ClickPipes がトピックを読み、管理サブスクリプションを作る | `terraform/gcp.tf` |
| ClickHouse Cloud | データベース `gcl` のテーブルと MV | L0、L1、MV1、L3（分単位の件数）、ノイズの件数 | `sql/10`〜`sql/50` |
| ClickHouse Cloud | ClickPipe | トピックを L0 に取り込む | `terraform/clickhouse.tf` |
| ClickStack | ログソースとダッシュボード | L1 を検索・可視化する（任意） | `terraform/clickstack.tf` |

テーブルと MV は、Terraform から `tools/chq.py` を呼び出し、`sql/` のファイルを実行して作成します。
ClickHouse の Terraform プロバイダには DDL を実行するリソースがないためです。
どの文も `CREATE ... IF NOT EXISTS` なので、再実行しても既存のテーブルは変わりません。
そのため、作成後に TTL などの値を変えても、既存のテーブルには反映されません（「作成後に設定を変える」を参照）。

## 前提

- ClickHouse Cloud のサービス（26.6 以降）。
  トピックのメッセージの保存先は、`topic_storage_regions` でこのサービスと同じリージョンに限定します（手順 2）。
- ClickHouse Cloud の API キー（書き込みができる権限）と組織 ID。
- Google Cloud のプロジェクトで、トピック、シンク、サービスアカウント、カスタムロール、IAM を作れる権限。
- プロジェクトで Pub/Sub、Cloud Logging、IAM の API が有効になっていること（手順 1）。
- ローカル環境に Terraform 1.9 以降、`gcloud`、`python3`、`clickhousectl`。
- `tools/chq.py` を初めて実行すると、`clickhousectl` がそのサービスに Query API のエンドポイントとキーを作ります（`Provisioning Query API endpoint + key` と表示されます）。
- サービスアカウントの鍵の作成を組織のポリシー（`iam.disableServiceAccountKeyCreation`）で禁止している場合は、許可された手順で作った鍵ファイルを用意します（`service_account_key_file`）。

## 手順

### 1. 認証

```bash
# Terraform の google プロバイダが使う認証情報（Application Default Credentials）
gcloud auth application-default login

# 使う API を有効にする（有効になっていれば何もしない）
gcloud services enable pubsub.googleapis.com logging.googleapis.com iam.googleapis.com --project <project>

# Terraform の ClickHouse プロバイダは 3 つとも読み、clickhousectl（tools/chq.py が呼ぶ）は API キーの 2 つを読む
export CLICKHOUSE_ORG_ID=<organization id>
export CLICKHOUSE_CLOUD_API_KEY=<key id>
export CLICKHOUSE_CLOUD_API_SECRET=<key secret>
clickhousectl cloud service get <service id>   # サービスが見えれば、正しいキーで読めている
```

`clickhousectl` は、カレントディレクトリに `.clickhouse/credentials.json`（`clickhousectl cloud auth login` で保存されるファイル）があると、環境変数よりそちらを優先します。
`tools/chq.py` はリポジトリの最上位のディレクトリで実行し、そこに別の組織の認証情報を置かないようにします。

### 2. 変数を決める

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` を開き、`gcp_project_id` と `clickhouse_service_id` を書き換え、`topic_storage_regions` の行のコメントを外してサービスのリージョンにします。
ほかの値は既定のままで動きます。
主な変数は次のとおりです。
すべての変数と既定値は `terraform/variables.tf` にあり、値の誤りは `terraform plan` の時点で検出されます。

| 変数 | 既定値 | 決め方 |
|---|---|---|
| `gcp_project_id` | ― | ログを送るプロジェクトの ID |
| `clickhouse_service_id` | ― | 取り込み先のサービスの ID |
| `sink_filter` | プロジェクトの全ログ | 種類の絞り込みは ClickHouse 側で行うので、通常は変えない |
| `sink_exclusions` | なし | 量が多く ClickHouse で検索しないノイズを、シンクで除外する場合 |
| `topic_storage_regions` | 制限なし | ClickHouse Cloud のサービスと同じリージョンにする（例 `["asia-northeast1"]`）。リージョンをまたぐと配信に転送料がかかる |
| `topic_kms_key_name` | なし（Google が管理する鍵） | トピックを顧客管理の鍵（CMEK）で暗号化するとき |
| `landing_ttl_days` | 7 | 取り込みの遅延、切り替えとバックフィル、照合とロールバックに必要な期間に余裕を加える |
| `logs_ttl_days` | 400 | ログの保持要件 |
| `pipe_seek_type` | `latest` | 新しい管理サブスクリプションの開始位置。トピックに保持がないので、通常は変えない |
| `pipe_replicas` など | 1 レプリカ、最小サイズ | 取り込み量と遅延を測って増やす |
| `clickstack_connection_id` | なし | ClickStack のソースとダッシュボードを作るとき（下の 4） |

### 3. 計画を確かめてから適用する

```bash
terraform init
terraform plan
```

`plan` の出力で、作られるリソースとシンクのフィルタ（`filter`）を確かめます。
ClickStack を使わない場合、作られるリソースは 10 個です（削除時の待ち合わせ用の `terraform_data.subscription_cleanup` を含む。`service_account_key_file` を指定した場合は 9 個）。

```bash
terraform apply
```

適用は次の順に進みます。

1. トピック、シンク、IAM、サービスアカウントを作る。
2. `sql/10`〜`sql/50` を実行し、テーブルと MV を作成する（`apply_schema = false` の場合はスキップする）。
3. 既存の L0 を宛先にして ClickPipe を作る。

### 4. ClickStack のソースを作る（任意）

ClickStack の Team Settings の Connections で、このサービスへの接続の ID を調べます。
`terraform.tfvars` に `clickstack_connection_id` を書き足して、もう一度適用すると、L1 のログソースとサンプルのダッシュボード「Cloud Logging overview」が作成されます。

```bash
terraform apply
```

### 5. 動作を確認する

```bash
terraform output clickpipe_state   # Running

# 遅延、詰まったバッチ、重複、遅延到着、解析の状態など（tools/chq.py は CH_SERVICE_ID を読む）
cd ..
export CH_SERVICE_ID=<service id>
python3 tools/chq.py verify/checks.sql
```

シンクから届いたログが L0 と L1 に入っていれば、取り込みは動いています。
ここで導入は完了です。
定期的な確認項目は [運用](operations.md) の「日常の確認」にあります。

## 作成後に設定を変える

| 変えるもの | 方法 |
|---|---|
| シンクのフィルタと除外、パイプのサイズ、ClickStack のソース | `terraform.tfvars` を変えて `terraform apply` |
| L0、L1、集計テーブルの TTL | `ALTER TABLE ... MODIFY TTL`（[運用](operations.md) の「保持期間を変える」）。`terraform.tfvars` の値は、作り直すときのために合わせておく |
| L1 の列や解析の内容 | [運用](operations.md) の手順（MV の `MODIFY QUERY`） |

## リソースを削除する

```bash
cd terraform
terraform destroy
cd ..
export CH_SERVICE_ID=<service id>
python3 tools/chq.py -q "DROP DATABASE IF EXISTS gcl SYNC"
```

- `terraform destroy` は、Terraform が作ったリソースだけを削除します。
- 先にパイプを削除してからデータベースを削除します。
  逆の順だと、削除までの間にパイプの INSERT が失敗し続けます。
- ClickPipe を削除すると、ClickPipes が管理サブスクリプションを非同期で削除します。
  `terraform destroy` は、その削除が終わるのを待ってから（`tools/wait_subscriptions_gone.py`、最大 5 分）、鍵と権限を削除します。
  待たずに鍵や権限を消すと、管理サブスクリプションが削除済みのトピック（`_deleted-topic_`）を指したまま残りました。
  5 分を過ぎても消えない場合、destroy は警告を出して先へ進みます。
  表示された `gcloud pubsub subscriptions delete` のコマンドで、残った管理サブスクリプションを削除します。
- `sql/` で作ったデータベース `gcl` は Terraform の管理外なので、`DROP DATABASE` で削除します。
- 削除したカスタムロールは削除済みの状態で残り、7 日以内なら復元できます。
  完全に削除されるまで、同じ ID では作り直せません（[カスタムロールの削除](https://cloud.google.com/iam/docs/creating-custom-roles#deleting-custom-role)）。
  続けて試す場合は `clickpipes_role_id` を変えます。
