use std::collections::HashMap;
use std::env;
use std::time::Duration;

use reqwest::Url;

use crate::results;

/// 終端状態の実行情報を持っておく既定の長さ（1 時間）。本物の Athena の保持期間は未実測なので athena-local の都合で決めた値。
pub const DEFAULT_RETENTION: Duration = Duration::from_secs(3600);

/// 結果ファイルの PUT を諦めるまでの時間（30 秒）。応答しない S3 でクエリが RUNNING のまま止まらないようにする。
/// 本物の Athena には無い事象なので athena-local の都合で決めた値。
pub const DEFAULT_S3_PUT_TIMEOUT: Duration = Duration::from_secs(30);

/// StartQueryExecution で WorkGroup が省略されたときの既定名で、
/// ATHENA_LOCAL_WORK_GROUPS が未設定のときに ListWorkGroups が返す唯一の名前。
/// GetWorkGroup では使わない（WorkGroup は必須項目で、無ければ parse が弾く）。
pub const DEFAULT_WORK_GROUP: &str = "primary";

/// athena-local の設定。すべて環境変数で与える。
pub struct Config {
    /// HTTP の待ち受けアドレス。
    pub bind_address: String,
    /// SQL の実行を委ねる Trino。
    pub trino_url: String,
    /// Trino に名乗るユーザ名。
    pub trino_user: String,
    /// QueryExecutionContext.Catalog が無いリクエストに使う既定。
    pub default_catalog: Option<String>,
    /// QueryExecutionContext.Database が無いリクエストに使う既定。
    pub default_database: Option<String>,
    /// Athena のカタログ名 → Trino のカタログ名。
    /// S3 Tables の `s3tablescatalog/<bucket>` のように、Trino では付けられない名前を差し替える。
    pub catalog_map: HashMap<String, String>,
    /// 結果 CSV を OutputLocation に書くか。
    pub results: ResultsMode,
    /// 終端状態の実行情報と、その `ClientRequestToken` の対応を持っておく長さ。QUEUED / RUNNING は捨てない。
    pub retention: Duration,
    /// ListWorkGroups が返すワークグループ名。名前の辞書順に整列済みなのが不変条件
    /// （本物の一覧も名前順。2026-09-18 実測）。athena-local にワークグループの実体は無く、
    /// ここに無い名前でも GetWorkGroup は成功する。
    pub work_groups: Vec<String>,
}

/// 結果 CSV の書き込み。
pub enum ResultsMode {
    /// 書かない。OutputLocation は形を確かめて GetQueryExecution に返すだけ（0.2.0 までと同じく S3 は要らない）。
    None,
    /// S3 互換ストレージ（MinIO など）に書く。
    S3(S3Settings),
}

pub struct S3Settings {
    /// 素の HTTP の接続先。バケットは path-style でパスに載せる。
    pub endpoint: Url,
    pub access_key_id: String,
    pub secret_access_key: String,
    /// 署名に使う。MinIO は値を見ない。
    pub region: String,
    /// リクエストに OutputLocation が無いときの既定（本物の workgroup の既定の代わり）。
    pub default_output_location: Option<String>,
    /// PUT 1 本を諦めるまでの時間。環境変数では変えられず、常に DEFAULT_S3_PUT_TIMEOUT（テストだけ短くする）。
    pub put_timeout: Duration,
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        let catalog_map = match optional_env("TRINO_CATALOG_MAP") {
            Some(text) => {
                parse_catalog_map(&text).map_err(|e| format!("TRINO_CATALOG_MAP: {e}"))?
            }
            None => HashMap::new(),
        };

        let results = parse_results(optional_env)?;
        let retention = parse_retention(optional_env)?;
        let work_groups = parse_work_groups(optional_env)?;

