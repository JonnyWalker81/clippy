use anyhow::Result;
use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;
use tracing::info;

// Configuration
const DEFAULT_PORT: u16 = 8080;
const DEFAULT_HOST: &str = "0.0.0.0";
const MAX_CLIPBOARD_SIZE: usize = 10 * 1024 * 1024; // 10MB
const MAX_HISTORY_ITEMS: usize = 100;

// Data Models
#[derive(Debug, Clone, Serialize, Deserialize)]
struct ClipboardItem {
    id: u64,
    content: String, // Base64-encoded
    hash: String,    // MD5 hash for deduplication
    timestamp: DateTime<Utc>,
    size: usize,
}

#[derive(Debug, Deserialize)]
struct SubmitClipboardRequest {
    content: String, // Base64-encoded clipboard data
}

#[derive(Debug, Serialize)]
struct SubmitClipboardResponse {
    id: u64,
    hash: String,
    timestamp: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
struct LatestClipboardResponse {
    id: u64,
    content: String,
    hash: String,
    timestamp: DateTime<Utc>,
    size: usize,
}

#[derive(Debug, Serialize)]
struct HistoryResponse {
    items: Vec<ClipboardItem>,
    total: usize,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: String,
    items_count: usize,
    uptime_seconds: u64,
}

// Application State
#[derive(Clone)]
struct AppState {
    storage: Arc<Mutex<ClipboardStorage>>,
    start_time: DateTime<Utc>,
}

struct ClipboardStorage {
    items: Vec<ClipboardItem>,
    next_id: u64,
}

impl ClipboardStorage {
    fn new() -> Self {
        Self {
            items: Vec::new(),
            next_id: 1,
        }
    }

    fn add_item(&mut self, content: String) -> ClipboardItem {
        let hash = format!("{:x}", md5::compute(&content));
        let timestamp = Utc::now();
        let size = content.len();

        let item = ClipboardItem {
            id: self.next_id,
            content,
            hash,
            timestamp,
            size,
        };

        self.items.push(item.clone());
        self.next_id += 1;

        // Maintain max history size (FIFO)
        if self.items.len() > MAX_HISTORY_ITEMS {
            self.items.remove(0);
        }

        item
    }

    fn get_latest(&self) -> Option<ClipboardItem> {
        self.items.last().cloned()
    }

    fn get_all(&self) -> Vec<ClipboardItem> {
        self.items.clone()
    }

    fn count(&self) -> usize {
        self.items.len()
    }
}

// Error handling
enum AppError {
    ContentTooLarge,
    EmptyContent,
    InvalidBase64,
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            AppError::ContentTooLarge => (
                StatusCode::PAYLOAD_TOO_LARGE,
                format!("Content exceeds maximum size of {} bytes", MAX_CLIPBOARD_SIZE),
            ),
            AppError::EmptyContent => (StatusCode::BAD_REQUEST, "Content cannot be empty".to_string()),
            AppError::InvalidBase64 => (StatusCode::BAD_REQUEST, "Invalid base64 content".to_string()),
        };

        (status, Json(serde_json::json!({ "error": message }))).into_response()
    }
}

// API Handlers
async fn health_check(State(state): State<AppState>) -> Json<HealthResponse> {
    let storage = state.storage.lock().await;
    let uptime = (Utc::now() - state.start_time).num_seconds() as u64;

    Json(HealthResponse {
        status: "healthy".to_string(),
        items_count: storage.count(),
        uptime_seconds: uptime,
    })
}

async fn submit_clipboard(
    State(state): State<AppState>,
    Json(payload): Json<SubmitClipboardRequest>,
) -> Result<Json<SubmitClipboardResponse>, AppError> {
    // Validate content
    if payload.content.is_empty() {
        return Err(AppError::EmptyContent);
    }

    if payload.content.len() > MAX_CLIPBOARD_SIZE {
        return Err(AppError::ContentTooLarge);
    }

    // Verify it's valid base64
    use base64::Engine;
    if base64::engine::general_purpose::STANDARD.decode(&payload.content).is_err() {
        return Err(AppError::InvalidBase64);
    }

    let mut storage = state.storage.lock().await;
    let item = storage.add_item(payload.content);

    info!(
        "New clipboard item: id={}, size={}, hash={}",
        item.id,
        item.size,
        &item.hash[..8]
    );

    Ok(Json(SubmitClipboardResponse {
        id: item.id,
        hash: item.hash,
        timestamp: item.timestamp,
    }))
}

async fn get_latest(State(state): State<AppState>) -> Result<Json<LatestClipboardResponse>, StatusCode> {
    let storage = state.storage.lock().await;

    match storage.get_latest() {
        Some(item) => Ok(Json(LatestClipboardResponse {
            id: item.id,
            content: item.content,
            hash: item.hash,
            timestamp: item.timestamp,
            size: item.size,
        })),
        None => Err(StatusCode::NOT_FOUND),
    }
}

async fn get_history(State(state): State<AppState>) -> Json<HistoryResponse> {
    let storage = state.storage.lock().await;
    let items = storage.get_all();
    let total = items.len();

    Json(HistoryResponse { items, total })
}

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    // Configuration
    let host = std::env::var("CLIPBOARD_SERVER_HOST").unwrap_or_else(|_| DEFAULT_HOST.to_string());
    let port = std::env::var("CLIPBOARD_SERVER_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(DEFAULT_PORT);

    // Initialize state
    let state = AppState {
        storage: Arc::new(Mutex::new(ClipboardStorage::new())),
        start_time: Utc::now(),
    };

    // Build router
    let app = Router::new()
        .route("/health", get(health_check))
        .route("/api/clipboard", post(submit_clipboard))
        .route("/api/clipboard/latest", get(get_latest))
        .route("/api/clipboard/history", get(get_history))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    // Start server
    let addr = format!("{}:{}", host, port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;

    info!("🚀 Clipboard HTTP Server starting");
    info!("📍 Listening on http://{}", addr);
    info!("📊 Max clipboard size: {} bytes", MAX_CLIPBOARD_SIZE);
    info!("📚 Max history items: {}", MAX_HISTORY_ITEMS);
    info!("");
    info!("API Endpoints:");
    info!("  POST   /api/clipboard          - Submit new clipboard");
    info!("  GET    /api/clipboard/latest   - Get latest clipboard");
    info!("  GET    /api/clipboard/history  - Get clipboard history");
    info!("  GET    /health                 - Health check");
    info!("");

    axum::serve(listener, app).await?;

    Ok(())
}
