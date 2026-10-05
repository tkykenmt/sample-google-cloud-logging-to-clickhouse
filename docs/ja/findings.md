# 検証記録

[English](../en/findings.md) | 日本語

2026-10-01〜02 に ClickHouse Cloud と Google Cloud の検証環境で確かめた結果です。
Pub/Sub ClickPipes は Private Preview の段階にあり、ClickHouse Cloud も自動でバージョンが更新されるため、ここに記載した挙動は将来変わる可能性があります。

## 環境

| 項目 | 値 |
|---|---|
| ClickHouse Cloud | GCP asia-northeast1、1 レプリカ、メモリ 8〜32 GiB の自動スケール、リリースチャンネル fast、26.6.1.2191 |
| ClickPipes | Pub/Sub、JSONEachRow、1 レプリカ（0.125 vCPU、0.5 GB）、`clickhousectl` で作成 |
| Pub/Sub | 検証専用トピック、メッセージ保持 7 日 |
| 入力 | `loadgen/gen_logentry.py` の合成 LogEntry（平均 711 バイト。遅延 2%、未来 0.2%、timestamp 欠落 0.2%、同一エントリの再送 0.5% を含む） |
| 実ログ | 自社 GCP プロジェクトの Cloud Logging（監査ログが大半、平均約 1.5 KB）。解析の正しさと CPU の比較だけに使った |
| ローカル | clickhouse local 26.7.7.19 |

完全性は、負荷発生器が Pub/Sub の応答から記録したメッセージ ID の全件と、L0 と L1 の `MessageId` を `verify/completeness.sh` で突き合わせて確かめました。

## パイプの作成と宛先

| 問い | 結果 |
|---|---|
| 既存のテーブルを宛先にできるか | できる。`--column` で列を指定した |
| 仮想列の型 | `_message_id String`、`_publish_time DateTime64(3)`、`_attributes Map(String, String)` で受け付けられ、値が入った |
| Null エンジンを宛先にできるか | できる。パイプは Running になり、MV 経由で行が書かれた |
| 開始位置を指定できるか | 作成時に `latest`、`earliest`、`timestamp` を指定できる。`timestamp` では指定時刻から読み始めた（トピックの保持が有効な場合） |
| パイプの INSERT | 同期 INSERT（`async_insert = 0`）、Native 形式、約 5 秒ごと |
| 管理サブスクリプション | 名前は `clickpipes-<パイプ ID>`。メッセージ保持 7 日、ack 期限 60 秒、順序付け有効、非アクティブ時の有効期限 31 日 |

`clickhousectl` で `--column` を付けて作ると、既存テーブルを指定しても API 上は `managedTable: true` と記録されました。
このパイプを削除しても、宛先テーブルとエラーテーブルは残りました。
Pub/Sub の管理サブスクリプションは、パイプの削除から 2 分以内に消えました。
停止しただけのパイプのサブスクリプションは残っていました（未処理のメッセージは保持期間の 7 日までたまると考えられます）。

## 権限

MV の SQL SECURITY と、パイプのユーザーに必要な権限を、INSERT 権限だけを持つユーザーで確かめました。

| MV の定義 | INSERT 権限だけのユーザーで INSERT した結果 |
|---|---|
| SQL SECURITY を書かない（Cloud の既定） | 失敗。MV の読み取り元への SELECT 権限を要求された。2 段目の MV では中間テーブルへの SELECT 権限も要求された |
| `DEFINER = default SQL SECURITY DEFINER` | 成功。2 段の MV もすべて通った |
| `SQL SECURITY INVOKER` | MV には指定できない（作成時にエラー） |

SQL SECURITY を書かない MV で権限が足りなかったとき、読み取り元のテーブルには行が書かれ、MV の先には書かれませんでした。

`clickhousectl` で作ったパイプのユーザーには `default_role` が付いていて、権限不足は起きません。
UI の「Only destination table」を選ぶ場合は、MV を DEFINER 付きで作ります。

## MV が例外を出したとき

特定の insertId で `throwIf` が例外を出すよう MV を `MODIFY QUERY` で変え、該当メッセージを 3 件送信しました。