        Ok(Self {
            bind_address: env_or("ATHENA_LOCAL_BIND", "0.0.0.0:8080"),
            trino_url: env_or("TRINO_URL", "http://trino:8080"),
            trino_user: env_or("TRINO_USER", "athena-local"),
            default_catalog: optional_env("TRINO_CATALOG"),
            default_database: optional_env("TRINO_SCHEMA"),
            catalog_map,
            results,
            retention,
            work_groups,
        })
    }

    /// Trino に送るカタログ名。別名があれば差し替え、無ければそのまま。
    pub fn trino_catalog<'a>(&'a self, catalog: &'a str) -> &'a str {
        self.catalog_map
            .get(catalog)
            .map_or(catalog, String::as_str)
    }
}

/// `<Athena のカタログ名>=<Trino のカタログ名>` をカンマ区切りで並べたもの。
/// どちらの名前にも `=` と `,` は使えないので、要素ごとに `=` はちょうど 1 つ。
fn parse_catalog_map(text: &str) -> Result<HashMap<String, String>, String> {
    let mut map = HashMap::new();

    for entry in text.split(',') {
        let parts: Vec<&str> = entry.split('=').map(str::trim).collect();
        let [from, to] = parts.as_slice() else {
            return Err(format!("`<athena>=<trino>` の形ではありません: {entry:?}"));
        };
        if from.is_empty() || to.is_empty() {
            return Err(format!("カタログ名が空です: {entry:?}"));
        }
        if map.insert(from.to_string(), to.to_string()).is_some() {
            return Err(format!("同じカタログ名が 2 回あります: {from}"));
        }
    }

    Ok(map)
}

/// ATHENA_LOCAL_RESULTS と、`s3` のときに要る設定を読む。
/// 足りない・形が崩れている設定は起動時に止める。ネットワークには出ない
/// （compose ではバケットの用意が athena-local の起動より遅れることがある）。
fn parse_results(env: impl Fn(&str) -> Option<String>) -> Result<ResultsMode, String> {
    match env("ATHENA_LOCAL_RESULTS").as_deref() {
        None | Some("none") => return Ok(ResultsMode::None),
        Some("s3") => {}
        Some(other) => {
            return Err(format!(
                "ATHENA_LOCAL_RESULTS: `none` か `s3` を指定してください: {other:?}"
            ));
        }
    }

    let required = |key: &str| {
        env(key).ok_or_else(|| format!("ATHENA_LOCAL_RESULTS=s3 には {key} が要ります"))
    };

    let endpoint_text = env("AWS_ENDPOINT_URL_S3")
        .or_else(|| env("AWS_ENDPOINT_URL"))
        .ok_or_else(|| {
            "ATHENA_LOCAL_RESULTS=s3 には AWS_ENDPOINT_URL_S3（または AWS_ENDPOINT_URL）が要ります"
                .to_string()
        })?;
    let endpoint = Url::parse(&endpoint_text)
        .map_err(|e| format!("S3 の接続先を URL として読めません: {endpoint_text:?}: {e}"))?;
    if endpoint.scheme() != "http" {
        return Err(format!(
            "S3 の接続先は http:// だけに対応しています（TLS は入れていません）: {endpoint_text:?}"
        ));
    }

    let default_output_location = env("ATHENA_LOCAL_OUTPUT_LOCATION");
    if let Some(location) = &default_output_location
        && !results::is_valid_output_location(location)
    {
        return Err(format!(
            "ATHENA_LOCAL_OUTPUT_LOCATION: `s3://<bucket>/<prefix>` の形ではありません: {location:?}"
        ));
    }

    Ok(ResultsMode::S3(S3Settings {
        endpoint,
        access_key_id: required("AWS_ACCESS_KEY_ID")?,
        secret_access_key: required("AWS_SECRET_ACCESS_KEY")?,
        region: env("AWS_REGION").unwrap_or_else(|| "us-east-1".to_string()),
        default_output_location,
        put_timeout: DEFAULT_S3_PUT_TIMEOUT,
    }))
}

