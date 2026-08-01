# Godot Sky

面向 Meta Quest 3 独立运行的超轻量 24 小时天空插件。核心目标是用离线贴图替代实时大气、云和星空计算，只让太阳、月亮、方向光和环境光以低频率更新。

## 纯 Rust 运行时

插件运行时完全由 Rust GDExtension 实现，不包含 GDScript 控制器或后备实现。

`QuestSkyController` 原生类直接继承 `Node3D`，负责：

- 设备时间和手动时间；
- JSON 时间轴读取、校验和任意间距关键帧查找；
- 当前/下一张天空贴图加载及再下一张贴图预取；
- 可见天空与环境天空 Shader 参数、太阳光、月光、环境光和反射更新；
- Timer 生命周期和纹理加载失败降级。

Rust 动态库是必需组件。缺少或版本不兼容时，Godot 会明确报告 GDExtension 加载失败，不会静默改走 GDScript。

`QuestSkyController` 同时是编辑器工具类。实例化 `quest_sky.tscn` 后可直接在 3D 编辑器中预览天空；修改手动时间、系统时间同步、太阳方位偏移或时间轴路径时会立即刷新预览。

## 渲染设计

- 8 张真实感 2:1 经纬度 PNG 关键帧，覆盖午夜、黎明、日出、白天、黄昏和入夜，运行时仅持有活动贴图。
- 可见天空由 Godot 原生 `Environment.sky` 绘制，在 XR 中使用每只眼睛的视线方向，没有近距离球体的双目视差。
- 默认每分钟更新一次天空状态。
- 可见背景、环境漫反射与 PBR 反射共用同一个 `Environment.sky`。
- 太阳和月亮使用解析圆盘；太阳与月亮各有独立的 `DirectionalLight3D`。无体积云、FBM、Ray March 和屏幕空间雾。
- `Environment.sky` 仅在低频时间轴更新时重建辐照/反射数据，不执行逐帧动态大气计算。
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

天空资源位于 `addons/quest_sky/assets/sky/sky_HHMM.png`，时间轴在 8 个关键时段间连续插值。正式资源应采用左右无缝的 2:1 经纬度栅格贴图。

## 构建测试 APK

在 GitHub 仓库的 **Actions → Build Quest APK → Run workflow** 手动执行。工作流会先构建 Rust Linux/Android GDExtension，再导出 Quest 3 ARM64 APK，并验证 APK 内原生库。

Quest 3 的最终帧时间、热状态和头显内视觉效果仍需实机验证。

## License

MIT
