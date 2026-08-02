param(
    [string]$Sky3DProject = 'F:\3rdLib\Sky3D',
    [string]$OutputDir = 'F:\3rdLib\godot-sky\addons\vrsky\assets\sky',
    [string]$WorkingDir = 'F:\3rdLib\godot-sky\.sky3d-cubemaps',
    [int]$FaceSize = 2048,
    [int]$Width = 7096,
    [string]$Minutes = '0,300,360,480,720,1020,1140,1260',
    [string]$PythonExecutable = 'python'
)

# 任一外部命令或文件操作失败都立即停止，禁止继续覆盖剩余正式关键帧。
$ErrorActionPreference = 'Stop'

# 捕获和投影保持为两个独立阶段：前者只能在 Godot/Sky3D 环境中运行，
# 后者由 Python/Numpy 批量处理大图，便于分别诊断渲染问题和投影问题。
$captureScript = Join-Path $PSScriptRoot 'capture_sky3d_cubemaps.gd'
$convertScript = Join-Path $PSScriptRoot 'cubemap_to_equirect.py'

& godot --path $Sky3DProject --script $captureScript -- --output-dir $WorkingDir --face-size $FaceSize --minutes $Minutes
if ($LASTEXITCODE -ne 0) {
    throw "Sky3D cubemap capture failed with exit code $LASTEXITCODE"
}

# 转换器内部先写暂存文件并原子替换；这里只在全部捕获成功后才进入转换阶段。
& $PythonExecutable $convertScript --input-dir $WorkingDir --output-dir $OutputDir --width $Width --minutes $Minutes
if ($LASTEXITCODE -ne 0) {
    throw "Cubemap conversion failed with exit code $LASTEXITCODE"
}