/// 既定の出力先が無いときに起動時に出す警告。起動は止めない。
/// 出力は main.rs の起動ログに並ぶので、そちらと同じ英語にする。
pub const OUTPUT_LOCATION_WARNING: &str = "warning: no default output location; awswrangler may create a bucket on real AWS. Set ATHENA_LOCAL_RESULTS=s3 with ATHENA_LOCAL_OUTPUT_LOCATION, or pass s3_output from the client (see README Caveats).";

/// 既定の出力先が無ければ OUTPUT_LOCATION_WARNING を返す。
/// 既定の出力先が無いと GetWorkGroup は OutputLocation を返さず、awswrangler は
/// create_athena_bucket() で STS と S3 を呼ぶ。AWS_ENDPOINT_URL が全サービスに効いていなければ
/// 実 AWS に出る（#2 の実機検証で確認）。ResultsMode::None でも GetWorkGroup は
/// OutputLocation を返さないので、危険の条件は同じ。よって none にも出す。
pub fn output_location_warning(results: &ResultsMode) -> Option<&'static str> {
    let location = match results {
        ResultsMode::None => None,
        ResultsMode::S3(settings) => settings.default_output_location.as_deref(),
    };
    location.is_none().then_some(OUTPUT_LOCATION_WARNING)
}

/// ATHENA_LOCAL_RETENTION_SECONDS を読む。未設定なら既定。空文字は optional_env が未設定として落とす。
/// 数として読めない値と 0 は起動時に止める（0 を「無期限」と読んだ設定で全クエリが直後に消えるのを防ぐ）。
fn parse_retention(env: impl Fn(&str) -> Option<String>) -> Result<Duration, String> {
    let Some(text) = env("ATHENA_LOCAL_RETENTION_SECONDS") else {
        return Ok(DEFAULT_RETENTION);
    };
    let seconds: u64 = text.parse().map_err(|_| {
        format!("ATHENA_LOCAL_RETENTION_SECONDS: 1 以上の整数（秒）を指定してください: {text:?}")
    })?;
    if seconds == 0 {
        return Err(
            "ATHENA_LOCAL_RETENTION_SECONDS: 0 は指定できません（無期限にしたいなら大きな値を入れてください）"
                .to_string(),
        );
    }
    Ok(Duration::from_secs(seconds))
}

/// ATHENA_LOCAL_WORK_GROUPS を読む。未設定なら DEFAULT_WORK_GROUP の 1 件。
/// カンマ区切りで、要素ごとに前後の空白を捨てる。空の要素は起動時に止める
/// （末尾のカンマは compose で現実に起こり、黙って通すと一覧に空の名前が並ぶ）。
/// 同じ名前が 2 回あっても止めない（一覧に同じ名前が 2 回出るだけで、起動を止める方が害が大きい）。
/// 本物の一覧は名前順なので、ここで辞書順に並べる（2026-09-18 実測）。
fn parse_work_groups(env: impl Fn(&str) -> Option<String>) -> Result<Vec<String>, String> {
    let Some(text) = env("ATHENA_LOCAL_WORK_GROUPS") else {
        return Ok(vec![DEFAULT_WORK_GROUP.to_string()]);
    };

    let mut names = Vec::new();
    for entry in text.split(',') {
        let name = entry.trim();
        if name.is_empty() {
            return Err(format!(
                "ATHENA_LOCAL_WORK_GROUPS: ワークグループ名が空です: {entry:?}"
            ));
        }
        names.push(name.to_string());
    }
    names.sort();

    Ok(names)
}

fn env_or(key: &str, default: &str) -> String {
    optional_env(key).unwrap_or_else(|| default.to_string())
}

