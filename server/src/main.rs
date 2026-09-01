mod archive;
mod db;
mod exif_util;
mod mdns;
mod media;
mod thumb;

use axum::{extract::DefaultBodyLimit, routing, Router};
use std::path::PathBuf;
use tower_http::cors::CorsLayer;

#[derive(Clone)]
pub struct AppState {
    pub pool: sqlx::SqlitePool,
    pub data_dir: PathBuf,
    pub media_dir: PathBuf,
    pub thumbs_dir: PathBuf,
    pub device_name: String,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(9600);

    let data_dir = std::env::var("DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("./data"));

    let device_name = std::env::var("DEVICE_NAME").unwrap_or_else(|_| {
        gethostname::gethostname()
            .to_string_lossy()
            .to_string()
    });

    let media_dir = data_dir.join("media");
    let thumbs_dir = data_dir.join("thumbs");

    tokio::fs::create_dir_all(&media_dir).await.expect("failed to create media dir");
    tokio::fs::create_dir_all(&thumbs_dir).await.expect("failed to create thumbs dir");

    let pool = db::init_pool(&data_dir).await;

    let state = AppState {
        pool,
        data_dir,
        media_dir,
        thumbs_dir,
        device_name: device_name.clone(),
    };

    let app = Router::new()
        .route("/v1/media/query", routing::post(media::query_media))
        .route("/v1/media/upload", routing::post(media::upload))
        .route("/v1/media/upload-batch", routing::post(media::upload_batch))
        .route("/v1/media/batch-delete", routing::post(media::batch_delete))
        .route("/v1/media/download", routing::post(media::download_batch))
        .route("/v1/media/{id}", routing::get(media::get_media).delete(media::delete_media).patch(media::update_media))
        .route("/v1/media/{id}/thumb", routing::get(media::get_thumb))
        .route("/v1/media/{id}/restore", routing::post(media::restore_media))
        .route("/v1/info", routing::get(media::server_info))
        .layer(DefaultBodyLimit::max(4 * 1024 * 1024 * 1024)) // 4 GB
        .layer(CorsLayer::permissive())
        .with_state(state);

    mdns::register(port, &device_name);

    let addr = format!("0.0.0.0:{port}");
    tracing::info!("iGallery server listening on {addr}");

    let listener = tokio::net::TcpListener::bind(&addr).await.expect("failed to bind");
    axum::serve(listener, app).await.expect("server error");
}
