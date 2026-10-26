//! Photos, avatars and files. The SDK authenticates, decrypts and caches; apps get bytes or a
//! file on disk.
//!
//! A media handle is either an `mxc://` URL (avatars) or the JSON of a message's media source,
//! which may be encrypted. Apps treat both as opaque strings.

use std::path::{Path, PathBuf};

use matrix_sdk::{
    Client,
    media::{MediaFormat, MediaRequestParameters, MediaThumbnailSettings},
    ruma::{OwnedMxcUri, api::client::media::get_content_thumbnail::v3::Method, events::room::MediaSource},
};

use crate::{
    client::XeniaClient,
    error::{XeniaError, Result},
    runtime::run,
};

pub(crate) fn source_handle(source: &MediaSource) -> String {
    serde_json::to_string(source).unwrap_or_default()
}

fn parse_source(handle: &str) -> Result<MediaSource> {
    let handle = handle.trim();
    if handle.starts_with("mxc://") {
        return Ok(MediaSource::Plain(OwnedMxcUri::from(handle)));
    }
    serde_json::from_str(handle).map_err(|_| XeniaError::NotFound)
}

/// Where files saved for Quick Look, sharing and dragging out live. Decrypted copies, so they go
/// when the session ends.
pub(crate) fn saved_files_dir(cache_dir: &str) -> PathBuf {
    Path::new(cache_dir).join("files")
}

/// A file name that's safe on every file system: no separators, and short enough for one (most
/// allow 255 bytes), keeping its extension.
fn safe_file_name(name: &str) -> String {
    const MAX_BYTES: usize = 200;
    let cleaned: String = name
        .chars()
        // Bidirectional overrides would let "invoice\u{202E}fdp.command" pass for a PDF.
        .filter(|c| !matches!(c, '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{200E}' | '\u{200F}'))
        .map(|c| if matches!(c, '/' | '\\' | ':') || c.is_control() { '-' } else { c })
        .collect();
    let trimmed = cleaned.trim().trim_start_matches('.');
    if trimmed.is_empty() {
        return "file".to_owned();
    }
    if trimmed.len() <= MAX_BYTES {
        return trimmed.to_owned();
    }
    let ext = Path::new(trimmed).extension().and_then(|e| e.to_str()).filter(|e| e.len() <= 16);
    let keep = MAX_BYTES - ext.map_or(0, |e| e.len() + 1);
    let mut end = keep;
    while !trimmed.is_char_boundary(end) {
        end -= 1;
    }
    let stem = trimmed[..end].trim_end();
    match ext {
        Some(ext) => format!("{stem}.{ext}"),
        None => stem.to_owned(),
    }
}

/// Names a source's cache folder. Cryptographic, so nobody can craft a source that lands in
/// another file's folder.
fn stable_hash(text: &str) -> String {
    use sha2::Digest;
    sha2::Sha256::digest(text.as_bytes()).iter().take(16).map(|b| format!("{b:02x}")).collect()
}

/// A square avatar thumbnail, `size_px` on a side.
pub(crate) async fn avatar_bytes(client: &Client, mxc_url: String, size_px: u32) -> Result<Vec<u8>> {
    let source = MediaSource::Plain(OwnedMxcUri::from(mxc_url));
    let settings = MediaThumbnailSettings::with_method(Method::Crop, size_px.into(), size_px.into());
    let request = MediaRequestParameters { source, format: MediaFormat::Thumbnail(settings) };
    Ok(client.media().get_media_content(&request, true).await?)
}

/// A photo scaled to fit, or whole when the server can't scale it (encrypted).
pub(crate) async fn thumbnail_bytes(client: &Client, source: String, width_px: u32, height_px: u32) -> Result<Vec<u8>> {
    let source = parse_source(&source)?;
    if let MediaSource::Plain(_) = source {
        let settings = MediaThumbnailSettings::with_method(Method::Scale, width_px.into(), height_px.into());
        let request = MediaRequestParameters { source: source.clone(), format: MediaFormat::Thumbnail(settings) };
        if let Ok(bytes) = client.media().get_media_content(&request, true).await {
            return Ok(bytes);
        }
        // A photo still uploading (the send queue's local copy) or a server that can't
        // thumbnail it: fall back to the file itself.
    }
    let request = MediaRequestParameters { source, format: MediaFormat::File };
    Ok(client.media().get_media_content(&request, true).await?)
}

#[uniffi::export]
impl XeniaClient {
    /// A square avatar thumbnail, `size_px` on a side (ask for 2x or 3x the point size).
    pub async fn load_avatar(&self, mxc_url: String, size_px: u32) -> Result<Vec<u8>> {
        let core = self.core().await?;
        run(async move { avatar_bytes(&core.client, mxc_url, size_px).await }).await
    }

    /// A photo scaled to fit `width_px` by `height_px`. Encrypted photos can't be thumbnailed by
    /// the server, so they come at full size.
    pub async fn load_thumbnail(&self, source: String, width_px: u32, height_px: u32) -> Result<Vec<u8>> {
        let core = self.core().await?;
        run(async move { thumbnail_bytes(&core.client, source, width_px, height_px).await }).await
    }

