# Godot Sky

面向 Meta Quest 3 独立运行的超轻量 24 小时天空插件。核心目标是用离线贴图替代实时大气、云和星空计算，只让太阳、月亮、方向光和环境光以低频率更新。

## 纯 Rust 运行时

插件运行时完全由 Rust GDExtension 实现，不包含 GDScript 控制器或后备实现。

`QuestSkyController` 原生类直接继承 `Node3D`，负责：

- 设备时间和手动时间；
- JSON 时间轴读取、校验和任意间距关键帧查找；
- 当前/下一张天空贴图加载及再下一张贴图预取；
- Shader 参数、太阳、月亮、方向光和环境光更新；
- Timer 生命周期和纹理加载失败降级。

Rust 动态库是必需组件。缺少或版本不兼容时，Godot 会明确报告 GDExtension 加载失败，不会静默改走 GDScript。

## 渲染设计

- 24 张每小时关键帧天空贴图，运行时仅持有活动贴图。
- 倒置低细分 `SphereMesh` 直接提供经纬度 UV；片元 Shader 不执行 `atan`、`asin` 或八面体解码。
- 默认每分钟更新一次天空状态。
- 单个天空球 Draw Call，每像素两次天空贴图采样。
- 太阳和月亮使用解析圆盘；无体积云、FBM、Ray March、屏幕空间雾和动态 Radiance Cubemap。
- Quest 使用 Godot 4.6 Compatibility 渲染器和 OpenXR。

## 目录

- `addons/quest_sky/`：Godot 插件、GDExtension 描述文件、Shader、场景和天空资源。
- `native/`：完整 Rust 运行时源码。
- `demo/`：桌面和 OpenXR 测试场景；其中的 GDScript 只负责 Demo UI/启动，不参与插件运行时。
- `.github/workflows/build-apk.yml`：构建 Rust Android ARM64 库并导出测试 APK。

## 使用

源码仓库不会提交平台动态库。先按 [docs/ANDROID.md](docs/ANDROID.md) 构建目标平台库，再使用 Godot 打开项目。

构建完成后，将整个 `addons/quest_sky` 目录复制到目标 Godot 项目，并实例化：

```text
res://addons/quest_sky/quest_sky.tscn
```

默认同步设备真实时间。测试时可设置原生类的：

```text
sync_system_clock = false
manual_time_minutes = 720.0
```

替换 `addons/quest_sky/assets/sky/sky_00.svg` 至 `sky_23.svg` 可更换全天视觉风格。正式资源建议采用左右无缝的 2:1 经纬度贴图。

## 构建测试 APK

在 GitHub 仓库的 **Actions → Build Quest APK → Run workflow** 手动执行。工作流会先构建 Rust Linux/Android GDExtension，再导出 Quest 3 ARM64 APK，并验证 APK 内原生库。

Quest 3 的最终帧时间、热状态和头显内视觉效果仍需实机验证。

## License

MIT
