use std::collections::HashMap;
use std::env;

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
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        let catalog_map = match optional_env("TRINO_CATALOG_MAP") {
            Some(text) => {
                parse_catalog_map(&text).map_err(|e| format!("TRINO_CATALOG_MAP: {e}"))?
            }
            None => HashMap::new(),
        };

        Ok(Self {
            bind_address: env_or("ATHENA_LOCAL_BIND", "0.0.0.0:8080"),
            trino_url: env_or("TRINO_URL", "http://trino:8080"),
            trino_user: env_or("TRINO_USER", "athena-local"),
            default_catalog: optional_env("TRINO_CATALOG"),
            default_database: optional_env("TRINO_SCHEMA"),
            catalog_map,
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
        };

        assert_eq!(config.trino_catalog("s3tablescatalog/a"), "iceberg");
        assert_eq!(config.trino_catalog("hive"), "hive");
    }
}
