extends Node3D

# 桌面预览显式关闭系统时间同步，让滑杆成为唯一时间来源。
@onready var vrsky: VrSkyController = $VRSky
@onready var time_label: Label = $UI/Panel/VBox/TimeLabel
@onready var time_slider: HSlider = $UI/Panel/VBox/TimeSlider

func _ready() -> void:
    # 先连接信号再主动应用初值，确保标签、控制器和 Inspector 初始值一致。
    time_slider.value_changed.connect(_on_time_changed)
    _on_time_changed(time_slider.value)

func _on_time_changed(value: float) -> void:
    # 控制器内部仍会执行全天环绕；这里取整只是让演示 UI 精确显示到分钟。
    var minutes := int(value)
    vrsky.sync_system_clock = false
    vrsky.manual_time_minutes = minutes
    vrsky.refresh_sky_state()
    time_label.text = "%02d:%02d" % [minutes / 60, minutes % 60]
