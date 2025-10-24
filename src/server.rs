use crate::config::Config;
use crate::storage::{models::ClipboardEntry, ClipboardStorage};
use crate::sync::protocol::Message;
use anyhow::Result;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;
use tracing::{error, info, warn};

pub struct ClipboardServer {
    config: Arc<Config>,
    storage: Arc<ClipboardStorage>,
    clipboard_tx: broadcast::Sender<ClipboardEntry>,
}

impl ClipboardServer {
    pub async fn new(config: Config, storage: ClipboardStorage) -> Result<Self> {
        let (clipboard_tx, _) = broadcast::channel(100);

        Ok(Self {
            config: Arc::new(config),
            storage: Arc::new(storage),
            clipboard_tx,
        })
    }

    pub fn get_clipboard_receiver(&self) -> broadcast::Receiver<ClipboardEntry> {
        self.clipboard_tx.subscribe()
    }

    pub async fn broadcast_clipboard_update(&self, entry: ClipboardEntry) {
        let _ = self.clipboard_tx.send(entry);
    }

    pub async fn run(&self) -> Result<()> {
        let addr = format!(
            "{}:{}",
            self.config.server.host, self.config.server.port
        );

        let listener = TcpListener::bind(&addr).await?;
        info!("Clipboard server listening on {}", addr);

        loop {
            match listener.accept().await {
                Ok((socket, addr)) => {
                    info!("New connection from: {}", addr);
                    let config = Arc::clone(&self.config);
                    let storage = Arc::clone(&self.storage);
                    let clipboard_rx = self.clipboard_tx.subscribe();

                    tokio::spawn(async move {
                        if let Err(e) =
                            Self::handle_connection(socket, config, storage, clipboard_rx).await
                        {
                            error!("Error handling connection from {}: {}", addr, e);
                        }
                    });
                }
                Err(e) => {
                    error!("Error accepting connection: {}", e);
                }
            }
        }
    }

    async fn handle_connection(
        mut socket: TcpStream,
        config: Arc<Config>,
        storage: Arc<ClipboardStorage>,
        mut clipboard_rx: broadcast::Receiver<ClipboardEntry>,
    ) -> Result<()> {
        let mut authenticated = config.server.auth_token.is_none();
        let mut buffer = vec![0u8; 8192];
        let mut pending_data = Vec::new();

        loop {
            tokio::select! {
                // Read from socket
                result = socket.read(&mut buffer) => {
                    match result {
                        Ok(0) => {
                            info!("Connection closed");
                            break;
                        }
                        Ok(n) => {
                            pending_data.extend_from_slice(&buffer[..n]);

                            // Process complete messages
                            while pending_data.len() >= 4 {
                                match Message::from_bytes(&pending_data) {
                                    Ok((message, size)) => {
                                        pending_data.drain(..size);

                                        match Self::handle_message(
                                            message,
                                            &mut socket,
                                            &config,
                                            &storage,
                                            &mut authenticated,
                                        )
                                        .await
                                        {
                                            Ok(should_continue) => {
                                                if !should_continue {
                                                    return Ok(());
                                                }
                                            }
                                            Err(e) => {
                                                error!("Error handling message: {}", e);
                                                let error_msg = Message::Error {
                                                    message: e.to_string(),
                                                };
                                                let _ = socket.write_all(&error_msg.to_bytes()?).await;
                                            }
                                        }
                                    }
                                    Err(_) => {
                                        // Not enough data yet, wait for more
                                        break;
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            error!("Error reading from socket: {}", e);
                            break;
                        }
                    }
                }

                // Broadcast clipboard updates to connected clients
                result = clipboard_rx.recv() => {
                    if !authenticated {
                        continue;
                    }

                    match result {
                        Ok(entry) => {
                            let msg = Message::ClipboardUpdate {
                                content_type: entry.content_type.as_str().to_string(),
                                content: entry.content.clone(),
                                timestamp: entry.timestamp,
                                source: entry.source.clone(),
                                checksum: entry.checksum.clone(),
                            };

                            if let Err(e) = socket.write_all(&msg.to_bytes()?).await {
                                error!("Error sending clipboard update: {}", e);
                                break;
                            }
                        }
                        Err(e) => {
                            warn!("Error receiving clipboard broadcast: {}", e);
                        }
                    }
                }
            }
        }

        Ok(())
    }

    async fn handle_message(
        message: Message,
        socket: &mut TcpStream,
        config: &Config,
        storage: &ClipboardStorage,
        authenticated: &mut bool,
    ) -> Result<bool> {
        match message {
            Message::Auth { token } => {
                let success = if let Some(expected_token) = &config.server.auth_token {
                    token == *expected_token
                } else {
                    true
                };

                *authenticated = success;

                let response = Message::AuthResponse {
                    success,
                    message: if success {
                        "Authentication successful".to_string()
                    } else {
                        "Authentication failed".to_string()
                    },
                };

                socket.write_all(&response.to_bytes()?).await?;
            }

            Message::Ping => {
                let response = Message::Pong;
                socket.write_all(&response.to_bytes()?).await?;
            }

            Message::ClipboardUpdate {
                content_type,
                content,
                timestamp,
                source,
                checksum,
            } => {
                if !*authenticated {
                    return Ok(true);
                }

                let content_type_enum = crate::storage::models::ClipboardContentType::from_str(
                    &content_type,
                )
                .unwrap_or(crate::storage::models::ClipboardContentType::Text);

                let entry = ClipboardEntry {
                    id: None,
                    content_type: content_type_enum,
                    content: content.clone(),
                    metadata: None,
                    source,
                    timestamp,
                    checksum: checksum.clone(),
                };

                match storage.insert(&entry).await {
                    Ok(_) => {
                        let response = Message::ClipboardAck {
                            checksum,
                            success: true,
                        };
                        socket.write_all(&response.to_bytes()?).await?;
                    }
                    Err(e) => {
                        error!("Error storing clipboard entry: {}", e);
                        let response = Message::ClipboardAck {
                            checksum,
                            success: false,
                        };
                        socket.write_all(&response.to_bytes()?).await?;
                    }
                }
            }

            Message::HistoryRequest { limit, offset } => {
                if !*authenticated {
                    return Ok(true);
                }

                let query = crate::storage::models::ClipboardSearchQuery {
                    limit,
                    offset,
                    ..Default::default()
                };

                let entries = storage.search(&query).await?;

                let history_entries: Vec<crate::sync::protocol::HistoryEntry> = entries
                    .into_iter()
                    .map(|e| crate::sync::protocol::HistoryEntry {
                        id: e.id.unwrap_or(0),
                        content_type: e.content_type.as_str().to_string(),
                        content: e.content,
                        source: e.source,
                        timestamp: e.timestamp,
                        checksum: e.checksum,
                    })
                    .collect();

                let response = Message::HistoryResponse {
                    entries: history_entries,
                };

                socket.write_all(&response.to_bytes()?).await?;
            }

            _ => {
                warn!("Unexpected message type");
            }
        }

        Ok(true)
    }
}