    /// What a link shows, read by the homeserver so the site never sees this device. `None`
    /// when the page has nothing to show.
    pub async fn link_preview(&self, url: String) -> Result<Option<LinkPreview>> {
        let core = self.core().await?;
        run(async move {
            use matrix_sdk::ruma::api::client::authenticated_media::get_media_preview::v1::Request;
            let response = core.client.send(Request::new(url.clone())).await?;
            let Some(data) = response.data else { return Ok(None) };
            let json: serde_json::Value = serde_json::from_str(data.get()).unwrap_or_default();
            Ok(link_preview(&url, &json))
        })
        .await
    }

    /// The whole file behind a message, decrypted.
    pub async fn load_media(&self, source: String) -> Result<Vec<u8>> {
        let core = self.core().await?;
        run(async move {
            let request = MediaRequestParameters { source: parse_source(&source)?, format: MediaFormat::File };
            Ok(core.client.media().get_media_content(&request, true).await?)
        })
        .await
    }

    /// Saves the file behind a message under its own name in the cache, for Quick Look, sharing
    /// and dragging out. Returns its path.
    pub async fn save_media(&self, source: String, filename: String) -> Result<String> {
        let core = self.core().await?;
        let cache_dir = self.cache_dir();
        run(async move {
            let dir = saved_files_dir(&cache_dir).join(stable_hash(&source));
            let path = dir.join(safe_file_name(&filename));
            if !path.exists() {
                let request = MediaRequestParameters { source: parse_source(&source)?, format: MediaFormat::File };
                let bytes = core.client.media().get_media_content(&request, true).await?;
                tokio::fs::create_dir_all(&dir).await?;
                // Written aside and moved into place, so a write cut short is never served.
                let partial = dir.join(format!(".partial-{}", uuid::Uuid::new_v4().simple()));
                if let Err(error) = tokio::fs::write(&partial, bytes).await {
                    let _ = tokio::fs::remove_file(&partial).await;
                    return Err(error.into());
                }
                if let Err(error) = tokio::fs::rename(&partial, &path).await {
                    let _ = tokio::fs::remove_file(&partial).await;
                    return Err(error.into());
                }
            }
            Ok(path.to_string_lossy().into_owned())
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_names_are_safe() {
        assert_eq!(safe_file_name("a/b:c.pdf"), "a-b-c.pdf");
        assert_eq!(safe_file_name("..hidden"), "hidden");
        assert_eq!(safe_file_name("  "), "file");
        assert_eq!(safe_file_name("invoice\u{202E}fdp.command"), "invoicefdp.command");
        assert_eq!(safe_file_name("two\nlines.txt"), "two-lines.txt");
        let long = format!("{}.pdf", "é".repeat(150));
        let short = safe_file_name(&long);
        assert!(short.len() <= 200 && short.ends_with(".pdf"), "{short}");
    }

    #[test]
    fn handles_round_trip() {
        let source = MediaSource::Plain(OwnedMxcUri::from("mxc://localhost/abc"));
        let handle = source_handle(&source);
        assert!(matches!(parse_source(&handle).unwrap(), MediaSource::Plain(u) if u.as_str() == "mxc://localhost/abc"));
        assert!(matches!(parse_source("mxc://localhost/abc").unwrap(), MediaSource::Plain(_)));
    }
}

/// A link's preview, as the homeserver read it from the page.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LinkPreview {
    pub url: String,
    pub title: Option<String>,
    pub description: Option<String>,
    pub site_name: Option<String>,
    /// The page's image, kept on the homeserver: pass to the media loader.
    pub image: Option<String>,
    pub image_width: u32,
    pub image_height: u32,
}

/// The fields worth showing from the homeserver's OpenGraph data; `None` when there's no title
/// and no image.
fn link_preview(url: &str, data: &serde_json::Value) -> Option<LinkPreview> {
    let text = |key: &str| {
        data.get(key).and_then(serde_json::Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
    };
    let number = |key: &str| {
        let value = data.get(key)?;
        value.as_u64().or_else(|| value.as_str()?.trim().parse().ok()).and_then(|n| u32::try_from(n).ok())
    };
    // Only media the homeserver keeps, never a web address that would reach the site.
    let image = text("og:image").filter(|i| i.starts_with("mxc://"));
    let title = text("og:title");
    if title.is_none() && image.is_none() {
        return None;
    }
    Some(LinkPreview {
        url: url.to_owned(),
        title,
        description: text("og:description"),
        site_name: text("og:site_name"),
        image,
        image_width: number("og:image:width").unwrap_or(0),
        image_height: number("og:image:height").unwrap_or(0),
    })
}

#[cfg(test)]
mod link_preview_tests {
    use super::link_preview;
    use serde_json::json;

    #[test]
    fn keeps_what_a_card_shows() {
        let data = json!({
            "og:title": " Apple ",
            "og:site_name": "Apple",
            "og:image": "mxc://example.org/abc",
            "og:image:width": 1200,
            "og:image:height": "630",
            "matrix:image:size": 1000,
        });
        let preview = link_preview("https://apple.com", &data).expect("preview");
        assert_eq!(preview.title.as_deref(), Some("Apple"));
        assert_eq!(preview.image.as_deref(), Some("mxc://example.org/abc"));
        assert_eq!((preview.image_width, preview.image_height), (1200, 630), "sizes come as numbers or text");
    }

    #[test]
    fn drops_pages_with_nothing_to_show_and_images_from_the_web() {
        assert!(link_preview("https://a.b", &json!({ "og:description": "Only a description" })).is_none());
        let preview =
            link_preview("https://a.b", &json!({ "og:title": "T", "og:image": "https://tracker.example/i.png" }));
        assert_eq!(preview.and_then(|p| p.image), None);
    }
}