| 観察項目 | 結果 |
|---|---|
| 失敗したバッチ（303 行） | L0 には書かれ、L1 と集計テーブルには届かなかった |
| 再試行 | 同じバッチを 10 秒、30 秒、70 秒、その後は 2 分ごとに再試行した。2 回目以降は L0 で重複排除された（`DuplicatedInsertedBlocks = 1`） |
| ほかのバッチ | 並行して処理され続けた |
| パイプの状態 | 30 秒間隔の観測で 1 回だけ Degraded、ほかは Running |
| エラーテーブル | 0 行のまま |
| 復旧 | MV を直してから最初の再試行で L1 に届いた。全メッセージ ID で欠損 0、重複 0 |

復旧で欠損が出なかったのは、L0 で重複排除されたブロックも下流の MV には渡されるためです（Cloud の既定値 `deduplicate_blocks_in_dependent_materialized_views = 1`）。
この設定を 0 にしていると、再試行時に L0 でブロックの重複が排除された時点で MV も実行されず、L1 から欠けると考えられます（未検証）。

### 60 分以上直さなかった場合

別のパイプで、同じエラーを修正せずに取り込みを継続しました。

| 経過 | 観察 |
|---|---|
| 最初の失敗から約 60 分 | 失敗したバッチのメッセージが再配信され、L0 に同じメッセージが最大 3 重に入った（L0 の重複 606 件）。再配信分の一部は別のバッチとして L1 側にも書かれた |
| 約 62 分 | このパイプの INSERT が途絶えた。約 15 分後の確認で状態は Failed だった。Failed のパイプは何も取り込まない |
| MV を直して `clickpipe start` | 2 分以内に Running に戻り、ack されていなかったメッセージが再配信されて L0 と L1 の差は 0 になった。欠損はなかった |
| 復旧後 | 処理が停滞したバッチのうち 100 件が L1 に 2 回書かれた（60 分の時点の再配信で 1 回、再開後に 1 回） |

この検証では、故障を直さずに取り込みが続いたのは最初の失敗から約 60 分まででした。
それを過ぎるとパイプが止まり、復旧後に `MessageId` の重複が残りました。
再開は、管理サブスクリプションのメッセージ保持（既定 7 日）の間に行う必要があります（保持期間からの推論）。

## スキーマ変更と切り替え

いずれも 50 msg/s の負荷を継続したまま行いました。

| 手順 | 結果 |
|---|---|
| `ADD COLUMN` → `MODIFY QUERY` | 失敗した INSERT は 0。1 回の INSERT の中で新旧の版は混ざらなかった |
| Blue/Green（ORDER BY を変更、境界 T は `_publish_time`、L0 からバックフィル） | v2 は T 以降だけを受け取り、バックフィル後に欠損 0、重複 0。集計テーブルも v1 と一致した |
| パイプの差し替え（新パイプを T2 の 10 分前へ Seek） | L1 で欠損 0、重複 0。新しい着地テーブルには 500 件の再配信が入ったが、すべて T2 より前で境界条件により除外された |
| `REPLACE PARTITION` による 1 日の作り直し | L1 は置き換わったが、集計テーブルは古い値のまま。集計を作り直して一致した |
| L0 からの作り直し（重複除去なし） | 再配信由来の重複 493 件が L1 に戻った。`LIMIT 1 BY _message_id` を入れると 0 になった |
| MV と同じ SELECT での `INSERT ... SELECT` | 列が位置で対応付けられ、型変換エラーで失敗した。列を名前で並べ直す必要がある |

## EXCHANGE と RENAME（26.6.1、手動 INSERT）

| 操作 | 結果 |
|---|---|
| MV の書き込み先を `EXCHANGE TABLES` | MV は元の物理テーブル（交換後は別の名前）に書き続けた |
| MV の読み取り元を `EXCHANGE TABLES` | MV は名前に追従した（新しくその名前を持ったテーブルへの INSERT で発火し、元のテーブルへの INSERT では発火しなかった） |
| MV の読み取り元を `RENAME TABLE` し、元の名前で作り直す | 旧名と新名のどちらへの INSERT でも MV は発火せず、エラーも出なかった |

## 解析コスト

LogEntry を項目ごとに `JSONExtract*` で読む方式（A）と、`JSONExtract(_raw_message, 'Tuple(...)')` で 1 回だけ解析する方式（B、`sql/30_logs_v1_mv.sql`）を比べました。
B は監査ログの `Body` を `serviceName methodName` に、HTTP だけのログの `Body` を `METHOD STATUS URL` にするなど、出力も一部変えています。
その差分以外の列は、合成ログ 30 万行で A と一致しました。

