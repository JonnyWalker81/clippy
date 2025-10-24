use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub server: ServerConfig,
    pub client: ClientConfig,
    pub storage: StorageConfig,
    pub sync: SyncConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerConfig {
    #[serde(default = "default_host")]
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default)]
    pub auth_token: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientConfig {
    pub server_host: String,
    #[serde(default = "default_port")]
    pub server_port: u16,
    #[serde(default)]
    pub auth_token: Option<String>,
    #[serde(default = "default_true")]
    pub auto_connect: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageConfig {
    #[serde(default = "default_max_history")]
    pub max_history: usize,
    #[serde(default = "default_max_content_size_mb")]
    pub max_content_size_mb: usize,
    #[serde(default)]
    pub database_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncConfig {
    #[serde(default = "default_interval_ms")]
    pub interval_ms: u64,
    #[serde(default = "default_retry_delay_ms")]
    pub retry_delay_ms: u64,
    #[serde(default = "default_heartbeat_interval_ms")]
    pub heartbeat_interval_ms: u64,
}

fn default_host() -> String {
    "0.0.0.0".to_string()
}

fn default_port() -> u16 {
    9876
}

fn default_max_history() -> usize {
    1000
}

fn default_max_content_size_mb() -> usize {
    10
}

fn default_interval_ms() -> u64 {
    500
}

fn default_retry_delay_ms() -> u64 {
    5000
}

fn default_heartbeat_interval_ms() -> u64 {
    30000
}

fn default_true() -> bool {
    true
}

impl Default for Config {
    fn default() -> Self {
        Self {
            server: ServerConfig {
                host: default_host(),
                port: default_port(),
                auth_token: None,
            },
            client: ClientConfig {
                server_host: "127.0.0.1".to_string(),
                server_port: default_port(),
                auth_token: None,
                auto_connect: true,
            },
            storage: StorageConfig {
                max_history: default_max_history(),
                max_content_size_mb: default_max_content_size_mb(),
                database_path: None,
            },
            sync: SyncConfig {
                interval_ms: default_interval_ms(),
                retry_delay_ms: default_retry_delay_ms(),
                heartbeat_interval_ms: default_heartbeat_interval_ms(),
            },
        }
    }
}

impl Config {
    pub fn load() -> Result<Self> {
        let config_path = Self::config_path()?;

        if config_path.exists() {
            let contents = std::fs::read_to_string(&config_path)?;
            let mut config: Config = toml::from_str(&contents)?;

            // Set default database path if not specified
            if config.storage.database_path.is_none() {
                config.storage.database_path = Some(Self::default_database_path()?);
            }

            Ok(config)
        } else {
            let mut config = Self::default();
            config.storage.database_path = Some(Self::default_database_path()?);
            Ok(config)
        }
    }

    pub fn save(&self) -> Result<()> {
        let config_path = Self::config_path()?;

        if let Some(parent) = config_path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let contents = toml::to_string_pretty(self)?;
        std::fs::write(&config_path, contents)?;

        Ok(())
    }

    pub fn config_path() -> Result<PathBuf> {
        let config_dir = dirs::config_dir()
            .ok_or_else(|| anyhow::anyhow!("Could not determine config directory"))?;
        Ok(config_dir.join("clippy").join("config.toml"))
    }

    pub fn default_database_path() -> Result<PathBuf> {
        let data_dir = dirs::data_local_dir()
            .ok_or_else(|| anyhow::anyhow!("Could not determine data directory"))?;
        Ok(data_dir.join("clippy").join("clipboard.db"))
    }

    pub fn get_database_path(&self) -> PathBuf {
        self.storage
            .database_path
            .clone()
            .unwrap_or_else(|| Self::default_database_path().unwrap())
    }

    pub fn get_source_name() -> String {
        #[cfg(target_os = "macos")]
        return "macos".to_string();

        #[cfg(target_os = "linux")]
        return "nixos".to_string();

        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        return "unknown".to_string();
    }
}
