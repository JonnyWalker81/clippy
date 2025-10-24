use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ClipboardContentType {
    Text,
    Image,
    Html,
    Rtf,
    Files,
}

impl ClipboardContentType {
    pub fn as_str(&self) -> &str {
        match self {
            ClipboardContentType::Text => "text",
            ClipboardContentType::Image => "image",
            ClipboardContentType::Html => "html",
            ClipboardContentType::Rtf => "rtf",
            ClipboardContentType::Files => "files",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "text" => Some(ClipboardContentType::Text),
            "image" => Some(ClipboardContentType::Image),
            "html" => Some(ClipboardContentType::Html),
            "rtf" => Some(ClipboardContentType::Rtf),
            "files" => Some(ClipboardContentType::Files),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipboardEntry {
    pub id: Option<i64>,
    pub content_type: ClipboardContentType,
    pub content: String, // Base64 encoded for binary content
    pub metadata: Option<String>, // JSON encoded metadata
    pub source: String, // "macos" or "nixos"
    pub timestamp: DateTime<Utc>,
    pub checksum: String, // SHA256 hash for deduplication
}

impl ClipboardEntry {
    pub fn new(
        content_type: ClipboardContentType,
        content: String,
        source: String,
    ) -> Self {
        let checksum = Self::calculate_checksum(&content);
        Self {
            id: None,
            content_type,
            content,
            metadata: None,
            source,
            timestamp: Utc::now(),
            checksum,
        }
    }

    pub fn with_metadata(mut self, metadata: String) -> Self {
        self.metadata = Some(metadata);
        self
    }

    fn calculate_checksum(content: &str) -> String {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let mut hasher = DefaultHasher::new();
        content.hash(&mut hasher);
        format!("{:x}", hasher.finish())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClipboardSearchQuery {
    pub content_type: Option<ClipboardContentType>,
    pub source: Option<String>,
    pub search_text: Option<String>,
    pub limit: usize,
    pub offset: usize,
}

impl Default for ClipboardSearchQuery {
    fn default() -> Self {
        Self {
            content_type: None,
            source: None,
            search_text: None,
            limit: 100,
            offset: 0,
        }
    }
}