| データ | A の CPU | B の CPU | 比 |
|---|---|---|---|
| 合成ログ 30 万行（ローカル、4 スレッド） | 2.0 秒 | 0.55 秒 | 約 3.7 倍 |
| 実ログ 200 万行（Cloud、2 回の平均） | 57.1 秒 | 20.9 秒 | 約 2.7 倍 |
| 参考：JSON 型への CAST（合成ログ、主要な列のみ） | 1.8 秒 | | |

取り込みの経路全体（パイプの INSERT、L0、MV1、L1、MV2）では、2,000 msg/s のとき 1 メッセージあたりの CPU 時間が約 18 マイクロ秒でした（合成ログ、`system.query_log` の `UserTimeMicroseconds`）。

## 負荷と遅延

最小構成のパイプ（1 レプリカ、0.125 vCPU）で、送信レートを 5 分ずつ上げました。
遅延は `_publish_time` から MV が行を作った時刻（`InsertedAt`）までです。

| 送信レート | 中央値 | p99 |
|---|---|---|
| 約 200 msg/s | 2.7 秒 | 5.2 秒 |
| 約 480 msg/s | 2.6〜2.9 秒 | 5.2 秒 |
| 約 980 msg/s | 2.7〜2.8 秒 | 5.3 秒 |
| 約 1,950 msg/s（約 1.4 MB/s） | 2.7〜2.9 秒 | 5.3 秒 |

どの送信レートでも滞留は増えませんでした。
p99 の約 5 秒は、パイプが約 5 秒ごとに INSERT することによると考えられます。
これより大きい流量（数十 MB/s 級）での挙動は確かめていません。

## 既存パイプラインの移行（実ログ）

自社 GCP プロジェクトの Cloud Logging を取り込んでいた既存のパイプライン（着地テーブルは `_raw_message` だけ、MV で監査ログと GKE ログに分割）を、`sql/runbooks/06_migrate_legacy_pipeline.sql` の手順（[運用](operations.md) の付録 A5）でこの構成へ移しました。
流量は約 18 msg/s（1 日約 155 万件、96% が k8s.io の Lease 更新の監査ログ）です。

| 項目 | 結果 |
|---|---|
| バックフィル | 旧着地テーブルの 7 日分（約 1,780 万行）を 6 時間ずつ 40 回。1 回あたり約 13 秒 |
| 旧着地テーブルの重複 | 1 日あたり数十件（例：2,603,287 行に対し識別子は 2,603,218 件） |
| 突き合わせ | 9/24〜10/01 の受信時刻の 1 時間ごとに、新旧の識別子の集合が一致 |
| 新しいパイプの一時停止と再開 | 停止中のメッセージは再開後に届き、`MessageId` の重複が 4 件残った |
| 監査ログの `audit.*` 属性を加えたパーサの CPU | 実ログ 200 万行で 18.8 秒（加える前は 20.9 秒、差は測定のばらつきの範囲） |

保存容量（圧縮後、1 行あたり）は次のとおりでした。

| 層 | 既存のパイプライン | この構成 |
|---|---|---|
| 着地テーブル | 178 バイト（`_raw_message` に加えて JSON 型の列に全体を保存） | 99 バイト |
| 本体 | 54 バイト（監査ログ専用、ORDER BY (serviceName, principalEmail, timestamp)） | 86 バイト（テキストインデックス約 13% を含む） |

本体が大きくなった主な要因は、k8s.io の監査ログがイベントごとに一意な UUID を持つ `OperationId`（列の 22%）と、`ProtoPayload` の原文（25%）、属性のテキストインデックスです。
長期保存の容量を減らすには、Lease 更新のような不要なログをシンクのフィルタで除外するのが最も効果的です。

## 日本語の全文検索

ClickStack は検索窓の語を `hasAllTokens(lower(Body), lower('語'))` に変換し、`lower(Body)` のテキストインデックスを使いました（query_log で確認）。
35 分間の合成ログ（約 110 万行）で、ClickStack から件数を数えた結果です。

