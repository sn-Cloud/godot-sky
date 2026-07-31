# Quest 3 / Android ARM64 构建

## 依赖

- Godot 4.6.3 标准版与 Android Export Templates
- OpenJDK 17
- Android SDK Platform 35、Build Tools 35.0.1
- Android NDK 28.1.13356709
- Rust stable、`aarch64-linux-android` target、`cargo-ndk`

## 原生库的定位

Rust GDExtension 是可选组件，只负责每分钟一次的太阳方向计算。仓库默认不提交 `godot/quest_sky.gdextension` 和编译产物，因此直接打开仓库时会使用等价的 GDScript 后备实现，不会影响天空功能。

需要验证原生路径时，先构建库，再从模板生成 `.gdextension` 文件。

## Android ARM64 原生库

```bash
rustup target add aarch64-linux-android
cargo install cargo-ndk --locked
mkdir -p godot/bin/android
cargo ndk -t arm64-v8a -o godot/bin/android build --release -p quest_sky_native
cp godot/quest_sky.gdextension.template godot/quest_sky.gdextension
```

生成文件必须位于：

```text
godot/bin/android/arm64-v8a/libquest_sky_native.so
godot/quest_sky.gdextension
```

这与 `godot/quest_sky.gdextension.template` 中的 Android 路径一致。

## Linux 编辑器验证

```bash
cargo build --release -p quest_sky_native
mkdir -p godot/bin/linux
cp target/release/libquest_sky_native.so godot/bin/linux/libquest_sky_native.so
cp godot/quest_sky.gdextension.template godot/quest_sky.gdextension
```

## Windows 编辑器验证

在 PowerShell 中执行：

```powershell
cargo build --release -p quest_sky_native
New-Item -ItemType Directory -Force godot/bin/windows | Out-Null
Copy-Item target/release/quest_sky_native.dll godot/bin/windows/quest_sky_native.dll
Copy-Item godot/quest_sky.gdextension.template godot/quest_sky.gdextension
```

## 导出

在 Godot 中配置 Android SDK 和 Java SDK 路径，选择 `Quest 3 Debug` 导出预设。该预设只包含 ARM64，XR 模式为 OpenXR。

GitHub Actions 会自动执行原生库构建、生成 `.gdextension`、导出 APK，并验证 APK 中只存在一个 `lib/arm64-v8a/libquest_sky_native.so`。正式发布时必须使用自己的 Meta 应用标识和发布签名，不要把签名文件提交到仓库。
