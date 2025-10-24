use crate::config::Config;
use crate::sync::protocol::Message;
use anyhow::Result;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::time::{sleep, Duration};
use tracing::{error, info, warn};

pub struct ClipboardClient {
    config: Arc<Config>,
    tx: mpsc::Sender<Message>,
    rx: mpsc::Receiver<Message>,
}

impl ClipboardClient {
    pub fn new(config: Config) -> Self {
        let (tx, rx) = mpsc::channel(100);

        Self {
            config: Arc::new(config),
            tx,
            rx,
        }
    }

    pub fn get_sender(&self) -> mpsc::Sender<Message> {
        self.tx.clone()
    }

    pub async fn run(&mut self) -> Result<()> {
        loop {
            match self.connect_and_run().await {
                Ok(_) => {
                    info!("Client connection closed gracefully");
                }
                Err(e) => {
                    error!("Client error: {}", e);
                }
            }

            info!(
                "Reconnecting in {} ms...",
                self.config.sync.retry_delay_ms
            );
            sleep(Duration::from_millis(self.config.sync.retry_delay_ms)).await;
        }
    }

    async fn connect_and_run(&mut self) -> Result<()> {
        let addr = format!(
            "{}:{}",
            self.config.client.server_host, self.config.client.server_port
        );

        info!("Connecting to server at {}...", addr);
        let mut socket = TcpStream::connect(&addr).await?;
        info!("Connected to server");

        // Authenticate if token is provided
        if let Some(token) = &self.config.client.auth_token {
            let auth_msg = Message::Auth {
                token: token.clone(),
            };
            socket.write_all(&auth_msg.to_bytes()?).await?;

            // Wait for auth response
            let mut buffer = vec![0u8; 8192];
            let n = socket.read(&mut buffer).await?;
            let (msg, _) = Message::from_bytes(&buffer[..n])?;

            match msg {
                Message::AuthResponse { success, message } => {
                    if !success {
                        return Err(anyhow::anyhow!("Authentication failed: {}", message));
                    }
                    info!("Authentication successful");
                }
                _ => {
                    return Err(anyhow::anyhow!("Unexpected response to auth"));
                }
            }
        }

        let mut buffer = vec![0u8; 8192];
        let mut pending_data = Vec::new();
        let mut heartbeat_interval =
            tokio::time::interval(Duration::from_millis(self.config.sync.heartbeat_interval_ms));

        loop {
            tokio::select! {
                // Send messages from the queue
                Some(message) = self.rx.recv() => {
                    if let Err(e) = socket.write_all(&message.to_bytes()?).await {
                        error!("Error sending message: {}", e);
                        return Err(e.into());
                    }
                }

                // Read messages from server
                result = socket.read(&mut buffer) => {
                    match result {
                        Ok(0) => {
                            info!("Server closed connection");
                            return Ok(());
                        }
                        Ok(n) => {
                            pending_data.extend_from_slice(&buffer[..n]);

                            // Process complete messages
                            while pending_data.len() >= 4 {
                                match Message::from_bytes(&pending_data) {
                                    Ok((message, size)) => {
                                        pending_data.drain(..size);
                                        self.handle_message(message).await?;
                                    }
                                    Err(_) => {
                                        // Not enough data yet
                                        break;
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            error!("Error reading from server: {}", e);
                            return Err(e.into());
                        }
                    }
                }

                // Send heartbeat
                _ = heartbeat_interval.tick() => {
                    let ping = Message::Ping;
                    if let Err(e) = socket.write_all(&ping.to_bytes()?).await {
                        error!("Error sending heartbeat: {}", e);
                        return Err(e.into());
                    }
                }
            }
        }
    }

    async fn handle_message(&self, message: Message) -> Result<()> {
        match message {
            Message::ClipboardUpdate {
                content_type,
                content,
                timestamp: _,
                source,
                checksum,
            } => {
                info!(
                    "Received clipboard update from {} (type: {}, checksum: {})",
                    source, content_type, checksum
                );

                // Update local clipboard
                if let Err(e) = self.apply_clipboard_update(&content_type, &content).await {
                    error!("Error applying clipboard update: {}", e);
                }
            }

            Message::Pong => {
                // Heartbeat response
            }

            Message::ClipboardAck { checksum, success } => {
                if success {
                    info!("Clipboard sync acknowledged: {}", checksum);
                } else {
                    warn!("Clipboard sync failed: {}", checksum);
                }
            }

            Message::Error { message } => {
                error!("Server error: {}", message);
            }

            _ => {
                warn!("Unexpected message from server");
            }
        }

        Ok(())
    }

    async fn apply_clipboard_update(&self, content_type: &str, content: &str) -> Result<()> {
        use crate::clipboard::{ClipboardContent, ClipboardManager};

        let mut clipboard = ClipboardManager::new()?;
        let clipboard_content = ClipboardContent::from_base64(content_type, content)?;
        clipboard.set_content(&clipboard_content)?;

        Ok(())
    }
}
