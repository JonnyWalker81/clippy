use anyhow::Result;
use arboard::{Clipboard as ArboardClipboard, ImageData};
use std::borrow::Cow;

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
        // Try to get image first (higher priority)
        if let Ok(image) = self.clipboard.get_image() {
            let png_data = Self::image_to_png(&image)?;
            return Ok(Some(ClipboardContent::Image(png_data)));
        }

        // Try to get text
        if let Ok(text) = self.clipboard.get_text() {
            return Ok(Some(ClipboardContent::Text(text)));
        }

        // Try to get HTML (if available on platform)
        #[cfg(target_os = "linux")]
        {
            // Linux-specific HTML handling would go here
        }

        Ok(None)
    }

    /// Set clipboard content
    pub fn set_content(&mut self, content: &ClipboardContent) -> Result<()> {
        match content {
            ClipboardContent::Text(text) => {
                self.clipboard.set_text(text)?;
            }
            ClipboardContent::Image(png_data) => {
                let image_data = Self::png_to_image_static(png_data)?;
                self.clipboard.set_image(image_data)?;
            }
            ClipboardContent::Html(html) => {
                // For now, fall back to text
                // Platform-specific HTML handling can be added
                self.clipboard.set_text(html)?;
            }
        }
        Ok(())
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
