# Godot Sky

面向 Meta Quest 3 独立运行的超轻量 24 小时天空插件。核心目标是用离线贴图替代实时大气、云和星空计算，只让太阳、月亮、方向光和环境光以低频率更新。

## 设计

- 24 张每小时关键帧天空贴图，运行时仅保留当前与下一张。
- 倒置低细分 `SphereMesh` 直接提供经纬度 UV；片元 Shader 不执行 `atan`、`asin` 或八面体解码。
- 每分钟更新贴图混合比例、太阳、月亮、方向光和环境光。
- 提前预取下一张关键帧贴图，整点优先交换已经加载的资源。
- 单个天空球 Draw Call，每像素两次天空贴图采样。
- 太阳和月亮使用解析圆盘；无体积云、FBM、Ray March、屏幕空间雾和动态 Radiance Cubemap。
- 时间轴加载时校验字段、数值、重复时间和资源路径；坏帧会被跳过并给出明确错误。
- 单关键帧时间轴可作为静态天空使用。
- Quest 使用 Godot 4.6 Compatibility 渲染器和 OpenXR。
- Rust GDExtension 只提供可选的太阳方向计算；未构建原生库时自动使用等价的 GDScript 实现。

## 目录

- `addons/quest_sky/`：可复制到其他 Godot 项目的插件。
- `demo/demo.tscn`：桌面时间预览。
- `demo/xr_demo.tscn`：OpenXR/Quest 场景。
- `native/`：可选 Rust GDExtension。
- `export_presets.cfg`：Quest 3 ARM64 Debug APK 预设。
- `.github/workflows/build-apk.yml`：手动构建并上传测试 APK。

## 使用

1. 将 `addons/quest_sky` 复制到项目。
2. 启用 `Quest Sky` 编辑器插件。
3. 实例化 `addons/quest_sky/quest_sky.tscn`。
4. 默认同步设备真实时间；测试时设置 `sync_system_clock=false` 并修改 `manual_time_minutes`。
5. 替换 `addons/quest_sky/assets/sky/sky_00.svg` 至 `sky_23.svg` 可更换全天视觉风格。
6. 自定义贴图应采用经纬度布局并保持左右边缘无缝；正式美术资源建议使用 2:1 长宽比。

## 构建测试 APK

在 GitHub 仓库的 **Actions → Build Quest APK → Run workflow** 手动执行。成功后从 `quest-sky-debug-apk` Artifact 下载 APK。工作流不会因普通提交自动运行，因此不会持续发送构建邮件。

本地 Android/Rust 构建见 [docs/ANDROID.md](docs/ANDROID.md)。Quest 3 的最终帧时间、热状态和头显内视觉效果仍需实机验证。

## License

MIT
