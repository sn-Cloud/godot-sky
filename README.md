# Godot Sky

面向 Meta Quest 3 独立运行的超轻量 24 小时天空系统。

## 当前实现

- 天空、云、星星全部烘焙进 4 张八面体映射占位贴图；
- 每六小时一个占位关键帧，运行时仅混合当前和下一张贴图；
- 默认每 60 秒更新一次贴图混合比例、太阳、月亮、方向光和环境光；
- 太阳、月亮使用解析圆盘，不做大气散射或额外纹理采样；
- 不使用体积云、FBM、Ray March、屏幕空间雾或动态 Radiance Cubemap；
- 天空立方体在 Shader 中移除相机平移，不需要每帧 CPU 跟随；
- Godot 4.6 Mobile Renderer；
- 包含 Rust GDExtension 数学/控制核心和可立即运行的 GDScript 参考控制器。

## 性能模型

天空主体每像素约为：

- 两次 2D 贴图采样；
- 一次贴图插值；
- 八面体方向映射；
- 太阳、月亮各一个点积和 `smoothstep`。

CPU 默认每分钟更新一次，不存在每帧天空逻辑。

## 运行演示

1. 使用 Godot 4.6.x 打开仓库根目录。
2. 运行 `demo/demo.tscn`。
3. 拖动左上角滑块查看完整 24 小时变化。

## 集成

将 `addons/quest_sky` 复制到目标项目，然后实例化：

```text
res://addons/quest_sky/quest_sky.tscn
```

默认使用系统本地时间。测试时可关闭 `sync_system_clock` 并设置 `manual_time_minutes`。

## 资源约定

当前 256×256 图片是自动生成的占位资源，用于验证渲染路径、切换逻辑和性能。最终版本将替换为美术质量贴图，并保留完全相同的运行时架构。

## Rust

当前 godot-rust 依赖固定为 `0.5.2`，API 目标为 Godot 4.6。Android ARM64说明见 `docs/ANDROID.md`。

## License

MIT
