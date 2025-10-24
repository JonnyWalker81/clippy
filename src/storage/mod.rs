pub mod models;

use anyhow::Result;
use chrono::{TimeZone, Utc};
use models::{ClipboardEntry, ClipboardSearchQuery};
use sqlx::{sqlite::SqlitePool, Row};
use std::path::PathBuf;

#[derive(Clone)]
pub struct ClipboardStorage {
    pool: SqlitePool,
    max_history: usize,
}

impl ClipboardStorage {
    pub async fn new(db_path: PathBuf, max_history: usize) -> Result<Self> {
        // Ensure parent directory exists
        if let Some(parent) = db_path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }

        let db_url = format!("sqlite:{}?mode=rwc", db_path.display());
        let pool = SqlitePool::connect(&db_url).await?;

        let storage = Self { pool, max_history };
        storage.init_schema().await?;

        Ok(storage)
    }

    async fn init_schema(&self) -> Result<()> {
        sqlx::query(
            r#"
            CREATE TABLE IF NOT EXISTS clipboard_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                content_type TEXT NOT NULL,
                content TEXT NOT NULL,
                metadata TEXT,
                source TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                checksum TEXT NOT NULL,
                UNIQUE(checksum)
            );

            CREATE INDEX IF NOT EXISTS idx_timestamp ON clipboard_history(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_source ON clipboard_history(source);
            CREATE INDEX IF NOT EXISTS idx_content_type ON clipboard_history(content_type);
            CREATE INDEX IF NOT EXISTS idx_checksum ON clipboard_history(checksum);
            "#,
        )
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    pub async fn insert(&self, entry: &ClipboardEntry) -> Result<i64> {
        // Check if entry with same checksum exists
        let existing: Option<i64> = sqlx::query_scalar(
            "SELECT id FROM clipboard_history WHERE checksum = ? LIMIT 1",
        )
        .bind(&entry.checksum)
        .fetch_optional(&self.pool)
        .await?;

        if let Some(id) = existing {
            // Update timestamp of existing entry
            sqlx::query(
                "UPDATE clipboard_history SET timestamp = ? WHERE id = ?",
            )
            .bind(entry.timestamp.timestamp())
            .bind(id)
            .execute(&self.pool)
            .await?;
            return Ok(id);
        }

        // Insert new entry
        let result = sqlx::query(
            r#"
            INSERT INTO clipboard_history (content_type, content, metadata, source, timestamp, checksum)
            VALUES (?, ?, ?, ?, ?, ?)
            "#,
        )
        .bind(entry.content_type.as_str())
        .bind(&entry.content)
        .bind(&entry.metadata)
        .bind(&entry.source)
        .bind(entry.timestamp.timestamp())
        .bind(&entry.checksum)
        .execute(&self.pool)
        .await?;

        // Cleanup old entries if exceeding max_history
        self.cleanup_old_entries().await?;

        Ok(result.last_insert_rowid())
    }

    async fn cleanup_old_entries(&self) -> Result<()> {
        sqlx::query(
            r#"
            DELETE FROM clipboard_history
            WHERE id NOT IN (
                SELECT id FROM clipboard_history
                ORDER BY timestamp DESC
                LIMIT ?
            )
            "#,
        )
        .bind(self.max_history as i64)
        .execute(&self.pool)
        .await?;

        Ok(())
    }

    pub async fn get_latest(&self) -> Result<Option<ClipboardEntry>> {
        let row = sqlx::query(
            r#"
            SELECT id, content_type, content, metadata, source, timestamp, checksum
            FROM clipboard_history
            ORDER BY timestamp DESC
            LIMIT 1
            "#,
        )
        .fetch_optional(&self.pool)
        .await?;

        Ok(row.map(|r| self.row_to_entry(r)))
    }

    pub async fn search(&self, query: &ClipboardSearchQuery) -> Result<Vec<ClipboardEntry>> {
        let mut sql = String::from(
            "SELECT id, content_type, content, metadata, source, timestamp, checksum FROM clipboard_history WHERE 1=1",
        );
        let mut bindings = Vec::new();

        if let Some(ref content_type) = query.content_type {
            sql.push_str(" AND content_type = ?");
            bindings.push(content_type.as_str().to_string());
        }

        if let Some(ref source) = query.source {
            sql.push_str(" AND source = ?");
            bindings.push(source.clone());
        }

        if let Some(ref search_text) = query.search_text {
            sql.push_str(" AND content LIKE ?");
            bindings.push(format!("%{}%", search_text));
        }

        sql.push_str(" ORDER BY timestamp DESC LIMIT ? OFFSET ?");

        let mut query_builder = sqlx::query(&sql);
        for binding in bindings {
            query_builder = query_builder.bind(binding);
        }
        query_builder = query_builder.bind(query.limit as i64);
        query_builder = query_builder.bind(query.offset as i64);

        let rows = query_builder.fetch_all(&self.pool).await?;

        Ok(rows.into_iter().map(|r| self.row_to_entry(r)).collect())
    }

    pub async fn get_count(&self) -> Result<i64> {
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM clipboard_history")
            .fetch_one(&self.pool)
            .await?;
        Ok(count)
    }

    pub async fn clear(&self) -> Result<()> {
        sqlx::query("DELETE FROM clipboard_history")
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    fn row_to_entry(&self, row: sqlx::sqlite::SqliteRow) -> ClipboardEntry {
        use models::ClipboardContentType;

        let id: i64 = row.get("id");
        let content_type_str: String = row.get("content_type");
        let content: String = row.get("content");
        let metadata: Option<String> = row.get("metadata");
        let source: String = row.get("source");
        let timestamp: i64 = row.get("timestamp");
        let checksum: String = row.get("checksum");

        ClipboardEntry {
            id: Some(id),
            content_type: ClipboardContentType::from_str(&content_type_str)
                .unwrap_or(ClipboardContentType::Text),
            content,
            metadata,
            source,
            timestamp: Utc.timestamp_opt(timestamp, 0).unwrap(),
            checksum,
        }
    }
}