fn optional_env(key: &str) -> Option<String> {
    env::var(key).ok().filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(from, to)| (from.to_string(), to.to_string()))
            .collect()
    }

    #[test]
    fn 別名を_1_件読む() {
        assert_eq!(
            parse_catalog_map("s3tablescatalog/example-bucket=iceberg"),
            Ok(map(&[("s3tablescatalog/example-bucket", "iceberg")]))
        );
    }

    #[test]
    fn 複数件を読み前後の空白は無視する() {
        assert_eq!(
            parse_catalog_map("s3tablescatalog/a=iceberg, AwsDataCatalog = hive"),
            Ok(map(&[
                ("s3tablescatalog/a", "iceberg"),
                ("AwsDataCatalog", "hive")
            ]))
        );
    }

    #[test]
    fn 形式が崩れていればエラーにする() {
        for text in [
            "iceberg",  // = が無い
            "a=b=c",    // = が 2 つ
            "=iceberg", // 左が空
            "a=",       // 右が空
            "a=b,",     // 空の要素
            "a=b,,c=d", // 空の要素
            "a=b, a=c", // 同じ名前が 2 回
        ] {
            assert!(parse_catalog_map(text).is_err(), "通ってしまった: {text:?}");
        }
    }

    #[test]
    fn 別名があれば差し替え無ければそのまま() {
        let config = Config {
            bind_address: String::new(),
            trino_url: String::new(),
            trino_user: String::new(),
            default_catalog: None,
            default_database: None,
            catalog_map: map(&[("s3tablescatalog/a", "iceberg")]),
            results: ResultsMode::None,
            retention: DEFAULT_RETENTION,
            work_groups: vec![DEFAULT_WORK_GROUP.to_string()],
        };

        assert_eq!(config.trino_catalog("s3tablescatalog/a"), "iceberg");
        assert_eq!(config.trino_catalog("hive"), "hive");
    }

    /// 環境変数の代わり。テストは並列に走るので本物の環境変数は触らない。
    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let values = map(pairs);
        move |key| values.get(key).cloned()
    }

    const S3_ENV: [(&str, &str); 4] = [
        ("ATHENA_LOCAL_RESULTS", "s3"),
        ("AWS_ENDPOINT_URL_S3", "http://minio:9000"),
        ("AWS_ACCESS_KEY_ID", "key"),
        ("AWS_SECRET_ACCESS_KEY", "secret"),
    ];

    fn with(overrides: &[(&'static str, &'static str)]) -> Vec<(&'static str, &'static str)> {
        let mut pairs: Vec<_> = S3_ENV
            .iter()
            .filter(|(key, _)| overrides.iter().all(|(k, _)| k != key))
            .copied()
            .collect();
        pairs.extend(overrides.iter().filter(|(_, value)| !value.is_empty()));
        pairs
    }

    #[test]
    fn 未設定か_none_なら結果は書かない() {
        assert!(matches!(parse_results(env(&[])), Ok(ResultsMode::None)));
        assert!(matches!(
            parse_results(env(&[("ATHENA_LOCAL_RESULTS", "none")])),
            Ok(ResultsMode::None)
        ));
    }

    #[test]
    fn s3_なら接続先と認証情報を読み_region_の既定は_us_east_1() {
        let Ok(ResultsMode::S3(settings)) = parse_results(env(&with(&[(
            "ATHENA_LOCAL_OUTPUT_LOCATION",
            "s3://results/athena/",
        )]))) else {
            panic!("s3 として読めない");
        };

        assert_eq!(settings.endpoint.as_str(), "http://minio:9000/");
        assert_eq!(settings.access_key_id, "key");
        assert_eq!(settings.secret_access_key, "secret");
        assert_eq!(settings.region, "us-east-1");
        assert_eq!(
            settings.default_output_location.as_deref(),
            Some("s3://results/athena/")
        );
    }

    #[test]
    fn 接続先は_s3_専用の変数を優先し_無ければ共通の変数を読む() {
        let endpoint = |pairs: &[(&'static str, &'static str)]| match parse_results(env(pairs)) {
            Ok(ResultsMode::S3(settings)) => settings.endpoint.to_string(),
            _ => panic!("s3 として読めない"),
        };

        assert_eq!(
            endpoint(&with(&[("AWS_ENDPOINT_URL", "http://common:9000")])),
            "http://minio:9000/"
        );
        assert_eq!(
            endpoint(&with(&[
                ("AWS_ENDPOINT_URL_S3", ""),
                ("AWS_ENDPOINT_URL", "http://common:9000")
            ])),
            "http://common:9000/"
        );
    }

    #[test]
    fn 保持期限の既定は_1_時間() {
        assert_eq!(parse_retention(env(&[])), Ok(DEFAULT_RETENTION));
        assert_eq!(DEFAULT_RETENTION, Duration::from_secs(3600));
    }

    #[test]
    fn 保持期限は秒の整数で読む() {
        assert_eq!(
            parse_retention(env(&[("ATHENA_LOCAL_RETENTION_SECONDS", "60")])),
            Ok(Duration::from_secs(60))
        );
    }

    #[test]
    fn 保持期限が数として読めないか_0_なら起動時エラーにする() {
        // 空文字は optional_env が先に落とすのでこの関数には届かない。
        for text in [
            "0",    // 0 は「無期限」の読み違えを起動時に止める
            "abc",  // 数でない
            "-1",   // 負の数
            "3.5",  // 小数
            " 60 ", // trim しない
        ] {
            assert!(
                parse_retention(env(&[("ATHENA_LOCAL_RETENTION_SECONDS", text)])).is_err(),
                "通ってしまった: {text:?}"
            );
        }
    }

    #[test]
    fn s3_で設定が足りないか形が崩れていれば起動時エラーにする() {
        for overrides in [
            &[("ATHENA_LOCAL_RESULTS", "S3")][..],    // 大文字は受けない
            &[("AWS_ENDPOINT_URL_S3", "")],           // 接続先が無い
            &[("AWS_ACCESS_KEY_ID", "")],             // 認証情報が無い
            &[("AWS_SECRET_ACCESS_KEY", "")],         // 認証情報が無い
            &[("AWS_ENDPOINT_URL_S3", "minio:9000")], // URL でない
            &[("AWS_ENDPOINT_URL_S3", "https://s3.amazonaws.com")], // TLS は無い
            &[("ATHENA_LOCAL_OUTPUT_LOCATION", "results/athena/")], // s3:// でない
        ] {
            assert!(
                parse_results(env(&with(overrides))).is_err(),
                "通ってしまった: {overrides:?}"
            );
        }
    }
    #[test]
    fn 既定の出力先が無ければ警告を出す() {
        assert!(output_location_warning(&ResultsMode::None).is_some());

        let Ok(results) = parse_results(env(&with(&[]))) else {
            panic!("s3 として読めない");
        };
        assert!(output_location_warning(&results).is_some());
    }

    #[test]
    fn 既定の出力先があれば警告を出さない() {
        let Ok(results) = parse_results(env(&with(&[(
            "ATHENA_LOCAL_OUTPUT_LOCATION",
            "s3://results/athena/",
        )]))) else {
            panic!("s3 として読めない");
        };
        assert_eq!(output_location_warning(&results), None);
    }

    #[test]
    fn ワークグループの既定は_primary_の_1_件() {
        assert_eq!(parse_work_groups(env(&[])), Ok(vec!["primary".to_string()]));
    }

    #[test]
    fn カンマ区切りで読み前後の空白を捨てて辞書順に並べる() {
        assert_eq!(
            parse_work_groups(env(&[(
                "ATHENA_LOCAL_WORK_GROUPS",
                " etl , ad-hoc ,primary"
            )])),
            Ok(vec![
                "ad-hoc".to_string(),
                "etl".to_string(),
                "primary".to_string()
            ])
        );
    }

    #[test]
    fn 空の要素があれば起動時エラーにする() {
        // 空文字は optional_env が先に落とすのでこの関数には届かない。
        for text in [
            ",",    // 要素が 2 つとも空
            "a,",   // 末尾のカンマ
            "a,,b", // 途中の空の要素
            " ",    // 空白だけ
        ] {
            assert!(
                parse_work_groups(env(&[("ATHENA_LOCAL_WORK_GROUPS", text)])).is_err(),
                "通ってしまった: {text:?}"
            );
        }
    }
}