| lower(Body) の区切り方 | 「タイムアウト」 | 「timeout」 | インデックスのサイズ |
|---|---|---|---|
| 単語単位（splitByNonAlpha） | 0 件 | 70,311 件 | 3.3 MiB |
| 2 文字ずつ（ngrams(2)） | 92,517 件 | 70,311 件 | 15.1 MiB |
| 参考：LIKE で数えた件数 | 92,517 件 | 70,311 件 | ― |

- 単語単位の区切りでは、日本語の文がまるごと 1 つの語になり、日本語の検索はエラーにならずに 0 件になった。
- 1 つの式に付けられるテキストインデックスは 1 つまでだった。
- ngrams(2) では、1 文字だけの検索語は日本語でも英語でも 0 件になった。
- ClickStack は、検索の経路によって `hasToken(lower(Body), lower('語'))` を出すこともあった（MCP からの検索）。ngrams(2) のインデックスは、Cloud 26.6 では `hasToken` でも使われ（333 グラニュール中 11）、clickhouse local 26.7 では `hasAllTokens` でしか使われなかった。使う版で両方の形を EXPLAIN で確かめる。
- `hasAllTokens` は WHERE に書いたときだけインデックスの区切り方で評価された。SELECT 句の `countIf(hasAllTokens(...))` では日本語が 0 件になった（26.7.7 の clickhouse local、WHERE では LIKE と同じ 1,736 件）。件数の比較は WHERE で数える。

## シンクの送出件数との突き合わせ

Cloud Monitoring の `logging.googleapis.com/exports/log_entry_count`（シンク別）と、L0 の公開時刻ごとの件数を 1 時間ごとに比べた差は、3 時間とも 0.1% 未満でした（符号は入れ替わり、3 時間の合計で 0.03%）。

## Pub/Sub の課金対象量

