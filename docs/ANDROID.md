# VRSky 的 Quest 3 / Android ARM64 构建

## 依赖

- Godot 4.6.3 标准版与 Android Export Templates
- OpenJDK 17
- Android SDK Platform 35、Build Tools 35.0.1
- Android NDK 28.1.13356709
- Rust stable、`aarch64-linux-android` target、`cargo-ndk`

## 渲染器基线

项目固定使用 Godot Mobile 渲染器。桌面串流预览通过 RenderingDevice 后端运行，Quest 3 独立运行使用 Mobile + Vulkan；Compatibility / OpenGL 不是本项目的验证目标。

`project.godot` 必须保留以下设置：

```ini
[rendering]
renderer/rendering_method="mobile"
```

`config/features` 同时记录 `"Mobile"`。Godot 会省略值等于平台默认值的 `renderer/rendering_method.mobile`；这不代表移动端切换到了其他渲染器。

## 原生库是必需组件

VRSky 插件运行时全部由 Rust GDExtension 实现。仓库不包含 GDScript 后备控制器，也不会在原生库缺失时继续运行。

GDExtension 描述文件固定为：

```text
addons/vrsky/vrsky.gdextension
```

源码仓库不会提交平台动态库。打开 Godot 项目前，需要至少构建当前编辑器平台对应的原生库。

## Android ARM64 原生库

```bash
rustup target add aarch64-linux-android
cargo install cargo-ndk --locked
mkdir -p addons/vrsky/bin/android
cargo ndk -t arm64-v8a -o addons/vrsky/bin/android build --release -p vrsky_native
```

生成文件必须位于：

```text
addons/vrsky/bin/android/arm64-v8a/libvrsky_native.so
```

## Linux 编辑器验证

```bash
cargo build --release -p vrsky_native
mkdir -p addons/vrsky/bin/linux
cp target/release/libvrsky_native.so addons/vrsky/bin/linux/libvrsky_native.so
```

## Windows 编辑器验证

在 PowerShell 中执行：

```powershell
cargo build --release -p vrsky_native
New-Item -ItemType Directory -Force addons/vrsky/bin/windows | Out-Null
Copy-Item target/release/vrsky_native.dll addons/vrsky/bin/windows/vrsky_native.dll
```

## 验证

构建当前平台库后执行：

```bash
cargo fmt --all -- --check
cargo test --workspace
cargo check --workspace --release
```

然后使用 Godot 4.6.3 以 Mobile 渲染器导入项目并运行 `demo/demo.tscn`。启动日志应显示 Mobile 渲染方法及 Vulkan、Direct3D 12 或 Metal 驱动，而不是 OpenGL。若原生库缺失、损坏或与平台不兼容，Godot 会报告 GDExtension 加载错误；这是预期行为，不存在 GDScript 降级路径。

## 导出 Quest APK

在 Godot 中配置 Android SDK 和 Java SDK 路径，选择 `VRSky Quest 3 Debug` 导出预设。该预设只包含 ARM64，XR 模式为 OpenXR。

GitHub Actions 会构建 Linux 宿主库和 Android ARM64 库、导出 APK，并验证 APK 中只存在一个 `lib/arm64-v8a/libvrsky_native.so`。正式发布时必须使用自己的 Meta 应用标识和发布签名，不要把签名文件提交到仓库。
