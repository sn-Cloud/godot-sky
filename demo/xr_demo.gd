extends Node3D

@onready var sky: QuestSkyController = $QuestSky

func _ready() -> void:
    sky.sync_system_clock = true
    sky.refresh_sky_state()
    Performance.add_custom_monitor("quest_sky/update_interval_seconds", func() -> float: return sky.update_interval_seconds)

func _exit_tree() -> void:
    Performance.remove_custom_monitor("quest_sky/update_interval_seconds")
