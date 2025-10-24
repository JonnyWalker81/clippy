{
  description = "Cross-platform clipboard synchronization tool";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        rustToolchain = pkgs.rust-bin.nightly.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        };

        # Platform-specific dependencies
        darwinDeps = with pkgs; lib.optionals stdenv.isDarwin [
          darwin.apple_sdk.frameworks.AppKit
          darwin.apple_sdk.frameworks.Cocoa
        ];

        linuxDeps = with pkgs; lib.optionals stdenv.isLinux [
          xorg.libX11
          xorg.libXcursor
          xorg.libXi
          xorg.libXrandr
          wayland
          libxkbcommon
          # Clipboard utilities for runtime
          xclip  # X11 clipboard tool
          wl-clipboard  # Wayland clipboard tool
        ];
      in
      {
        packages.default = pkgs.rustPlatform.buildRustPackage {
          pname = "clippy";
          version = "0.1.0";

          src = ./.;

          cargoLock = {
            lockFile = ./Cargo.lock;
          };

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          buildInputs = with pkgs; [
            openssl
            sqlite
          ] ++ darwinDeps ++ linuxDeps;

          meta = with pkgs.lib; {
            description = "Cross-platform clipboard synchronization between NixOS and macOS";
            license = licenses.mit;
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            rustToolchain
            pkg-config
            openssl
            sqlite
          ] ++ darwinDeps ++ linuxDeps;

          shellHook = ''
            echo "Clippy - Cross-platform clipboard sync"
            echo "Rust nightly development environment"
            rustc --version
            cargo --version
            echo ""
            echo "Commands:"
            echo "  cargo build          - Build the project"
            echo "  cargo run -- start   - Start clipboard daemon"
            echo "  cargo run -- --help  - Show all commands"
          '';
        };
      }
    );
}
