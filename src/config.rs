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
}

impl Config {
    pub fn from_env() -> Self {
        Self {
            bind_address: env_or("ATHENA_LOCAL_BIND", "0.0.0.0:8080"),
            trino_url: env_or("TRINO_URL", "http://trino:8080"),
            trino_user: env_or("TRINO_USER", "athena-local"),
            default_catalog: optional_env("TRINO_CATALOG"),
            default_database: optional_env("TRINO_SCHEMA"),
        }
    }
}

fn env_or(key: &str, default: &str) -> String {
    optional_env(key).unwrap_or_else(|| default.to_string())
}

fn optional_env(key: &str) -> Option<String> {
    env::var(key).ok().filter(|value| !value.is_empty())
}
