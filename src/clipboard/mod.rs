use anyhow::Result;
use arboard::{Clipboard as ArboardClipboard, ImageData};
use std::borrow::Cow;

#[cfg(target_os = "linux")]
mod xclip_fallback;

#[derive(Debug, Clone)]
pub enum ClipboardContent {
    Text(String),
    Image(Vec<u8>), // PNG encoded
    Html(String),
    // Add more types as needed
}

pub struct ClipboardManager {
    clipboard: ArboardClipboard,
}

impl ClipboardManager {
    pub fn new() -> Result<Self> {
        Ok(Self {
            clipboard: ArboardClipboard::new()?,
        })
    }

    /// Get the current clipboard content
    pub fn get_content(&mut self) -> Result<Option<ClipboardContent>> {
        use tracing::{debug, warn};

        // Try to get image first (higher priority)
        match self.clipboard.get_image() {
            Ok(image) => {
                debug!("Found image in clipboard");
                let png_data = Self::image_to_png(&image)?;
                return Ok(Some(ClipboardContent::Image(png_data)));
            }
            Err(e) => {
                debug!("No image in clipboard: {}", e);
            }
        }

        // Try to get text
        match self.clipboard.get_text() {
            Ok(text) => {
                debug!("Found text in clipboard via arboard: {} bytes", text.len());
                return Ok(Some(ClipboardContent::Text(text)));
            }
            Err(e) => {
                warn!("arboard failed to get text from clipboard: {}", e);

                // Try xclip fallback on Linux
                #[cfg(target_os = "linux")]
                {
                    warn!("Trying xclip fallback...");

                    // List available targets for debugging
                    if let Ok(targets) = xclip_fallback::list_available_targets() {
                        if !targets.is_empty() {
                            debug!("Available clipboard targets: {:?}", targets);
                        }
                    }

                    match xclip_fallback::get_text_via_xclip() {
                        Ok(Some(text)) => {
                            warn!("✓ xclip fallback succeeded! Found {} bytes", text.len());
                            warn!("NOTE: arboard has compatibility issues with your clipboard manager");
                            warn!("Using xclip fallback mode for clipboard access");
                            return Ok(Some(ClipboardContent::Text(text)));
                        }
                        Ok(None) => {
                            debug!("xclip also reports clipboard empty");
                        }
                        Err(xe) => {
                            warn!("xclip fallback also failed: {}", xe);
                        }
                    }
                }

                warn!("This usually means:");
                warn!("  - Clipboard is genuinely empty");
                warn!("  - Or clipboard has unsupported format");
                warn!("  - Or wrong clipboard selection (PRIMARY vs CLIPBOARD)");
            }
        }

        // Try to get HTML (if available on platform)
        #[cfg(target_os = "linux")]
        {
            // Linux-specific HTML handling would go here
        }

        debug!("Clipboard appears to be empty or has unsupported content");
        Ok(None)
    }

    /// Set clipboard content
    pub fn set_content(&mut self, content: &ClipboardContent) -> Result<()> {
        use tracing::warn;

        match content {
            ClipboardContent::Text(text) => {
                match self.clipboard.set_text(text) {
                    Ok(_) => Ok(()),
                    Err(e) => {
                        warn!("arboard failed to set text: {}", e);

                        // Try xclip fallback on Linux
                        #[cfg(target_os = "linux")]
                        {
                            warn!("Trying xclip fallback for write...");
                            xclip_fallback::set_text_via_xclip(text)?;
                            warn!("✓ xclip fallback write succeeded");
                            return Ok(());
                        }

                        #[cfg(not(target_os = "linux"))]
                        return Err(e.into());
                    }
                }
            }
            ClipboardContent::Image(png_data) => {
                let image_data = Self::png_to_image_static(png_data)?;
                self.clipboard.set_image(image_data)?;
                Ok(())
            }
            ClipboardContent::Html(html) => {
                // For now, fall back to text
                // Platform-specific HTML handling can be added
                match self.clipboard.set_text(html) {
                    Ok(_) => Ok(()),
                    Err(e) => {
                        #[cfg(target_os = "linux")]
                        {
                            warn!("arboard failed, trying xclip fallback...");
                            xclip_fallback::set_text_via_xclip(html)?;
                            return Ok(());
                        }

                        #[cfg(not(target_os = "linux"))]
                        return Err(e.into());
                    }
                }
            }
        }
    }

    /// Get a checksum of the current clipboard content
    pub fn get_content_checksum(&mut self) -> Result<Option<String>> {
        if let Some(content) = self.get_content()? {
            Ok(Some(self.calculate_checksum(&content)))
        } else {
            Ok(None)
        }
    }

    fn calculate_checksum(&self, content: &ClipboardContent) -> String {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let mut hasher = DefaultHasher::new();
        match content {
            ClipboardContent::Text(text) => text.hash(&mut hasher),
            ClipboardContent::Image(data) => data.hash(&mut hasher),
            ClipboardContent::Html(html) => html.hash(&mut hasher),
        }
        format!("{:x}", hasher.finish())
    }

    fn image_to_png(image: &ImageData) -> Result<Vec<u8>> {
        use image::{ImageBuffer, RgbaImage};
        use std::io::Cursor;

        let img: RgbaImage = ImageBuffer::from_raw(
            image.width as u32,
            image.height as u32,
            image.bytes.to_vec(),
        )
        .ok_or_else(|| anyhow::anyhow!("Failed to create image buffer"))?;

        let mut png_data = Vec::new();
        img.write_to(&mut Cursor::new(&mut png_data), image::ImageFormat::Png)?;

        Ok(png_data)
    }

    fn png_to_image_static(png_data: &[u8]) -> Result<ImageData<'_>> {
        use image::ImageReader;
        use std::io::Cursor;

        let img = ImageReader::new(Cursor::new(png_data))
            .with_guessed_format()?
            .decode()?
            .to_rgba8();

        let (width, height) = img.dimensions();

        Ok(ImageData {
            width: width as usize,
            height: height as usize,
            bytes: Cow::Owned(img.into_raw()),
        })
    }
}

impl ClipboardContent {
    pub fn to_base64(&self) -> String {
        use base64::{engine::general_purpose::STANDARD, Engine};

        match self {
            ClipboardContent::Text(text) => text.clone(),
            ClipboardContent::Image(data) => STANDARD.encode(data),
            ClipboardContent::Html(html) => html.clone(),
        }
    }

    pub fn from_base64(content_type: &str, data: &str) -> Result<Self> {
        use base64::{engine::general_purpose::STANDARD, Engine};

        match content_type {
            "text" => Ok(ClipboardContent::Text(data.to_string())),
            "image" => {
                let decoded = STANDARD.decode(data)?;
                Ok(ClipboardContent::Image(decoded))
            }
            "html" => Ok(ClipboardContent::Html(data.to_string())),
            _ => Err(anyhow::anyhow!("Unknown content type: {}", content_type)),
        }
    }

    pub fn content_type_str(&self) -> &str {
        match self {
            ClipboardContent::Text(_) => "text",
            ClipboardContent::Image(_) => "image",
            ClipboardContent::Html(_) => "html",
        }
    }
}
