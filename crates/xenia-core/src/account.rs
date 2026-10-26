//! The account's own settings that live on the server or in the stores: profile photo, blocked
//! people, notification keywords, and the space Xenia takes on this device.

use std::path::Path;

use matrix_sdk::{
    media::MediaRetentionPolicy,
    ruma::{UserId, events::ignored_user_list::IgnoredUserListEventContent},
};
use tracing::warn;

use crate::{
    client::XeniaClient,
    error::{XeniaError, Result},
    models::Person,
    runtime::run,
};

/// How much space Xenia's caches take on this device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct StorageUsage {
    /// Photos, videos and files downloaded from conversations. Clearing it is safe: they
    /// download again when needed.
    pub media_bytes: u64,
}

#[uniffi::export]
impl XeniaClient {
    // MARK: Profile photo

    /// Uploads a new profile photo (JPEG or PNG bytes) and uses it.
    pub async fn set_avatar(&self, data: Vec<u8>, mimetype: String) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            let mime: mime::Mime = mimetype.parse().unwrap_or(mime::IMAGE_JPEG);
            core.client.account().upload_avatar(&mime, data).await?;
            Ok::<_, XeniaError>(())
        })
        .await?;
        self.reload_profile().await;
        Ok(())
    }

    pub async fn remove_avatar(&self) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            core.client.account().set_avatar_url(None).await?;
            Ok::<_, XeniaError>(())
        })
        .await?;
        self.reload_profile().await;
        Ok(())
    }

    // MARK: Blocked people

    /// People I've blocked (ignored): their messages and invitations don't reach me.
    pub async fn blocked_people(&self) -> Result<Vec<Person>> {
        let core = self.core().await?;
        run(async move {
            let content = core.client.account().account_data::<IgnoredUserListEventContent>().await?;
            let ids: Vec<_> = content
                .and_then(|raw| raw.deserialize().ok())
                .map(|c| c.ignored_users.into_keys().collect())
                .unwrap_or_default();
            // Profiles load together, not one after another.
            let account = core.client.account();
            let profiles = futures_util::future::join_all(ids.iter().map(|id| account.fetch_user_profile_of(id))).await;
            let mut people = Vec::with_capacity(ids.len());
            for (user_id, profile) in ids.into_iter().zip(profiles) {
                let profile = profile.ok();
                people.push(Person {
                    display_name: profile
                        .as_ref()
                        .and_then(|p| p.get("displayname"))
                        .and_then(|v| v.as_str())
                        .map(str::to_owned),
                    avatar_url: profile
                        .as_ref()
                        .and_then(|p| p.get("avatar_url"))
                        .and_then(|v| v.as_str())
                        .map(str::to_owned),
                    user_id: user_id.to_string(),
                });
            }
            people.sort_by_key(|p| crate::text::normalize_for_search(&p.name()));
            Ok(people)
        })
        .await
    }

    /// The IDs of people I've blocked, from what this device already knows (no request).
    pub async fn blocked_user_ids(&self) -> Vec<String> {
        let Ok(core) = self.core().await else { return Vec::new() };
        core.client.subscribe_to_ignore_user_list_changes().get()
    }

    pub async fn block(&self, user_id: String) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            core.client.account().ignore_user(&UserId::parse(&user_id)?).await?;
            Ok(())
        })
        .await
    }

    pub async fn unblock(&self, user_id: String) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            core.client.account().unignore_user(&UserId::parse(&user_id)?).await?;
            Ok(())
        })
        .await
    }

    // MARK: Keywords

    /// Words that notify like a mention, from the account's push rules (shared by every device).
    pub async fn notification_keywords(&self) -> Result<Vec<String>> {
        let core = self.core().await?;
        run(async move {
            let settings = core.client.notification_settings().await;
            let mut words: Vec<String> = settings.enabled_keywords().await.into_iter().collect();
            words.sort_by_key(|w| w.to_lowercase());
            Ok(words)
        })
        .await
    }

    pub async fn add_notification_keyword(&self, keyword: String) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            let word = keyword.trim().to_owned();
            if word.is_empty() {
                return Ok(());
            }
            core.client.notification_settings().await.add_keyword(word).await.map_err(XeniaError::generic)?;
            core.reload_keywords().await;
            Ok(())
        })
        .await
    }

    pub async fn remove_notification_keyword(&self, keyword: String) -> Result<()> {
        let core = self.core().await?;
        run(async move {
            core.client.notification_settings().await.remove_keyword(&keyword).await.map_err(XeniaError::generic)?;
            core.reload_keywords().await;
            Ok(())
        })
        .await
    }

    // MARK: Storage

    /// Downloaded media in the SDK's media store, plus files saved for Quick Look and sharing.
    pub async fn storage_usage(&self) -> StorageUsage {
        let cache = self.cache_dir();
        let Ok(core) = self.core().await else { return StorageUsage { media_bytes: 0 } };
        run(async move {
            let store = core.client.get_store_sizes().await.ok().and_then(|s| s.media_store).unwrap_or(0);
            // A walk of the disk: off the async threads.
            let files = crate::media::saved_files_dir(&cache);
            let saved = tokio::task::spawn_blocking(move || folder_size(&files)).await.unwrap_or(0);
            StorageUsage { media_bytes: store as u64 + saved }
        })
        .await
    }

    /// Removes downloaded photos and files. Messages, keys and settings stay.
    pub async fn clear_media_cache(&self) -> Result<()> {
        let core = self.core().await?;
        let cache = self.cache_dir();
        run(async move {
            let files = crate::media::saved_files_dir(&cache);
            if let Err(error) = tokio::fs::remove_dir_all(&files).await
                && error.kind() != std::io::ErrorKind::NotFound
            {
                warn!("Couldn't remove saved files: {error}");
            }
            // The SDK's media store empties itself when the policy allows nothing, then goes back
            // to its usual limits.
            let media = core.client.media();
            media
                .set_media_retention_policy(MediaRetentionPolicy::new().with_max_cache_size(Some(0)))
                .await
                .map_err(XeniaError::generic)?;
            let cleaned = media.clean().await.map_err(XeniaError::generic);
            media.set_media_retention_policy(MediaRetentionPolicy::new()).await.map_err(XeniaError::generic)?;
            cleaned?;
            // SQLite keeps the freed pages until it's vacuumed; without this the space never
            // comes back.
            if let Ok(store) = core.client.media_store().lock().await
                && let Err(error) = store.optimize().await
            {
                warn!("Couldn't compact the media store: {error}");
            }
            Ok(())
        })
        .await
    }
}

fn folder_size(path: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(path) else { return 0 };
    entries
        .flatten()
        .map(|entry| match entry.metadata() {
            Ok(meta) if meta.is_dir() => folder_size(&entry.path()),
            Ok(meta) => meta.len(),
            Err(_) => 0,
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folder_size_counts_nested_files_and_tolerates_missing_folders() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a"), [0u8; 10]).unwrap();
        std::fs::create_dir(dir.path().join("sub")).unwrap();
        std::fs::write(dir.path().join("sub").join("b"), [0u8; 32]).unwrap();
        assert_eq!(folder_size(dir.path()), 42);
        assert_eq!(folder_size(&dir.path().join("missing")), 0);
    }
}
