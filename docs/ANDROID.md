# Quest 3 / Android ARM64 构建

## 依赖

- Godot 4.6.3 标准版与 Android Export Templates
- OpenJDK 17
- Android SDK Platform 35、Build Tools 35.0.1
- Android NDK 28.1.13356709
- Rust stable、`aarch64-linux-android` target、`cargo-ndk`

## 原生库

```bash
rustup target add aarch64-linux-android
cargo install cargo-ndk --locked
cargo ndk -t arm64-v8a -o godot/bin build --release -p quest-sky-native
```

把生成的 `libquest_sky_native.so` 复制为：

```text
godot/bin/libquest_sky_native.android.release.arm64.so
godot/bin/libquest_sky_native.android.debug.arm64.so
```

再复制：

```text
godot/quest_sky.gdextension.template
godot/quest_sky.gdextension
```

## 导出

在 Godot 中配置 Android SDK 和 Java SDK 路径，选择 `Quest 3 Debug` 导出预设。该预设只包含 ARM64，XR 模式为 OpenXR。

GitHub Actions 已自动执行上述步骤并输出测试 APK。正式发布时必须使用你自己的 Meta 应用标识和发布签名，不要把签名文件提交到仓库。
