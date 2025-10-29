use crate::clipboard::{ClipboardContent, ClipboardManager};
use crate::config::Config;
use anyhow::{Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::time::sleep;
use tracing::{error, info, warn};

#[derive(Debug, Serialize, Deserialize)]
pub struct ClipboardItem {
    pub id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>, // Base64-encoded (not present in POST response)
    pub hash: String,    // MD5 hash
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<usize>,
}

#[derive(Debug, Serialize)]
struct ClipboardSubmit {
    content: String, // Base64-encoded
}

#[derive(Debug, Deserialize)]
struct HealthResponse {
    status: String,
    items_count: usize,
    uptime_seconds: u64,
}

pub struct HttpSyncClient {
    server_url: String,
    poll_interval: Duration,
    client: reqwest::Client,
    last_sent_hash: Option<String>,
    last_received_id: u64,
}

impl HttpSyncClient {
    pub fn new(server_url: String, poll_interval_ms: u64) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .expect("Failed to create HTTP client");

        Self {
            server_url,
            poll_interval: Duration::from_millis(poll_interval_ms),
            client,
            last_sent_hash: None,
            last_received_id: 0,
        }
    }

    pub fn from_config(config: &Config) -> Self {
        let server_url = format!(
            "http://{}:{}",
            config.client.server_host, config.client.server_port
        );
        Self::new(server_url, config.sync.interval_ms)
    }

    /// Test connectivity to the server
    pub async fn health_check(&self) -> Result<HealthResponse> {
        let url = format!("{}/health", self.server_url);
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .context("Failed to connect to server")?;

        if !response.status().is_success() {
            anyhow::bail!("Server returned error: {}", response.status());
        }

        let health = response
            .json::<HealthResponse>()
            .await
            .context("Failed to parse health response")?;

        Ok(health)
    }

    /// Send clipboard content to server
    async fn send_to_server(&self, content: &str) -> Result<ClipboardItem> {
        let encoded = BASE64.encode(content.as_bytes());
        let submit = ClipboardSubmit { content: encoded };

        let url = format!("{}/api/clipboard", self.server_url);
        let response = self
            .client
            .post(&url)
            .json(&submit)
            .send()
            .await
            .context("Failed to send clipboard to server")?;

        if !response.status().is_success() {
            anyhow::bail!("Server returned error: {}", response.status());
        }

        let item = response
            .json::<ClipboardItem>()
            .await
            .context("Failed to parse server response")?;

        Ok(item)
    }

    /// Get latest clipboard from server
    async fn get_from_server(&self) -> Result<Option<ClipboardItem>> {
        let url = format!("{}/api/clipboard/latest", self.server_url);
        let response = self
            .client
            .get(&url)
            .send()
            .await
            .context("Failed to get clipboard from server")?;

        if response.status().is_success() {
            let item = response
                .json::<ClipboardItem>()
                .await
                .context("Failed to parse clipboard item")?;
            Ok(Some(item))
        } else {
            Ok(None)
        }
    }

    /// Monitor local clipboard and send changes to server
    async fn monitor_local_clipboard(&mut self, clipboard: &mut ClipboardManager) -> Result<()> {
        info!("🔍 Starting local clipboard monitor");

        loop {
            sleep(self.poll_interval).await;

            // Get current clipboard content
            match clipboard.get_content() {
                Ok(Some(content)) => {
                    let content_str = match &content {
                        ClipboardContent::Text(text) => text.clone(),
                        ClipboardContent::Image(data) => {
                            // For images, we'll use base64 directly
                            BASE64.encode(data)
                        }
                        ClipboardContent::Html(html) => html.clone(),
                    };

                    // Calculate hash
                    let current_hash = format!("{:x}", md5::compute(content_str.as_bytes()));

                    // Check if content changed
                    if self.last_sent_hash.as_ref() != Some(&current_hash) {
                        let preview = if content_str.len() > 50 {
                            format!("{}...", &content_str[..50])
                        } else {
                            content_str.clone()
                        };

                        info!(
                            "🔍 Local clipboard changed: '{}' ({} bytes, hash: {})",
                            preview,
                            content_str.len(),
                            &current_hash[..8]
                        );

                        // Send to server
                        match self.send_to_server(&content_str).await {
                            Ok(item) => {
                                info!(
                                    "📤 Sent to server: id={}, hash={}",
                                    item.id,
                                    &item.hash[..8]
                                );
                                self.last_sent_hash = Some(current_hash);
                            }
                            Err(e) => {
                                error!("❌ Failed to send to server: {}", e);
                            }
                        }
                    }
                }
                Ok(None) => {
                    // Clipboard is empty
                }
                Err(e) => {
                    warn!("⚠️  Failed to read clipboard: {}", e);
                }
            }
        }
    }

    /// Poll server for clipboard changes
    async fn poll_server(&mut self, clipboard: &mut ClipboardManager) -> Result<()> {
        info!("📥 Starting server poll loop");

        loop {
            sleep(self.poll_interval).await;

            match self.get_from_server().await {
                Ok(Some(item)) => {
                    // Check if this is a new item
                    if item.id > self.last_received_id {
                        // Skip if no content
                        let Some(ref content_base64) = item.content else {
                            warn!("⚠️  Server item {} has no content", item.id);
                            continue;
                        };

                        // Decode content
                        match BASE64.decode(content_base64) {
                            Ok(decoded_bytes) => {
                                match String::from_utf8(decoded_bytes.clone()) {
                                    Ok(content) => {
                                        // Calculate hash of decoded content
                                        let content_hash =
                                            format!("{:x}", md5::compute(content.as_bytes()));

                                        // Only apply if different from what we sent
                                        if self.last_sent_hash.as_ref() != Some(&content_hash) {
                                            let preview = if content.len() > 50 {
                                                format!("{}...", &content[..50])
                                            } else {
                                                content.clone()
                                            };

                                            info!(
                                                "📥 Received from server: id={}, '{}' ({} bytes, hash: {})",
                                                item.id,
                                                preview,
                                                content.len(),
                                                &content_hash[..8]
                                            );

                                            // Apply to local clipboard
                                            let clipboard_content = ClipboardContent::Text(content);
                                            match clipboard.set_content(&clipboard_content) {
                                                Ok(_) => {
                                                    self.last_received_id = item.id;
                                                    self.last_sent_hash = Some(content_hash);
                                                    info!("✅ Applied to local clipboard");
                                                }
                                                Err(e) => {
                                                    error!("❌ Failed to apply to clipboard: {}", e);
                                                }
                                            }
                                        }
                                        // Silently skip if hash matches (no log spam)
                                    }
                                    Err(_) => {
                                        // Binary data (image)
                                        let content_hash =
                                            format!("{:x}", md5::compute(&decoded_bytes));

                                        if self.last_sent_hash.as_ref() != Some(&content_hash) {
                                            info!(
                                                "📥 Received image from server: id={}, {} bytes",
                                                item.id,
                                                decoded_bytes.len()
                                            );

                                            let clipboard_content =
                                                ClipboardContent::Image(decoded_bytes);
                                            match clipboard.set_content(&clipboard_content) {
                                                Ok(_) => {
                                                    self.last_received_id = item.id;
                                                    self.last_sent_hash = Some(content_hash);
                                                    info!("✅ Applied image to local clipboard");
                                                }
                                                Err(e) => {
                                                    error!("❌ Failed to apply image: {}", e);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            Err(e) => {
                                error!("❌ Failed to decode clipboard content: {}", e);
                            }
                        }
                    }
                }
                Ok(None) => {
                    // No clipboard items on server yet
                }
                Err(e) => {
                    warn!("⚠️  Failed to poll server: {}", e);
                }
            }
        }
    }

    /// Run bidirectional sync
    pub async fn run(&mut self) -> Result<()> {
        info!("🚀 Starting HTTP clipboard sync");
        info!("📍 Server URL: {}", self.server_url);
        info!("📊 Poll interval: {}ms", self.poll_interval.as_millis());

        // Test server connectivity
        info!("🔗 Testing server connectivity...");
        match self.health_check().await {
            Ok(health) => {
                info!("✅ Server is reachable");
                info!("   Status: {}", health.status);
                info!("   Items: {}", health.items_count);
                info!("   Uptime: {}s", health.uptime_seconds);
            }
            Err(e) => {
                warn!("⚠️  Cannot reach server: {}", e);
                warn!("   Make sure clipboard_server is running");
            }
        }

        // Initialize clipboard manager
        info!("🚀 Initializing clipboard manager...");
        let mut clipboard = ClipboardManager::new().context("Failed to initialize clipboard")?;
        info!("✓ Clipboard manager initialized successfully");

        // Initialize with current clipboard content
        let mut initial_hash = None;
        if let Ok(Some(content)) = clipboard.get_content() {
            let content_str = match &content {
                ClipboardContent::Text(text) => text.clone(),
                ClipboardContent::Image(data) => BASE64.encode(data),
                ClipboardContent::Html(html) => html.clone(),
            };
            let hash = format!("{:x}", md5::compute(content_str.as_bytes()));
            initial_hash = Some(hash);
            info!("📋 Initialized with current clipboard content");
        }

        // Spawn both monitor and poll tasks
        let monitor_handle = {
            let mut client_clone = Self::new(
                self.server_url.clone(),
                self.poll_interval.as_millis() as u64,
            );
            if let Some(hash) = initial_hash.clone() {
                client_clone.last_sent_hash = Some(hash);
            }
            let mut clipboard_clone = ClipboardManager::new()?;
            tokio::spawn(async move {
                if let Err(e) = client_clone
                    .monitor_local_clipboard(&mut clipboard_clone)
                    .await
                {
                    error!("Monitor error: {}", e);
                }
            })
        };

        let poll_handle = {
            let mut client_clone = Self::new(
                self.server_url.clone(),
                self.poll_interval.as_millis() as u64,
            );
            if let Some(hash) = initial_hash {
                client_clone.last_sent_hash = Some(hash);
            }
            let mut clipboard_clone = ClipboardManager::new()?;
            tokio::spawn(async move {
                if let Err(e) = client_clone.poll_server(&mut clipboard_clone).await {
                    error!("Poll error: {}", e);
                }
            })
        };

        info!("✓ Background processes started");

        // Wait for both tasks
        tokio::try_join!(monitor_handle, poll_handle)?;

        Ok(())
    }
}
