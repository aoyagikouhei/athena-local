use std::error::Error;

use athena_local::config::Config;
use tokio::net::TcpListener;

/// ローカル用の Athena 代役。SQL は Trino に実行させる。
#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let config = Config::from_env();
    let listener = TcpListener::bind(&config.bind_address).await?;

    println!(
        "athena-local listening on {} (trino: {}, default catalog/schema: {}/{})",
        config.bind_address,
        config.trino_url,
        config.default_catalog.as_deref().unwrap_or("-"),
        config.default_database.as_deref().unwrap_or("-")
    );

    axum::serve(listener, athena_local::router(config)).await?;

    Ok(())
}
