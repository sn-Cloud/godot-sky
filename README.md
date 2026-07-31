# Godot Sky

面向 Meta Quest 3 独立运行的超轻量 24 小时天空插件。核心目标是以贴图关键帧替代实时大气、云和星空计算，只让太阳、月亮和灯光以每分钟一次的频率更新。

## 设计

- 24 张每小时关键帧天空贴图，运行时仅保留当前与下一张。
- 每分钟更新贴图混合比例、太阳、月亮、方向光和环境光。
- 单个倒置天空盒 Draw Call。
- 每像素两次天空贴图采样；太阳和月亮使用解析圆盘。
- 无体积云、FBM、Ray March、屏幕空间雾和动态 Radiance Cubemap。
- Quest 使用 Godot 4.6 Compatibility 渲染器和 OpenXR。
- Rust GDExtension 提供原生时间/方向数学；没有原生库时自动使用 GDScript 后备实现。

## 目录

- `addons/quest_sky/`：可复制到其他 Godot 项目的插件。
- `demo/demo.tscn`：桌面时间预览。
- `demo/xr_demo.tscn`：OpenXR/Quest 场景。
- `native/`：Rust GDExtension。
- `export_presets.cfg`：Quest 3 ARM64 Debug APK 预设。
- `.github/workflows/build-apk.yml`：手动构建并上传测试 APK。

## 使用

1. 将 `addons/quest_sky` 复制到项目。
2. 启用 `Quest Sky` 编辑器插件。
3. 实例化 `addons/quest_sky/quest_sky.tscn`。
4. 默认同步设备真实时间；测试时设置 `sync_system_clock=false` 并修改 `manual_time_minutes`。
5. 替换 `addons/quest_sky/assets/sky/sky_00.svg` 至 `sky_23.svg` 可更换全天视觉风格。

## 构建测试 APK

在 GitHub 仓库的 **Actions → Build Quest APK → Run workflow** 手动执行。成功后从 `quest-sky-debug-apk` Artifact 下载 APK。工作流不会因普通提交自动运行，因此不会持续发送测试失败邮件。

最终集中构建已经通过：

- Rust 格式检查及 3 个单元测试；
- Linux 宿主库和 Android `arm64-v8a` GDExtension 编译；
- Godot 4.6.3 项目导入及 OpenXR Android 调试 APK 导出；
- APK v2/v3 签名验证；
- APK 内 `lib/arm64-v8a/libquest_sky_native.so` 唯一性验证；
- GitHub Artifact 上传。

本地 Android/Rust 构建见 [docs/ANDROID.md](docs/ANDROID.md)。Quest 3 的实际帧时间、热状态和最终视觉效果仍需实机验证。

## License

MIT
