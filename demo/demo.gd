extends Node3D

@onready var quest_sky: QuestSkyController = $QuestSky
@onready var time_label: Label = $UI/Panel/VBox/TimeLabel
@onready var time_slider: HSlider = $UI/Panel/VBox/TimeSlider

func _ready() -> void:
    time_slider.value_changed.connect(_on_time_changed)
    _on_time_changed(time_slider.value)

func _on_time_changed(value: float) -> void:
    var minutes := int(value)
    quest_sky.sync_system_clock = false
    quest_sky.manual_time_minutes = minutes
    quest_sky.refresh_sky_state()
    time_label.text = "%02d:%02d" % [minutes / 60, minutes % 60]
