// Fallback clipboard implementation using xclip directly
// Used when arboard can't access clipboard (some clipboard managers)

use anyhow::Result;
use std::process::Command;
use tracing::{debug, warn};

pub fn get_text_via_xclip() -> Result<Option<String>> {
    debug!("Attempting to read clipboard via xclip fallback");

    // First, try to get the default STRING target
    let output = Command::new("xclip")
        .args(&["-o", "-selection", "clipboard"])
        .output()?;

    if !output.status.success() {
        let error = String::from_utf8_lossy(&output.stderr);
        warn!("xclip failed with default target: {}", error);

        // If STRING target not available, try other common text targets
        debug!("Trying alternative targets...");

        // Try UTF8_STRING
        let output_utf8 = Command::new("xclip")
            .args(&["-o", "-selection", "clipboard", "-t", "UTF8_STRING"])
            .output()?;

        if output_utf8.status.success() && !output_utf8.stdout.is_empty() {
            let content = String::from_utf8(output_utf8.stdout)?;
            debug!("xclip: found {} bytes via UTF8_STRING target", content.len());
            return Ok(Some(content));
        }

        // Try TEXT
        let output_text = Command::new("xclip")
            .args(&["-o", "-selection", "clipboard", "-t", "TEXT"])
            .output()?;

        if output_text.status.success() && !output_text.stdout.is_empty() {
            let content = String::from_utf8(output_text.stdout)?;
            debug!("xclip: found {} bytes via TEXT target", content.len());
            return Ok(Some(content));
        }

        // Try text/plain
        let output_plain = Command::new("xclip")
            .args(&["-o", "-selection", "clipboard", "-t", "text/plain"])
            .output()?;

        if output_plain.status.success() && !output_plain.stdout.is_empty() {
            let content = String::from_utf8(output_plain.stdout)?;
            debug!("xclip: found {} bytes via text/plain target", content.len());
            return Ok(Some(content));
        }

        warn!("All xclip targets failed or returned empty");

        // Try xsel as a last resort
        debug!("Trying xsel as alternative...");
        if let Ok(xsel_output) = Command::new("xsel")
            .args(&["-o", "-b"])
            .output()
        {
            if xsel_output.status.success() && !xsel_output.stdout.is_empty() {
                let content = String::from_utf8(xsel_output.stdout)?;
                debug!("xsel: found {} bytes", content.len());
                return Ok(Some(content));
            }
        }

        warn!("All clipboard tools (xclip, xsel) failed");
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
