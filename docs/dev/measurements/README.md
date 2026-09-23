# 実測の記録

本物の Athena（と、比べる相手としての Trino・クライアント）で測った事実の記録。athena-local がどう振る舞うかは書かない。それは利用者向けの [docs/](../../) の仕事で、ここは「何を投げたら何が返ったか」だけを残す。

まだ測っていないものは [../unmeasured.md](../unmeasured.md)、決着済みの設計判断は [../decisions.md](../decisions.md)。

## 索引

| ファイル | 話題 | 対応する利用者向けの章 |
| --- | --- | --- |
| [result-files.md](result-files.md) | 結果ファイルの名前・本体・Content-Type、失敗・取り消しのとき、INSERT／CTAS／DROP TABLE／ALTER TABLE の置き方 | [result-files.md](../../result-files.md)、[ddl.md](../../ddl.md)、[caveats.md](../../caveats.md) |
| [metadata.md](metadata.md) | `.metadata` の中身（protobuf のフィールド、型ごとの Precision／Scale／CaseSensitive、SHOW 系の不透明な形式） | [result-files.md](../../result-files.md)、[caveats.md](../../caveats.md) |
| [statements.md](statements.md) | 先頭とキーワードの間のコメント、文の種類と `SubstatementType`、本物だけが弾く形、`EXPLAIN` の行の分け方と変種、`CREATE OR REPLACE TABLE ... AS` | [api.md](../../api.md)、[caveats.md](../../caveats.md) |
| [query-results.md](query-results.md) | `GetQueryResults` の先頭行、ページング、`MaxResults`／`NextToken` の検証 | [api.md](../../api.md)、[caveats.md](../../caveats.md) |
| [errors.md](errors.md) | リクエスト本文の解釈の失敗（`SerializationException`）、必須項目の欠落、`UnknownOperationException` | [caveats.md](../../caveats.md) |
| [work-groups.md](work-groups.md) | `GetWorkGroup`、`ListWorkGroups` | [api.md](../../api.md)、[caveats.md](../../caveats.md) |
| [client-request-token.md](client-request-token.md) | `ClientRequestToken` による冪等性とトークンの検証 | [api.md](../../api.md)、[caveats.md](../../caveats.md) |
| [clients.md](clients.md) | クライアント（AWS CLI、Athena JDBC 3.8.1、Grafana、awswrangler、PyAthena）の挙動とソース読み。本物の Athena ではない | [clients.md](../../clients.md)、[caveats.md](../../caveats.md) |
| [trino.md](trino.md) | 手元の Trino 482／483 での実測。本物の Athena ではない | — |

`ExecutionParameters` を本物で測った記録はまだ無いので、`parameters.md` は置いていない。

## 書き方

1 項目を `###` 1 つにし、次の形で書く。

```
### <話題を一言で>
- 日付: 2026-09-20 ／ issue: #39 ／ スクリプト: `tools/measure/drop-table-format.sh`（旧 `39-measure-drop-table-format.sh`） ／ 生データ: `$HOME/...`
- 相手: 本物の Athena（engine version 3、workgroup primary）
- 投げたもの: ...
- 返ったもの: （表はそのまま）
- 備考: 食い違い、採用した判断（誰がいつ）、後の実測との関係
```

- 1 項目に、日付・issue 番号・スクリプトのパス・投げたもの・返ったもの・備考を書く。スクリプトが無ければ「無し」、生データの置き場が無ければ省く。
- 返った値と表は要約せずにそのまま書く。推測で補わない。日付やスクリプトを推定したときは、その旨と根拠を書く。
- 上書きしない。測り直したら新しい項目を足す。
- 後の実測が前の実測と食い違ったら、両方を同じ話題の中に並べて残し、最後に「採用: ...」として採った判断と、判断した人と日付を書く。
- 並びは話題順で、同じ話題の中は日付順。
- athena-local 自身の観測（実機検証や結合テストの出力）はここに書かない。本物の実測ではないと後で分かった記述があれば、対応する本物の実測の備考に 1 行でその経緯を残す。
- スクリプトは `tools/measure/`（本物の Athena に投げるもの）と `tools/e2e/`（compose の実機検証の足場）に置き、項目からパスで指す。`.claude/issue-notes/` にあったころの名前は「（旧 `...`）」として添える。
