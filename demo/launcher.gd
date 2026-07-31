extends Node

func _ready() -> void:
    if OS.has_feature("android"):
        var xr_interface := XRServer.find_interface("OpenXR")
        if xr_interface != null and (xr_interface.is_initialized() or xr_interface.initialize()):
            get_viewport().use_xr = true
            get_tree().change_scene_to_file("res://demo/xr_demo.tscn")
            return
        push_error("OpenXR could not initialize; loading flat fallback scene.")
    get_tree().change_scene_to_file("res://demo/demo.tscn")
