//! Athena API(awsJson1.1)を受けて、SQL を Trino に実行させるサーバ。
//! バイナリは main.rs、組み立ては router() に置いてテストから使えるようにしている。

pub mod athena;
pub mod config;
mod convert;
mod handler;
mod operation;
mod response;
mod store;
pub mod trino;

use std::sync::Arc;

use axum::Router;
use axum::routing::post;

use crate::config::Config;
use crate::handler::App;
use crate::store::Store;
use crate::trino::Trino;

/// Athena API を受けるルータ。awsJson1.1 なのでパスは / だけ。
pub fn router(config: Config) -> Router {
    let app = App {
        store: Store::default(),
        trino: Arc::new(Trino::new(&config.trino_url, &config.trino_user)),
        config: Arc::new(config),
    };

    Router::new()
        .route("/", post(handler::dispatch))
        .with_state(app)
}
