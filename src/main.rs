use std::error::Error;

use athena_local::config::{Config, ResultsMode, output_location_warning};
use tokio::net::TcpListener;

/// ローカル用の Athena 代役。SQL は Trino に実行させる。
#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let config = Config::from_env()?;
    let listener = TcpListener::bind(&config.bind_address).await?;

    println!(
        "athena-local listening on {} (trino: {}, default catalog/schema: {}/{}, retention: {}s)",
        config.bind_address,
        config.trino_url,
        config.default_catalog.as_deref().unwrap_or("-"),
        config.default_database.as_deref().unwrap_or("-"),
        config.retention.as_secs()
    );
    match &config.results {
        ResultsMode::None => println!("results: not written (ATHENA_LOCAL_RESULTS=none)"),
        ResultsMode::S3(settings) => println!(
            "results: written as CSV to {} (default output location: {})",
            settings.endpoint,
            settings.default_output_location.as_deref().unwrap_or("-")
        ),
    }
    if let Some(warning) = output_location_warning(&config.results) {
        eprintln!("{warning}");
    }

    axum::serve(listener, athena_local::router(config)).await?;

    Ok(())
}
