@tool
extends EditorPlugin

var _export_plugin: QuestSkyExportPlugin

func _enter_tree() -> void:
    _export_plugin = QuestSkyExportPlugin.new()
    add_export_plugin(_export_plugin)

func _exit_tree() -> void:
    if _export_plugin != null:
        remove_export_plugin(_export_plugin)
        _export_plugin = null

class QuestSkyExportPlugin:
    extends EditorExportPlugin

    func _get_name() -> String:
        return "QuestSkyNativeExport"

    func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
        if features.has("android"):
            add_shared_object(
                "res://godot/bin/android/arm64-v8a/libquest_sky_native.so",
                PackedStringArray(["arm64"]),
                ""
            )
