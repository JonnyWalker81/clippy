// Test program to diagnose clipboard access issues
use arboard::Clipboard;
use std::env;

fn main() {
    println!("=== Clipboard Access Test ===\n");

    // Check environment
    println!("Environment:");
    println!("  DISPLAY: {:?}", env::var("DISPLAY"));
    println!("  WAYLAND_DISPLAY: {:?}", env::var("WAYLAND_DISPLAY"));
    println!("  XDG_SESSION_TYPE: {:?}", env::var("XDG_SESSION_TYPE"));
    println!();

    // Try to create clipboard
    println!("Creating clipboard instance...");
    let mut clipboard = match Clipboard::new() {
        Ok(c) => {
            println!("✓ Clipboard created successfully");
            c
        }
        Err(e) => {
            eprintln!("✗ Failed to create clipboard: {}", e);
            eprintln!("\nPossible fixes:");
            eprintln!("  1. Install xclip: nix-shell -p xclip");
            eprintln!("  2. Set DISPLAY: export DISPLAY=:0");
            eprintln!("  3. Run in graphical session (not SSH)");
            return;
        }
    };
    println!();

    // Try to set text
    println!("Writing test text to clipboard...");
    let test_text = format!("clippy-test-{}", std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs());

    match clipboard.set_text(&test_text) {
        Ok(_) => {
            println!("✓ Write successful: {}", test_text);
        }
        Err(e) => {
            eprintln!("✗ Failed to write: {}", e);
        }
    }
    println!();

    // Try to read text
    println!("Reading from clipboard...");
    match clipboard.get_text() {
        Ok(text) => {
            println!("✓ Read successful: {}", text);
            if text == test_text {
                println!("✓ Content matches what we wrote!");
            } else {
                println!("⚠ Content doesn't match (read from existing clipboard)");
            }
        }
        Err(e) => {
            eprintln!("✗ Failed to read: {}", e);
            eprintln!("\nThis means:");
            eprintln!("  - Clipboard is empty");
            eprintln!("  - Or wrong clipboard selection");
            eprintln!("  - Or clipboard has non-text content");
            eprintln!("\nTry manually copying text first:");
            eprintln!("  echo 'test' | xclip -selection clipboard");
            eprintln!("Then run this test again.");
        }
    }
    println!();

    // Try to get current clipboard with xclip
    println!("=== Testing with xclip directly ===");
    use std::process::Command;

    match Command::new("xclip")
        .args(&["-o", "-selection", "clipboard"])
        .output()
    {
        Ok(output) => {
            if output.status.success() {
                let content = String::from_utf8_lossy(&output.stdout);
                if !content.is_empty() {
                    println!("✓ xclip can read clipboard: {}", content.trim());
                    println!("\nBUT arboard cannot read it!");
                    println!("This suggests a format mismatch or arboard/clipboard manager incompatibility.");
                } else {
                    println!("✗ xclip also sees empty clipboard");
                }
            } else {
                println!("✗ xclip failed: {}", String::from_utf8_lossy(&output.stderr));
            }
        }
        Err(e) => {
            println!("✗ Could not run xclip: {}", e);
        }
    }
    println!();

    // Instructions
    println!("=== Manual Test ===");
    println!("1. Copy some text (Ctrl+C or using your application)");
    println!("2. Run this test again");
    println!("3. It should read what you copied");
    println!("\nOr test with xclip:");
    println!("  echo 'hello world' | xclip -selection clipboard");
    println!("  xclip -o -selection clipboard");
    println!("\nIf xclip works but arboard doesn't:");
    println!("  This is a known issue with some clipboard managers");
    println!("  Try: pkill -f 'clipboard' && echo 'test' | xclip -sel c");
}
