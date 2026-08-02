extends Node3D

@onready var sky: VrSkyController = $VRSky

func _ready() -> void:
    # XR 演示跟随设备真实时间。自定义监视器只暴露低频刷新间隔，
    # 不改变 VRSky 的更新驱动，也不会引入逐帧天空计算。
    sky.sync_system_clock = true
    sky.refresh_sky_state()
    Performance.add_custom_monitor("vrsky/update_interval_seconds", func() -> float: return sky.update_interval_seconds)

func _exit_tree() -> void:
    # 场景退出时移除全局监视器，避免再次进入场景时发生同名注册冲突。
    Performance.remove_custom_monitor("vrsky/update_interval_seconds")
