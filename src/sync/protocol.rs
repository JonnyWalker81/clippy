use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Message {
    // Authentication
    Auth { token: String },
    AuthResponse { success: bool, message: String },

    // Clipboard sync
    ClipboardUpdate {
        content_type: String,
        content: String, // Base64 encoded
        timestamp: DateTime<Utc>,
        source: String,
        checksum: String,
    },
    ClipboardAck {
        checksum: String,
        success: bool,
    },

    // History requests
    HistoryRequest {
        limit: usize,
        offset: usize,
    },
    HistoryResponse {
        entries: Vec<HistoryEntry>,
    },

    // Heartbeat
    Ping,
    Pong,

    // Error
    Error { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub id: i64,
    pub content_type: String,
    pub content: String,
    pub source: String,
    pub timestamp: DateTime<Utc>,
    pub checksum: String,
}

impl Message {
    pub fn to_json(&self) -> anyhow::Result<String> {
        Ok(serde_json::to_string(self)?)
    }

    pub fn from_json(json: &str) -> anyhow::Result<Self> {
        Ok(serde_json::from_str(json)?)
    }

    /// Serialize message with length prefix for TCP streaming
    pub fn to_bytes(&self) -> anyhow::Result<Vec<u8>> {
        let json = self.to_json()?;
        let len = json.len() as u32;
        let mut bytes = Vec::with_capacity(4 + json.len());
        bytes.extend_from_slice(&len.to_be_bytes());
        bytes.extend_from_slice(json.as_bytes());
        Ok(bytes)
    }

    /// Deserialize message from length-prefixed bytes
    pub fn from_bytes(bytes: &[u8]) -> anyhow::Result<(Self, usize)> {
        if bytes.len() < 4 {
            return Err(anyhow::anyhow!("Insufficient bytes for length prefix"));
        }

        let len = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as usize;

        if bytes.len() < 4 + len {
            return Err(anyhow::anyhow!("Insufficient bytes for message body"));
        }

        let json = std::str::from_utf8(&bytes[4..4 + len])?;
        let message = Self::from_json(json)?;

        Ok((message, 4 + len))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_message_serialization() {
        let msg = Message::Ping;
        let bytes = msg.to_bytes().unwrap();
        let (decoded, size) = Message::from_bytes(&bytes).unwrap();

        assert_eq!(size, bytes.len());
        matches!(decoded, Message::Ping);
    }

    #[test]
    fn test_clipboard_update_message() {
        let msg = Message::ClipboardUpdate {
            content_type: "text".to_string(),
            content: "Hello, World!".to_string(),
            timestamp: Utc::now(),
            source: "macos".to_string(),
            checksum: "abc123".to_string(),
        };

        let bytes = msg.to_bytes().unwrap();
        let (decoded, _) = Message::from_bytes(&bytes).unwrap();

        match decoded {
            Message::ClipboardUpdate { content, .. } => {
                assert_eq!(content, "Hello, World!");
            }
            _ => panic!("Wrong message type"),
        }
    }
}