[料金表](https://cloud.google.com/pubsub/pricing) では、公開と配信のそれぞれに $40/TiB がかかります（公開と配信を合わせて毎月 10 GiB までは無料、1 リクエストあたり最低 1 KB）。
全ログを送るシンク 1 本と稼働中のパイプ 1 本で、3 時間の量を Cloud Monitoring で測りました。

| 項目 | バイト数 | 指標 |
|---|---|---|
| Cloud Logging の課金対象の取り込み量 | 74.3 MB | `logging.googleapis.com/billing/bytes_ingested` |
| シンクの送出量 | 369.1 MB | `logging.googleapis.com/exports/byte_count` |
| Pub/Sub の公開 | 368.2 MB | `pubsub.googleapis.com/topic/byte_cost` |
| Pub/Sub の配信 | 376.9 MB | `pubsub.googleapis.com/subscription/byte_cost`（streaming_pull） |

- Pub/Sub に送った量は Cloud Logging の課金対象の約 5 倍だった。74% は Cloud Logging が課金しない `_Required` 行きの Admin Activity 監査ログで、59% は Kubernetes の Lease 更新だった。
- 料金に換算すると、Pub/Sub（公開と配信）は Cloud Logging の取り込み料の約 78% にあたった。
- Cloud Logging が課金するログだけでは、Pub/Sub に送った JSON は課金対象の量の約 1.2 倍で、Pub/Sub の料金は取り込み料の約 2 割になる。
- 配信側では ack（55.3 MB）と ack 期限の延長（179.8 MB）も byte_cost に計上された。これが課金されるかは確かめていない。
- Lease 更新だけを 1 日分（2026-10-04、GKE クラスタ 2 つ）で数えると、210 万件、メッセージ本文の合計で 2.71 GiB だった。公開と配信の料金に換算すると月に約 $6.4、クラスタ 1 つあたり約 $3 になる（無料枠と 1 KB の最低課金を考えない概算）。集計された件数（`gcl_noise_1m_v1`）と L0 の同じ条件の行の数は、どちらも 2,103,762 件で一致し、L1 には 0 件だった。
- 停止したパイプの管理サブスクリプションには、停止から 19 時間で 170 万件、2.3 GB が蓄積していた。公開から 1 日を超えた分には保管料がかかる。

## 属性の Map とインデックス（ClickStack の既定スキーマとの突き合わせ）

属性の型は、ClickStack の公式の推奨どおり Map にしています（JSON 型は ClickStack ではベータで、キーが少なく安定している場合向け）。

**属性で絞り込むときの SQL とインデックス**（Cloud 26.6、40 万行）
- テーブルに `LogAttributeItems`（`キー=値` の配列の ALIAS 列）があると、ClickStack は属性の絞り込みを `has(LogAttributeItems, 'キー=値')` に変換した。この列の text インデックスが使われ、読んだのは 8,192 行だった。
- この列がないテーブルでは、ClickStack は `LogAttributes['キー'] = '値' AND indexHint(mapContains(...))` に変換した。この形では `キー=値` のインデックスは使われず、`mapValues` のインデックスは使われた（clickhouse local 26.7）。
- そのため L1 には、既定スキーマと同じ `ResourceAttributeItems`／`LogAttributeItems` とそのインデックスを置く。

**Map の保存形式（`with_buckets`）**（Cloud 26.6、実ログ 1 日分 120 万行、属性のキーは 1 行あたり平均 2〜12 個・最大 22 個、3 回の中央値）

| クエリ | 従来の形式 | with_buckets（既定） | with_buckets（強制分割） |
|---|---|---|---|
| 1 つのキーで絞り込み | 196 ms | 167 ms | 150 ms |
| `has(LogAttributeItems, ...)` での検索 | 20 ms | 19 ms | 20 ms |
| 1 つのキーで集計 | 177 ms | 211 ms | 126 ms |
| Map 全体を読む | 181 ms | 180 ms | 440 ms |
| 保存量（圧縮後） | 23.6 MiB | 23.5 MiB | 26.0 MiB |
| INSERT（1 回） | 4.4 秒 | 4.1 秒 | 5.6 秒 |

- 既定の設定（`map_buckets_min_avg_size = 32`）では、平均のキー数が 32 個未満なので分割されず、保存の構造は従来の形式と同じだった。
- 強制的に分割すると（下限を 0）、1 つのキーを読むクエリは 2〜3 割速くなったが、Map 全体を読むクエリは 2.4 倍遅く、保存量は 1 割、INSERT は 3 割弱増えた。
- L1 では `with_buckets` を、INSERT 直後の部分は従来の形式のままにして指定する。キーが増えて平均が 32 個を超えた部分だけが、マージ時に自動で分割される。

## 継続運用中の L1 の移行（Blue/Green、2026-10-02）

旧スキーマ（属性の値のインデックス、本文は単語単位の区切り）の L1 を、新しいスキーマ（`キー=値` のインデックス、本文は ngrams(2)、Map は with_buckets）の `gcl_logs_v2` へ、`sql/runbooks/03_blue_green.sql` の手順（[運用](operations.md) の付録 A3）で移した。

- 境界時刻 T の 5 分前に、T 以降に公開されたデータだけを書き込む MV を作った。v2 の最初の行の公開時刻は T の 0.348 秒後で、T 以降の MessageId の数は v1 と一致した（1,813 件）。
- T より前のデータは、v1 から 6 時間ごとの区間に分けてコピーし、区間ごとに件数の一致を確認した（合計 18,921,930 行）。件数確認が 1 回失敗して処理が停止したが、コピー前の確認だったため、その区間をスキップして再開できた。
- 日ごとの件数、MessageId の重複数（641）、分単位の集計の合計は、v1 と v2 で一致した。
- ClickStack のソースと、名前を固定したビューを v2 に切り替えた。属性の絞り込み条件には `has(LogAttributeItems, ...)` が使われ、まれな値では 333 グラニュール中 1 まで絞れた。

## パーサ v7：共通項目は列に、個別の内容は属性に

v6 は L1 の解析で監査ログを前提とし、LogEntry の共通項目を個別に列挙していました。
v7 では特定のログ形式を前提にせず、列として定義しない共通項目は、項目名を列挙せずに属性へ保存します。

**形の違うログでの確認**（clickhouse local 26.7）

| LogEntry の形 | v7 の ServiceName | v7 の Body | 足された属性 |
|---|---|---|---|
| 監査ログ以外の protoPayload（App Engine、httpRequest あり） | モジュール名 | `GET 200 /items` | `http.responseSize`、`http.protocol`、`proto.type` |
| 同上（httpRequest なし） | モジュール名 | `[google.appengine.logging.v1.RequestLog] {...}` | `proto.type` |
| httpRequest と message のない jsonPayload（ロードバランサ風） | リソースの種類/ログ ID | `GET 503 https://...` | `http.responseSize`、`http.cacheHit`、`http.referer` |
| 分割されたエントリ | リソースの種類/ログ ID | textPayload | `entry.split` |
| `otel`、`apphub`、`errorGroups`、`operation.first` を持つ | サービス名 | message | `entry.otel`、`entry.apphub`、`entry.errorGroups`、`operation.first` |
| ペイロードなし | リソースの種類/ログ ID | `[ログ ID]` | なし |
| 監査ログ | API のサービス名 | `サービス名 メソッド名` | `audit.*`、`proto.type` |

v6 では、監査ログ以外の protoPayload は ServiceName が空、Body が空白 1 文字になっていた。

- 合成ログ 30 万行では、ServiceName・Body・既存の属性は v6 と同じで、属性の数が 16% 増えた。INSERT の CPU 時間は 1.53 秒から 1.78 秒（16% 増）。
- 継続運用中の MV に `MODIFY QUERY` で適用した後、失敗した INSERT と処理の停滞は 0 件だった。実ログでは、GKE の操作ログの `operation.first`・`operation.last` が新たに残るようになった（v6 では保存していなかった）。

## L1 での取り出しと型付きテーブル（L2）の比較

GKE のアップグレード通知の表（ノードプール、版、件数、失敗、平均時間）を、L1 の属性から検索時に取り出して作り、型付きテーブルと比べた（9 日分、L1 は 1,894 万行）。

| 作り方 | 結果 | 時間 | 読んだ行 |
|---|---|---|---|
| L2（型付きテーブル） | 6 行 | 13 ms | 5.5 万行 |
| L1（ログ ID で絞る） | L2 と同じ 6 行 | 623 ms | 1,894 万行 |
| L1（ServiceName で絞る、1 日分） | ― | 159 ms | 110 万行 |

- L1 の並び順の先頭は 5 分ごとの時刻なので、ServiceName で絞っても読み取り量はほとんど減らず、対象期間で決まる。
- 読み取り量は対象期間の行数に比例する。1 日分（110 万行）なら 159 ms、9 日分（1,894 万行）でも 623 ms で、この規模なら L1 だけでダッシュボードは十分に動く。

## テキストインデックス

`hasToken(lower(Body), 'timeout')` で `idx_lower_body` が使われました。
名前を固定したビュー（`gcl.logs`）経由でも、同じ実行計画でした。

## 構築手順（Terraform と cli/deploy.sh、2026-10-02）

検証用のプロジェクトとサービスを使い、両方の手順でリソースの作成から削除までを実行しました。
`cli/deploy.sh` と `cli/destroy.sh` はその後リポジトリから外し、同じコマンドを [ハンズオン](hands-on.md) の第 3 部に移しました。

| 手順 | 結果 |
|---|---|
| `terraform apply`（ClickStack のソースとダッシュボードを含む） | 11 リソースを約 50 秒で作成し、パイプは Running になった。既存の L0 を宛先にしたパイプ（`managed_table = false`）も作れた |
| `cli/deploy.sh` | 約 70 秒で作成し、パイプは Running になった。2 回目は、トピック、シンク、ロール、サービスアカウント、鍵ファイル、パイプが既存だったため、それぞれの作成をスキップした |
| 合成ログ 600 件を公開して照合（どちらも） | L0 で欠損 0、重複 0。L1 に入らなかったのは混ぜた Lease の更新だけで、L1 とノイズの件数の合計は L0 と一致し、L3 の合計は L1 と一致した。シンクからの実ログも数分で届き始めた |
| ClickStack のソース（Terraform で作成） | 「タイムアウト」の検索で、日本語の本文のログが返った |
| `terraform destroy`、`cli/destroy.sh` | トピック、シンク、管理サブスクリプション、サービスアカウント、パイプが消えた。カスタムロールは削除済み（復元できる状態）で残った |

## 未検証の項目

- UI で「Only destination table」を選んだパイプでの動作（同じ権限のユーザーでの INSERT で代用した）
- 数十 MB/s 級の流量でのパイプの必要なレプリカ数
- GKE 以外の発生源（Cloud Run のリクエストログなど）の実ログ。合成ログで代用した
