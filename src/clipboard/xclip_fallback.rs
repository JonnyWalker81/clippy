// Fallback clipboard implementation using xclip directly
// Used when arboard can't access clipboard (some clipboard managers)

use anyhow::Result;
use std::process::Command;
use tracing::{debug, warn};

pub fn get_text_via_xclip() -> Result<Option<String>> {
    debug!("Attempting to read clipboard via xclip fallback");

    // Helper function to validate clipboard content
    fn is_valid_content(content: &str) -> bool {
        // Reject empty content
        if content.is_empty() {
            return false;
        }

        // If content is more than 1 character, it's valid
        if content.len() > 1 {
            return true;
        }

        // Single character - only accept if it's alphanumeric
        // This filters out error indicators like '(' from xclip
        let ch = content.chars().next().unwrap();
        ch.is_alphanumeric()
    }

    // Try multiple targets in order of reliability for Ghostty and modern terminals
    // UTF8_STRING is most reliable for Ghostty terminal
    let targets = ["UTF8_STRING", "STRING", "TEXT", "text/plain"];

    for target in &targets {
        debug!("Trying xclip target: {}", target);

        let output = Command::new("xclip")
            .args(&["-o", "-selection", "clipboard", "-t", target])
            .output()?;

        if output.status.success() {
            if let Ok(content) = String::from_utf8(output.stdout) {
                if is_valid_content(&content) {
                    debug!("xclip: found {} bytes via {} target", content.len(), target);
                    return Ok(Some(content));
                } else {
                    debug!("xclip: target {} returned invalid/empty content", target);
                }
            }
        } else {
            let error = String::from_utf8_lossy(&output.stderr);
            debug!("xclip failed with target {}: {}", target, error);
        }
    }

    // Try xsel as a last resort
    debug!("Trying xsel as alternative...");
    if let Ok(xsel_output) = Command::new("xsel")
        .args(&["-o", "-b"])
        .output()
    {
        if xsel_output.status.success() {
            if let Ok(content) = String::from_utf8(xsel_output.stdout) {
                if is_valid_content(&content) {
                    debug!("xsel: found {} bytes", content.len());
                    return Ok(Some(content));
                }
            }
        }
    }

    warn!("All clipboard tools (xclip, xsel) failed or returned invalid content");
    Ok(None)
}

pub fn set_text_via_xclip(text: &str) -> Result<()> {
    debug!("Attempting to write clipboard via xclip fallback");

    let mut child = Command::new("xclip")
        .args(&["-selection", "clipboard"])
        .stdin(std::process::Stdio::piped())
        .spawn()?;

    if let Some(mut stdin) = child.stdin.take() {
        use std::io::Write;
        stdin.write_all(text.as_bytes())?;
    }

    let status = child.wait()?;

    if !status.success() {
        return Err(anyhow::anyhow!("xclip write failed"));
    }

    debug!("xclip: wrote {} bytes", text.len());
    Ok(())
}

pub fn get_checksum_via_xclip() -> Result<Option<String>> {
    if let Some(text) = get_text_via_xclip()? {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let mut hasher = DefaultHasher::new();
        text.hash(&mut hasher);
        Ok(Some(format!("{:x}", hasher.finish())))
    } else {
        Ok(None)
    }
}

pub fn list_available_targets() -> Result<Vec<String>> {
    debug!("Listing available clipboard targets");

    let output = Command::new("xclip")
        .args(&["-o", "-selection", "clipboard", "-t", "TARGETS"])
        .output()?;

    if !output.status.success() {
        warn!("Failed to list targets: {}", String::from_utf8_lossy(&output.stderr));
        return Ok(Vec::new());
    }

    let targets_str = String::from_utf8_lossy(&output.stdout);
    let targets: Vec<String> = targets_str
        .lines()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    debug!("Available clipboard targets: {:?}", targets);
    Ok(targets)
}
