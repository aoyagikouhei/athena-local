//! Athena API(awsJson1.1)を受けて、SQL を Trino に実行させるサーバ。
//! バイナリは main.rs、組み立ては router() に置いてテストから使えるようにしている。

pub mod athena;
mod catalog;
pub mod config;
mod content_type;
mod convert;
mod failure;
mod handler;
mod metadata;
mod operation;
mod request;
mod response;
mod results;
mod statement;
mod store;
pub mod trino;

use std::sync::Arc;

use axum::Router;
use axum::routing::post;

use crate::config::{Config, ResultsMode};
use crate::handler::App;
use crate::results::ResultWriter;
use crate::store::Store;
use crate::trino::Trino;

/// Athena API を受けるルータ。awsJson1.1 なのでパスは / だけ。
pub fn router(config: Config) -> Router {
    let app = App {
        store: Store::new(config.retention),
        trino: Arc::new(Trino::new(&config.trino_url, &config.trino_user)),
        results: match &config.results {
            ResultsMode::S3(settings) => Some(Arc::new(ResultWriter::new(settings))),
            ResultsMode::None => None,
        },
        config: Arc::new(config),
    };

    Router::new()
        .route("/", post(handler::dispatch))
        .with_state(app)
}
