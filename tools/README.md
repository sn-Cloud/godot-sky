# Sky3D 全景烘焙工具

高质量离线流程不再使用 `sky_bake_panorama()`。它先通过六个 90° 相机方向直接渲染 2048×2048 立方体面，再用双线性投影转换为 VRSky 使用的 7096×3548、2:1 经纬度 PNG。

离线 Shader 会直接略过太阳和月亮圆盘的计算，并关闭两者的局部 Mie 光晕；太阳和月亮方向仍参与大气散射、星空昼夜变化和云层照明。离线 Shader 还将积云步进从 10 提升到 32，并在原有 4 层 FBM 上增加 2 层高频细节，再按时段进行高光压缩；Sky3D 源文件不会被修改。

在 PowerShell 中运行：

```powershell
$python = 'C:\path\to\python.exe'
powershell -ExecutionPolicy Bypass -File F:\3rdLib\godot-sky\tools\bake_sky3d_panoramas.ps1 -PythonExecutable $python
```

Python 需要安装 `numpy` 和 `Pillow`。可以通过 `-Minutes '720' -FaceSize 1024 -Width 2048` 先试渲染单帧。

该命令必须使用 GPU 渲染，不能添加 `--headless`。转换脚本会在指定帧全部生成成功后再替换正式贴图，避免中途失败留下半套资源。

夜景包含 Sky3D 使用的银河素材，因此发布项目必须保留 `addons/vrsky/assets/sky/SKY3D_ATTRIBUTION.md` 中的署名。
