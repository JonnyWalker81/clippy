use crate::client::ClipboardClient;
use crate::clipboard::{ClipboardContent, ClipboardManager};
use crate::config::Config;
use crate::server::ClipboardServer;
use crate::storage::{models::ClipboardEntry, ClipboardStorage};
use crate::sync::protocol::Message;
use anyhow::Result;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::time::{sleep, Duration};
use tracing::{error, info, warn};

pub enum DaemonMode {
    Server,
    Client,
    Both,
}

pub struct ClipboardDaemon {
    config: Config,
    mode: DaemonMode,
}

impl ClipboardDaemon {
    pub fn new(config: Config, mode: DaemonMode) -> Self {
        Self { config, mode }
    }

    pub async fn run(&self) -> Result<()> {
        let storage = ClipboardStorage::new(
            self.config.get_database_path(),
            self.config.storage.max_history,
        )
        .await?;

        match self.mode {
            DaemonMode::Server => {
                self.run_server_only(storage).await?;
            }
            DaemonMode::Client => {
                self.run_client_only().await?;
            }
            DaemonMode::Both => {
                self.run_both(storage).await?;
            }
        }

        Ok(())
    }

    async fn run_server_only(&self, storage: ClipboardStorage) -> Result<()> {
        info!("Starting in server-only mode");

        let server = ClipboardServer::new(self.config.clone(), storage).await?;
        let clipboard_rx = server.get_clipboard_receiver();

        let server_task = tokio::spawn(async move {
            if let Err(e) = server.run().await {
                error!("Server error: {}", e);
            }
        });

        let monitor_task = self.spawn_clipboard_monitor(clipboard_rx);

        tokio::select! {
            _ = server_task => {},
            _ = monitor_task => {},
        }

        Ok(())
    }

    async fn run_client_only(&self) -> Result<()> {
        info!("Starting in client-only mode");

        let mut client = ClipboardClient::new(self.config.clone());
        let client_tx = client.get_sender();

        let client_task = tokio::spawn(async move {
            if let Err(e) = client.run().await {
                error!("Client error: {}", e);
            }
        });

        let monitor_task = self.spawn_clipboard_monitor_for_client(client_tx);

        tokio::select! {
            _ = client_task => {},
            _ = monitor_task => {},
        }

        Ok(())
    }

    async fn run_both(&self, storage: ClipboardStorage) -> Result<()> {
        info!("Starting in both server and client mode");

        let storage = Arc::new(storage);
        let server = ClipboardServer::new(self.config.clone(), (*storage).clone()).await?;

        let mut client = ClipboardClient::new(self.config.clone());
        let client_tx = client.get_sender();

        // Start server
        let server_handle = {
            let server = Arc::new(server);
            tokio::spawn(async move {
                if let Err(e) = server.run().await {
                    error!("Server error: {}", e);
                }
            })
        };

        // Start client
        let client_handle = tokio::spawn(async move {
            if let Err(e) = client.run().await {
                error!("Client error: {}", e);
            }
        });

        // Monitor clipboard and send to server
        let monitor_handle = {
            let config = self.config.clone();
            let storage = Arc::clone(&storage);
            tokio::spawn(async move {
                Self::monitor_clipboard_for_server(config, storage, client_tx).await;
            })
        };

        tokio::select! {
            _ = server_handle => {},
            _ = client_handle => {},
            _ = monitor_handle => {},
        }

        Ok(())
    }

    fn spawn_clipboard_monitor(
        &self,
        mut clipboard_rx: tokio::sync::broadcast::Receiver<ClipboardEntry>,
    ) -> tokio::task::JoinHandle<()> {
        tokio::spawn(async move {
            while let Ok(_entry) = clipboard_rx.recv().await {
                // Handle clipboard updates from server
                info!("Received clipboard update from server");
            }
        })
    }

    fn spawn_clipboard_monitor_for_client(
        &self,
        client_tx: mpsc::Sender<Message>,
    ) -> tokio::task::JoinHandle<()> {
        let config = self.config.clone();

        tokio::spawn(async move {
            Self::monitor_clipboard_changes(config, client_tx).await;
        })
    }

