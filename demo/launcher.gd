extends Node

# 启动场景只负责选择 XR 或桌面预览，不参与 VRSky 的天空状态管理。
# Android 上优先初始化 OpenXR；初始化失败时进入平面场景，便于从日志和画面继续诊断。
func _ready() -> void:
    if OS.has_feature("android"):
        var xr_interface := XRServer.find_interface("OpenXR")
        if xr_interface != null and (xr_interface.is_initialized() or xr_interface.initialize()):
            get_viewport().use_xr = true
            get_tree().change_scene_to_file("res://demo/xr_demo.tscn")
            return
        push_error("OpenXR could not initialize; loading flat fallback scene.")
    get_tree().change_scene_to_file("res://demo/demo.tscn")
