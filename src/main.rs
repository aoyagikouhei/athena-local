mod athena;
mod config;
mod convert;
mod handler;
mod operation;
mod response;
mod store;
mod trino;

use std::error::Error;
use std::sync::Arc;

use axum::Router;
use axum::routing::post;
use tokio::net::TcpListener;

use crate::config::Config;
use crate::handler::App;
use crate::store::Store;
use crate::trino::Trino;

/// ローカル用の Athena 代役。SQL は Trino に実行させる。
#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let config = Config::from_env();
    let app = App {
        store: Store::default(),
        trino: Arc::new(Trino::new(&config.trino_url, &config.trino_user)),
        config: Arc::new(config),
    };

    let listener = TcpListener::bind(&app.config.bind_address).await?;
    println!(
        "athena-local listening on {} (trino: {}, default catalog/schema: {}/{})",
        app.config.bind_address,
        app.config.trino_url,
        app.config.default_catalog.as_deref().unwrap_or("-"),
        app.config.default_database.as_deref().unwrap_or("-")
    );

    // awsJson1.1 なのでパスは / だけ。
    let router = Router::new()
        .route("/", post(handler::dispatch))
        .with_state(app);
    axum::serve(listener, router).await?;

    Ok(())
}
