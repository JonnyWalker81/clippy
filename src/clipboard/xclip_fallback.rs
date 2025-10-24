// Fallback clipboard implementation using xclip directly
// Used when arboard can't access clipboard (some clipboard managers)

use anyhow::Result;
use std::process::Command;
use tracing::{debug, warn};

pub fn get_text_via_xclip() -> Result<Option<String>> {
    debug!("Attempting to read clipboard via xclip fallback");

    let output = Command::new("xclip")
        .args(&["-o", "-selection", "clipboard"])
        .output()?;

    if !output.status.success() {
        let error = String::from_utf8_lossy(&output.stderr);
        warn!("xclip failed: {}", error);
        return Ok(None);
    }

    let content = String::from_utf8(output.stdout)?;

    if content.is_empty() {
        debug!("xclip: clipboard is empty");
        Ok(None)
    } else {
        debug!("xclip: found {} bytes", content.len());
        Ok(Some(content))
    }
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
