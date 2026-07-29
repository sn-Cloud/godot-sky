# Quest 3 / Android ARM64 build

Prerequisites:

- Godot 4.6.x with Android export templates
- Rust stable
- Android SDK and NDK
- Rust target: `rustup target add aarch64-linux-android`

Build the native library using the Android NDK linker, then copy/rename it to:

```text
godot/bin/libquest_sky_native.android.release.arm64.so
```

The exact linker path depends on the installed NDK. Follow the upstream godot-rust Android guide for `CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER`.

The demo currently uses the GDScript runtime controller so the project opens before native binaries exist. The Rust library is the native control/math companion and will replace the low-frequency controller after Android and Windows binaries are produced and verified.
