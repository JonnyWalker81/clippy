# Changelog

## [Unreleased] - 2025-10-24

### Fixed
- **CRITICAL BUG**: Server now applies clipboard updates to local clipboard
  - Previously, server received updates from clients and stored them in database
  - But never applied them to the actual macOS clipboard
  - Now properly updates local clipboard when receiving updates from clients
  - Fixes: NixOS → macOS clipboard sync not working

### Added
- Comprehensive logging throughout clipboard sync flow with emojis
  - 🔍 Clipboard change detection
  - 📋 Content preview in logs
  - 📤 Sending messages
  - 📥 Receiving messages
  - ✓/❌ Success/failure indicators
- Logging shows content type, size, checksum, and source
- Better error messages with context
- Verbose mode (`-v`) for detailed sync tracking

### Improved
- Server logs when applying clipboard updates locally
- Client logs when sending updates to server
- Daemon logs clipboard monitor startup
- Better visibility into sync latency
- Content preview in logs (50 char limit for text)

### Documentation
- Added TESTING.md with comprehensive testing guide
- Added TROUBLESHOOTING.md with common issues
- Added INVESTIGATION.md for diagnosing connection problems
- Added diagnostic scripts:
  - `scripts/diagnose-connection.sh` - Find correct macOS IP and test connectivity
  - `scripts/verify-macos-server.sh` - Verify server configuration
  - `scripts/setup-nixos-vm.sh` - Auto-setup for NixOS VM
  - `scripts/setup-macos-host.sh` - Auto-setup for macOS host
- Added config examples in `config.examples/`
  - `macos-server.toml` - macOS host configuration
  - `nixos-client.toml` - NixOS VM configuration
  - `both-modes.toml` - Bidirectional sync configuration

## [0.1.0] - 2025-10-24

### Initial Release
- Cross-platform clipboard synchronization between NixOS and macOS
- TCP-based client-server architecture
- Support for text, images, HTML, and RTF content
- SQLite-backed persistent clipboard history
- CLI for managing daemon and querying history
- Nix flake for development environment
- Search and filtering capabilities
- Configurable sync intervals and retention policies
