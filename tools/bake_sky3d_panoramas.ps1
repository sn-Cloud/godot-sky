param(
    [string]$Sky3DProject = 'F:\3rdLib\Sky3D',
    [string]$OutputDir = 'F:\3rdLib\godot-sky\addons\quest_sky\assets\sky',
    [string]$WorkingDir = 'F:\3rdLib\godot-sky\.sky3d-cubemaps',
    [int]$FaceSize = 2048,
    [int]$Width = 7096,
    [string]$Minutes = '0,300,360,480,720,1020,1140,1260',
    [string]$PythonExecutable = 'python'
)

$ErrorActionPreference = 'Stop'
$captureScript = Join-Path $PSScriptRoot 'capture_sky3d_cubemaps.gd'
$convertScript = Join-Path $PSScriptRoot 'cubemap_to_equirect.py'

& godot --path $Sky3DProject --script $captureScript -- --output-dir $WorkingDir --face-size $FaceSize --minutes $Minutes
if ($LASTEXITCODE -ne 0) {
    throw "Sky3D cubemap capture failed with exit code $LASTEXITCODE"
}

& $PythonExecutable $convertScript --input-dir $WorkingDir --output-dir $OutputDir --width $Width --minutes $Minutes
if ($LASTEXITCODE -ne 0) {
    throw "Cubemap conversion failed with exit code $LASTEXITCODE"
}
