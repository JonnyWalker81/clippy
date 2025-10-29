mod client;
mod clipboard;
mod config;
mod daemon;
mod http_sync;
mod server;
mod storage;
mod sync;

use anyhow::Result;
use clap::{Parser, Subcommand};
use config::Config;
use daemon::{ClipboardDaemon, DaemonMode};
use storage::{models::ClipboardSearchQuery, ClipboardStorage};
use tracing::Level;

#[derive(Parser)]
#[command(name = "clippy")]
#[command(about = "Cross-platform clipboard synchronization tool", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Enable verbose logging
    #[arg(short, long, global = true)]
    verbose: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the clipboard daemon
    Start {
        /// Run as server only
        #[arg(long)]
        server: bool,

        /// Run as client only
        #[arg(long)]
        client: bool,
    },

    /// Start HTTP sync client (connects to HTTP server)
    Sync {
        /// Server URL (default: http://localhost:8080)
        #[arg(short, long)]
        server: Option<String>,

        /// Poll interval in milliseconds (default: 200)
        #[arg(short, long)]
        interval: Option<u64>,
    },

    /// Show clipboard history
    History {
        /// Number of entries to show
        #[arg(short, long, default_value = "20")]
        limit: usize,

        /// Offset for pagination
        #[arg(short, long, default_value = "0")]
        offset: usize,

        /// Filter by source (macos or nixos)
        #[arg(short, long)]
        source: Option<String>,

        /// Filter by content type (text, image, html)
        #[arg(short, long)]
        type_filter: Option<String>,
    },

    /// Search clipboard history
    Search {
        /// Search text
        query: String,

        /// Number of results
        #[arg(short, long, default_value = "20")]
        limit: usize,
    },

    /// Clear clipboard history
    Clear {
        /// Skip confirmation
        #[arg(short, long)]
        yes: bool,
    },

    /// Show statistics
    Stats,

    /// Initialize or update configuration
    Config {
        /// Show current configuration
        #[arg(long)]
        show: bool,

        /// Initialize with default configuration
        #[arg(long)]
        init: bool,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    // Initialize logging
    let log_level = if cli.verbose {
        Level::DEBUG
    } else {
        Level::INFO
    };

    tracing_subscriber::fmt()
        .with_max_level(log_level)
        .with_target(false)
        .init();

    match cli.command {
        Commands::Start { server, client } => {
            let config = Config::load()?;

            let mode = match (server, client) {
                (true, false) => DaemonMode::Server,
                (false, true) => DaemonMode::Client,
                _ => DaemonMode::Both,
            };

            let daemon = ClipboardDaemon::new(config, mode);
            daemon.run().await?;
        }

        Commands::Sync { server, interval } => {
            let config = Config::load()?;

            let server_url = server.unwrap_or_else(|| {
                format!("http://{}:{}", config.client.server_host, config.client.server_port)
            });

            let poll_interval = interval.unwrap_or(200);

            let mut sync_client = http_sync::HttpSyncClient::new(server_url, poll_interval);
            sync_client.run().await?;
        }

        Commands::History {
            limit,
            offset,
            source,
            type_filter,
        } => {
            let config = Config::load()?;
            let storage = ClipboardStorage::new(
                config.get_database_path(),
                config.storage.max_history,
            )
            .await?;

            let content_type = type_filter
                .and_then(|t| storage::models::ClipboardContentType::from_str(&t));

            let query = ClipboardSearchQuery {
                content_type,
                source,
                search_text: None,
                limit,
                offset,
            };

            let entries = storage.search(&query).await?;

            if entries.is_empty() {
                println!("No clipboard history found");
            } else {
                println!("\nClipboard History ({} entries):\n", entries.len());
                for entry in entries {
                    println!("ID: {}", entry.id.unwrap_or(0));
                    println!("Type: {}", entry.content_type.as_str());
                    println!("Source: {}", entry.source);
                    println!("Time: {}", entry.timestamp.format("%Y-%m-%d %H:%M:%S"));
                    println!("Checksum: {}", entry.checksum);

                    // Show preview of content
                    let preview = if entry.content.len() > 100 {
                        format!("{}...", &entry.content[..100])
                    } else {
                        entry.content.clone()
                    };

                    match entry.content_type {
                        storage::models::ClipboardContentType::Text => {
                            println!("Content: {}", preview);
                        }
                        storage::models::ClipboardContentType::Image => {
                            println!("Content: [Image data, {} bytes]", entry.content.len());
                        }
                        _ => {
                            println!("Content: {}", preview);
                        }
                    }

                    println!("---");
                }
            }
        }

        Commands::Search { query, limit } => {
            let config = Config::load()?;
            let storage = ClipboardStorage::new(
                config.get_database_path(),
                config.storage.max_history,
            )
            .await?;

            let search_query = ClipboardSearchQuery {
                search_text: Some(query.clone()),
                limit,
                ..Default::default()
            };

            let entries = storage.search(&search_query).await?;

            if entries.is_empty() {
                println!("No results found for '{}'", query);
            } else {
                println!("\nSearch Results for '{}' ({} entries):\n", query, entries.len());
                for entry in entries {
                    println!("ID: {}", entry.id.unwrap_or(0));
                    println!("Type: {}", entry.content_type.as_str());
                    println!("Source: {}", entry.source);
                    println!("Time: {}", entry.timestamp.format("%Y-%m-%d %H:%M:%S"));

                    let preview = if entry.content.len() > 100 {
                        format!("{}...", &entry.content[..100])
                    } else {
                        entry.content.clone()
                    };
                    println!("Content: {}", preview);
                    println!("---");
                }
            }
        }

        Commands::Clear { yes } => {
            if !yes {
                println!("This will clear all clipboard history. Are you sure? (y/N)");
                let mut input = String::new();
                std::io::stdin().read_line(&mut input)?;
                if !input.trim().eq_ignore_ascii_case("y") {
                    println!("Cancelled");
                    return Ok(());
                }
            }

            let config = Config::load()?;
            let storage = ClipboardStorage::new(
                config.get_database_path(),
                config.storage.max_history,
            )
            .await?;

            storage.clear().await?;
            println!("Clipboard history cleared");
        }

        Commands::Stats => {
            let config = Config::load()?;
            let storage = ClipboardStorage::new(
                config.get_database_path(),
                config.storage.max_history,
            )
            .await?;

            let count = storage.get_count().await?;
            println!("\nClipboard Statistics:");
            println!("Total entries: {}", count);
            println!("Max history: {}", config.storage.max_history);
            println!("Database path: {}", config.get_database_path().display());
        }

        Commands::Config { show, init } => {
            if show {
                let config = Config::load()?;
                println!("\nCurrent Configuration:");
                println!("{}", toml::to_string_pretty(&config)?);
            } else if init {
                let config = Config::default();
                config.save()?;
                println!(
                    "Configuration initialized at: {}",
                    Config::config_path()?.display()
                );
                println!("\nDefault configuration:");
                println!("{}", toml::to_string_pretty(&config)?);
            } else {
                println!("Use --show to display current config or --init to create default config");
            }
        }
    }

    Ok(())
}