    async fn monitor_clipboard_changes(config: Config, client_tx: mpsc::Sender<Message>) {
        info!("🚀 Initializing clipboard manager...");
        let mut clipboard = match ClipboardManager::new() {
            Ok(c) => {
                info!("✓ Clipboard manager initialized successfully");
                c
            },
            Err(e) => {
                error!("❌ Failed to initialize clipboard manager: {}", e);
                error!("This usually means:");
                error!("  - X11: xclip or xsel not installed");
                error!("  - Wayland: wl-clipboard not installed");
                error!("  - No DISPLAY environment variable set");
                return;
            }
        };

        let mut last_checksum: Option<String> = None;
        let interval = Duration::from_millis(config.sync.interval_ms);

        info!("✓ Starting clipboard monitor (checking every {}ms)", config.sync.interval_ms);
        info!("🔄 Monitor loop started - waiting for clipboard changes...");

        let mut iteration = 0;
        loop {
            sleep(interval).await;
            iteration += 1;

            // Log every 10 iterations to show we're still polling
            if iteration % 10 == 0 {
                info!("🔄 Monitor active (iteration {}, last_checksum: {:?})", iteration, last_checksum.as_ref().map(|s| &s[..8]));
            }

            match clipboard.get_content_checksum() {
                Ok(Some(checksum)) => {
                    // Log every checksum check in verbose mode
                    if iteration % 10 == 1 {
                        info!("Current clipboard checksum: {}", &checksum[..8]);
                    }

                    if last_checksum.as_ref() != Some(&checksum) {
                        info!("⚡ CHECKSUM CHANGED! Old: {:?}, New: {}",
                            last_checksum.as_ref().map(|s| &s[..8]), &checksum[..8]);

                        last_checksum = Some(checksum.clone());

                        info!("🔍 Reading clipboard content...");
                        match clipboard.get_content() {
                            Ok(Some(content)) => {
                                info!(
                                    "🔍 Detected LOCAL clipboard change (type: {}, checksum: {})",
                                    content.content_type_str(),
                                    &checksum[..8]
                                );

                                let content_preview = match &content {
                                    ClipboardContent::Text(text) => {
                                        if text.len() > 50 {
                                            format!("{}...", &text[..50])
                                        } else {
                                            text.clone()
                                        }
                                    }
                                    ClipboardContent::Image(data) => {
                                        format!("[Image: {} bytes]", data.len())
                                    }
                                    ClipboardContent::Html(html) => {
                                        if html.len() > 50 {
                                            format!("{}...", &html[..50])
                                        } else {
                                            html.clone()
                                        }
                                    }
                                };

                                info!("📋 Content preview: {}", content_preview);

                                let message = Message::ClipboardUpdate {
                                    content_type: content.content_type_str().to_string(),
                                    content: content.to_base64(),
                                    timestamp: chrono::Utc::now(),
                                    source: Config::get_source_name(),
                                    checksum: checksum.clone(),
                                };

                                info!("📤 Sending clipboard update to server...");
                                if let Err(e) = client_tx.send(message).await {
                                    error!("❌ Failed to send clipboard update: {}", e);
                                } else {
                                    info!("✓ Clipboard update sent to server");
                                }
                            }
                            Ok(None) => {
                                warn!("⚠ Clipboard checksum exists but content is None");
                            }
                            Err(e) => {
                                error!("❌ Failed to read clipboard content: {}", e);
                            }
                        }
                    }
                }
                Ok(None) => {
                    if iteration % 10 == 1 {
                        info!("Clipboard is empty");
                    }
                    if last_checksum.is_some() {
                        info!("Clipboard cleared (was: {:?})", last_checksum.as_ref().map(|s| &s[..8]));
                        last_checksum = None;
                    }
                }
                Err(e) => {
                    error!("❌ Error checking clipboard: {}", e);
                    error!("This might be a clipboard access issue - check permissions");
                }
            }
        }
    }

    async fn monitor_clipboard_for_server(
        config: Config,
        storage: Arc<ClipboardStorage>,
        client_tx: mpsc::Sender<Message>,
    ) {
        let mut clipboard = match ClipboardManager::new() {
            Ok(c) => c,
            Err(e) => {
                error!("Failed to initialize clipboard manager: {}", e);
                return;
            }
        };

        let mut last_checksum: Option<String> = None;
        let interval = Duration::from_millis(config.sync.interval_ms);

        loop {
            sleep(interval).await;

            match clipboard.get_content_checksum() {
                Ok(Some(checksum)) => {
                    if last_checksum.as_ref() != Some(&checksum) {
                        last_checksum = Some(checksum.clone());

                        if let Ok(Some(content)) = clipboard.get_content() {
                            info!("Detected clipboard change");

                            let content_type = match &content {
                                ClipboardContent::Text(_) => {
                                    crate::storage::models::ClipboardContentType::Text
                                }
                                ClipboardContent::Image(_) => {
                                    crate::storage::models::ClipboardContentType::Image
                                }
                                ClipboardContent::Html(_) => {
                                    crate::storage::models::ClipboardContentType::Html
                                }
                            };

                            let entry = ClipboardEntry::new(
                                content_type,
                                content.to_base64(),
                                Config::get_source_name(),
                            );

                            // Store locally
                            if let Err(e) = storage.insert(&entry).await {
                                error!("Failed to store clipboard entry: {}", e);
                            }

                            // Send to remote via client
                            let message = Message::ClipboardUpdate {
                                content_type: content.content_type_str().to_string(),
                                content: content.to_base64(),
                                timestamp: chrono::Utc::now(),
                                source: Config::get_source_name(),
                                checksum: entry.checksum,
                            };

                            if let Err(e) = client_tx.send(message).await {
                                error!("Failed to send clipboard update: {}", e);
                            }
                        }
                    }
                }
                Ok(None) => {
                    last_checksum = None;
                }
                Err(e) => {
                    error!("Error checking clipboard: {}", e);
                }
            }
        }
    }
}
