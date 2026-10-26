# Bringing Xenia to another platform

Everything that isn't drawing lives in `xenia-core`, so a new platform is a new UI over the
same engine. The crate already builds as a `staticlib` (Apple), a `cdylib` (Android and anything
that loads a shared library) and a plain Rust `lib` (Rust front ends).

What each platform provides:

1. **A `SecretStore`** for the session: Keystore (Android), Credential Manager (Windows), Secret
   Service through `libsecret` (Linux).
2. **A `ClientListener`** that hops to the UI thread in order and updates the platform's state.
3. **Words** for the core's enums: `Body`, `Note`, `RoomPreview`, `XeniaError`, `BackupStatus`.
   `apple/Shared/Copy/` is the reference; strings belong in the platform's localization files.
4. **Its own shapes.** Xenia's rows arrive laid out (runs, headers, delivery), but the app decides
   what a bubble, a list and a sheet look like on that platform.

## Android (Kotlin + Jetpack Compose)

```bash
rustup target add aarch64-linux-android x86_64-linux-android
cargo install cargo-ndk
cargo ndk -t arm64-v8a -t x86_64 -o android/app/src/main/jniLibs build -p xenia-core --release
cargo run -p uniffi-bindgen -- generate \
  --library target/aarch64-linux-android/release/libxenia_core.so \
  --language kotlin --out-dir android/core/src/main/kotlin
```

The generated Kotlin uses JNA and coroutines: `XeniaClient.timeline(...)` is a `suspend fun`.
Implement `ClientListener` with a `MutableStateFlow` per value and collect them in Compose.
TLS uses rustls with `rustls-platform-verifier`, which the Matrix SDK already brings in. On
Android it trusts the system's certificates only once it's initialized with the app's context
from JNI and its Android component is in the Gradle build (the Matrix SDK's FFI crate shows how).

## Windows (WinUI 3)

Two good routes:

- **C# with WinUI 3:** generate bindings with
  [uniffi-bindgen-cs](https://github.com/NordSecurity/uniffi-bindgen-cs) against
  `xenia_core.dll` (`cargo build -p xenia-core --release --target x86_64-pc-windows-msvc`).
- **Rust with windows-rs:** depend on `xenia-core` as a Rust crate and call it directly; no
  bindings needed.

## Linux (GTK 4 / libadwaita)

Depend on `xenia-core` directly from a gtk-rs app. `XeniaClient`, `TimelineController` and every
record are plain Rust types; implement the listener traits on types that send to a
`glib::MainContext` channel, and keep the core's async calls on its own runtime (they already
are). Use `libsecret` for the `SecretStore`.

## Checklist for a new platform

- [ ] Secret store, listener bridge, and the words for every enum.
- [ ] Sign in (with the live server check), restore, sign out with its warning.
- [ ] Chats and Rooms, filters, find, invites, the context menu.
- [ ] Conversation: rows, composer with mentions, replies, edits, reactions, attachments.
- [ ] Threads, search, new message and group, browse rooms, details.
- [ ] Settings: account, notifications, privacy, chat backup.
- [ ] Notifications from `on_incoming_message`, with reply and mark as read.
