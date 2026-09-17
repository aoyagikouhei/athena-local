use std::collections::HashMap;
use std::env;
use std::time::Duration;

use reqwest::Url;

use crate::results;

/// 終端状態の実行情報を持っておく既定の長さ（1 時間）。本物の Athena の保持期間は未実測なので athena-local の都合で決めた値。
pub const DEFAULT_RETENTION: Duration = Duration::from_secs(3600);

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

        Ok(Self {
            bind_address: env_or("ATHENA_LOCAL_BIND", "0.0.0.0:8080"),
            trino_url: env_or("TRINO_URL", "http://trino:8080"),
            trino_user: env_or("TRINO_USER", "athena-local"),
            default_catalog: optional_env("TRINO_CATALOG"),
            default_database: optional_env("TRINO_SCHEMA"),
            catalog_map,
            results,
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
    }))
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
}
