@tool
class_name QuestSkyController
extends Node3D

const DEFAULT_TIMELINE_PATH := "res://addons/quest_sky/assets/sky/sky_timeline.json"
const REQUIRED_FRAME_KEYS := [
    "minute",
    "texture",
    "ambient_color",
    "ambient_energy",
    "sun_color",
    "sun_energy",
    "moon_energy",
]

## True: follow the device clock. False: use manual_time_minutes.
@export var sync_system_clock := true
## 0..1439.999. Used when sync_system_clock is false.
@export_range(0.0, 1439.999, 0.1) var manual_time_minutes := 720.0
## One minute is the intended Quest setting.
@export_range(1.0, 600.0, 1.0) var update_interval_seconds := 60.0:
    set(value):
        update_interval_seconds = clampf(value, 1.0, 600.0)
        if is_instance_valid(update_timer):
            update_timer.wait_time = update_interval_seconds
## Artistic rotation around the world Y axis.
@export_range(-180.0, 180.0, 0.1) var sun_azimuth_offset_degrees := -25.0
## External timeline keeps art data separate from runtime code.
@export_file("*.json") var timeline_path := DEFAULT_TIMELINE_PATH:
    set(value):
        timeline_path = value
        if is_node_ready() and not Engine.is_editor_hint():
            _load_timeline()
            refresh_sky_state()

@onready var sky_mesh: MeshInstance3D = $SkyMesh
@onready var sun_light: DirectionalLight3D = $SunLight
@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var update_timer: Timer = $UpdateTimer

var _frames: Array[Dictionary] = []
var _material: ShaderMaterial
var _native: Object
var _loaded_frame_a := -1
var _loaded_frame_b := -1
var _texture_a: Texture2D
var _texture_b: Texture2D
var _failed_texture_paths: Dictionary = {}
var _prefetch_path := ""


func _ready() -> void:
    if Engine.is_editor_hint():
        return

    sky_mesh.custom_aabb = AABB(
        Vector3(-1.0e20, -1.0e20, -1.0e20),
        Vector3(2.0e20, 2.0e20, 2.0e20)
    )
    sky_mesh.ignore_occlusion_culling = true

    var source_material := sky_mesh.material_override as ShaderMaterial
    if source_material != null:
        _material = source_material.duplicate() as ShaderMaterial
        sky_mesh.material_override = _material

    var source_environment := world_environment.environment
    if source_environment != null:
        world_environment.environment = source_environment.duplicate(true) as Environment

    _set_static_shader_parameters()
    _load_timeline()
    _initialize_native_companion()

    update_timer.wait_time = update_interval_seconds
    if not update_timer.timeout.is_connected(refresh_sky_state):
        update_timer.timeout.connect(refresh_sky_state)
    update_timer.start()
    refresh_sky_state()


func _notification(what: int) -> void:
    if (
        what == NOTIFICATION_APPLICATION_FOCUS_IN
        and is_node_ready()
        and not Engine.is_editor_hint()
    ):
        refresh_sky_state()


func refresh_sky_state() -> void:
    if not is_instance_valid(_material) or _frames.is_empty():
        return

    var minutes := _get_current_minutes()
    var pair := _find_keyframe_pair(minutes)
    var frame_a := int(pair.x)
    var frame_b := int(pair.y)
    var blend := pair.z

    if not _ensure_textures(frame_a, frame_b):
        sky_mesh.visible = false
        return
    sky_mesh.visible = true

    _material.set_shader_parameter("sky_texture_a", _texture_a)
    _material.set_shader_parameter("sky_texture_b", _texture_b)
    _material.set_shader_parameter("blend_factor", blend)

    var sun_direction := _calculate_sun_direction(minutes)
    var moon_direction := -sun_direction
    _material.set_shader_parameter("sun_direction", sun_direction)
    _material.set_shader_parameter("moon_direction", moon_direction)

    var current_data: Dictionary = _frames[frame_a]
    var next_data: Dictionary = _frames[frame_b]
    _apply_art_parameters(current_data, next_data, blend, sun_direction)


func set_manual_time(hour: int, minute: int = 0) -> void:
    sync_system_clock = false
    manual_time_minutes = fposmod(float(hour * 60 + minute), 1440.0)
    refresh_sky_state()


func set_manual_minutes(minutes: float) -> void:
    sync_system_clock = false
    manual_time_minutes = fposmod(minutes, 1440.0)
    refresh_sky_state()


func _set_static_shader_parameters() -> void:
    if not is_instance_valid(_material):
        return
    _material.set_shader_parameter("sun_inner_cos", cos(0.0105))
    _material.set_shader_parameter("sun_outer_cos", cos(0.0142))
    _material.set_shader_parameter("moon_inner_cos", cos(0.0080))
    _material.set_shader_parameter("moon_outer_cos", cos(0.0108))


func _get_current_minutes() -> float:
    if not sync_system_clock:
        return fposmod(manual_time_minutes, 1440.0)
    var now := Time.get_datetime_dict_from_system()
    return float(now.hour * 60 + now.minute) + float(now.second) / 60.0


func _load_timeline() -> void:
    _frames.clear()
    _reset_texture_state()

    if timeline_path.is_empty():
        push_error("Quest Sky timeline path is empty.")
        return
    if not FileAccess.file_exists(timeline_path):
        push_error("Quest Sky timeline does not exist: %s" % timeline_path)
        return

    var parsed = JSON.parse_string(FileAccess.get_file_as_string(timeline_path))
    if typeof(parsed) != TYPE_DICTIONARY:
        push_error("Quest Sky timeline root must be a dictionary: %s" % timeline_path)
        return

    var parsed_dictionary: Dictionary = parsed
    if not parsed_dictionary.has("frames") or typeof(parsed_dictionary.frames) != TYPE_ARRAY:
        push_error("Quest Sky timeline must contain a frames array: %s" % timeline_path)
        return

    var raw_frames: Array = parsed_dictionary.frames
    var validated_frames: Array[Dictionary] = []
    for index in range(raw_frames.size()):
        var validated := _validate_frame(raw_frames[index], index)
        if not validated.is_empty():
            validated_frames.append(validated)

    validated_frames.sort_custom(
        func(a: Dictionary, b: Dictionary) -> bool:
            return float(a.minute) < float(b.minute)
    )

    for frame in validated_frames:
        if (
            not _frames.is_empty()
            and is_equal_approx(float(_frames.back().minute), float(frame.minute))
        ):
            push_error(
                "Quest Sky skipped duplicate timeline minute %.3f."
                % float(frame.minute)
            )
            continue
        _frames.append(frame)

    if _frames.is_empty():
        push_error("Quest Sky timeline has no valid frames: %s" % timeline_path)
    elif _frames.size() == 1:
        push_warning("Quest Sky timeline contains one frame; the sky will remain static.")


func _validate_frame(raw_frame: Variant, index: int) -> Dictionary:
    if typeof(raw_frame) != TYPE_DICTIONARY:
        push_error("Quest Sky skipped frame %d: expected a dictionary." % index)
        return {}

    var frame: Dictionary = raw_frame
    for key in REQUIRED_FRAME_KEYS:
        if not frame.has(key):
            push_error("Quest Sky skipped frame %d: missing '%s'." % [index, key])
            return {}

    if not _is_number(frame.minute):
        push_error("Quest Sky skipped frame %d: minute must be numeric." % index)
        return {}
    var minute := float(frame.minute)
    if minute < 0.0 or minute >= 1440.0:
        push_error(
            "Quest Sky skipped frame %d: minute %.3f is outside 0..1439.999."
            % [index, minute]
        )
        return {}

    if typeof(frame.texture) != TYPE_STRING or str(frame.texture).is_empty():
        push_error("Quest Sky skipped frame %d: texture path is invalid." % index)
        return {}
    var texture_path := str(frame.texture)
    if not ResourceLoader.exists(texture_path, "Texture2D"):
        push_error(
            "Quest Sky skipped frame %d: texture does not exist: %s"
            % [index, texture_path]
        )
        return {}

    if not _is_color_array(frame.ambient_color):
        push_error("Quest Sky skipped frame %d: ambient_color must contain 3 numbers." % index)
        return {}
    if not _is_color_array(frame.sun_color):
        push_error("Quest Sky skipped frame %d: sun_color must contain 3 numbers." % index)
        return {}

    for energy_key in ["ambient_energy", "sun_energy", "moon_energy"]:
        if not _is_number(frame[energy_key]):
            push_error(
                "Quest Sky skipped frame %d: %s must be numeric."
                % [index, energy_key]
            )
            return {}

    return frame.duplicate(true)


func _is_number(value: Variant) -> bool:
    var value_type := typeof(value)
    return value_type == TYPE_INT or value_type == TYPE_FLOAT


func _is_color_array(value: Variant) -> bool:
    if typeof(value) != TYPE_ARRAY:
        return false
    var values: Array = value
    return (
        values.size() >= 3
        and _is_number(values[0])
        and _is_number(values[1])
        and _is_number(values[2])
    )


func _initialize_native_companion() -> void:
    if ClassDB.class_exists("QuestSkyNative"):
        _native = ClassDB.instantiate("QuestSkyNative")
        if _native is Node:
            add_child(_native)
            _native.azimuth_offset_degrees = sun_azimuth_offset_degrees


func _reset_texture_state() -> void:
    _loaded_frame_a = -1
    _loaded_frame_b = -1
    _texture_a = null
    _texture_b = null
    _failed_texture_paths.clear()
    _prefetch_path = ""


func _ensure_textures(frame_a: int, frame_b: int) -> bool:
    if frame_a == _loaded_frame_a and frame_b == _loaded_frame_b:
        return _texture_a != null and _texture_b != null

    var path_a := str(_frames[frame_a].texture)
    var path_b := str(_frames[frame_b].texture)
    var next_texture_a: Texture2D
    var next_texture_b: Texture2D

    if frame_a == _loaded_frame_a:
        next_texture_a = _texture_a
    elif frame_a == _loaded_frame_b:
        next_texture_a = _texture_b
    else:
        next_texture_a = _load_texture(path_a)

    if frame_b == frame_a:
        next_texture_b = next_texture_a
    elif frame_b == _loaded_frame_a:
        next_texture_b = _texture_a
    elif frame_b == _loaded_frame_b:
        next_texture_b = _texture_b
    else:
        next_texture_b = _load_texture(path_b)

    if next_texture_a == null and next_texture_b == null:
        if path_a != _prefetch_path and path_b != _prefetch_path:
            _loaded_frame_a = frame_a
            _loaded_frame_b = frame_b
        _texture_a = null
        _texture_b = null
        return false

    var actual_frame_a := frame_a
    var actual_frame_b := frame_b
    if next_texture_a == null:
        next_texture_a = next_texture_b
        if path_a == _prefetch_path:
            actual_frame_a = frame_b
    if next_texture_b == null:
        next_texture_b = next_texture_a
        if path_b == _prefetch_path:
            actual_frame_b = frame_a

    _loaded_frame_a = actual_frame_a
    _loaded_frame_b = actual_frame_b
    _texture_a = next_texture_a
    _texture_b = next_texture_b
    if actual_frame_a == frame_a and actual_frame_b == frame_b:
        _request_prefetch((frame_b + 1) % _frames.size())
    return true


func _load_texture(path: String) -> Texture2D:
    if _failed_texture_paths.has(path):
        return null

    var threaded_texture := _take_prefetched_texture(path)
    if threaded_texture != null:
        return threaded_texture
    if path == _prefetch_path or _failed_texture_paths.has(path):
        return null

    var texture := load(path) as Texture2D
    if texture == null:
        _remember_texture_failure(path, "synchronous load failed")
    return texture


func _take_prefetched_texture(path: String) -> Texture2D:
    if path != _prefetch_path:
        return null

    var status := ResourceLoader.load_threaded_get_status(path)
    if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
        return null
    if status == ResourceLoader.THREAD_LOAD_FAILED:
        _prefetch_path = ""
        _remember_texture_failure(path, "threaded load failed")
        return null
    if status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
        _prefetch_path = ""
        _remember_texture_failure(path, "threaded resource is invalid")
        return null

    var texture := ResourceLoader.load_threaded_get(path) as Texture2D
    _prefetch_path = ""
    if texture == null:
        _remember_texture_failure(path, "threaded load returned no texture")
    return texture


func _request_prefetch(frame_index: int) -> void:
    if _frames.size() < 2:
        return

    var path := str(_frames[frame_index].texture)
    if (
        path.is_empty()
        or _failed_texture_paths.has(path)
        or path == _prefetch_path
        or path == str(_frames[_loaded_frame_a].texture)
        or path == str(_frames[_loaded_frame_b].texture)
    ):
        return

    # A manual time jump can make an older request irrelevant. The old request
    # may finish in the shared cache; only the currently useful path is tracked.
    _prefetch_path = ""
    var error := ResourceLoader.load_threaded_request(path, "Texture2D")
    if error == OK:
        _prefetch_path = path
    else:
        _remember_texture_failure(path, "threaded request failed with code %d" % error)


func _remember_texture_failure(path: String, reason: String) -> void:
    if _failed_texture_paths.has(path):
        return
    _failed_texture_paths[path] = true
    push_error("Quest Sky texture failure (%s): %s" % [reason, path])


func _find_keyframe_pair(minutes: float) -> Vector3:
    if _frames.size() == 1:
        return Vector3.ZERO

    var current := fposmod(minutes, 1440.0)
    for index in range(_frames.size()):
        var next_index := (index + 1) % _frames.size()
        var start := float(_frames[index].minute)
        var end := float(_frames[next_index].minute)
        if next_index == 0:
            end += 1440.0

        var comparable := current
        if next_index == 0 and comparable < start:
            comparable += 1440.0
        if comparable >= start and comparable < end:
            return Vector3(index, next_index, inverse_lerp(start, end, comparable))

    push_error("Quest Sky could not resolve timeline time %.3f." % current)
    return Vector3.ZERO


func _calculate_sun_direction(minutes: float) -> Vector3:
    if _native != null:
        _native.azimuth_offset_degrees = sun_azimuth_offset_degrees
        return _native.calculate_sun_direction(minutes)

    var phase := TAU * (minutes / 1440.0 - 0.25)
    var base_direction := Vector3(cos(phase), sin(phase), 0.18).normalized()
    return base_direction.rotated(
        Vector3.UP,
        deg_to_rad(sun_azimuth_offset_degrees)
    )


func _apply_art_parameters(
    a: Dictionary,
    b: Dictionary,
    blend: float,
    sun_direction: Vector3
) -> void:
    var ambient_color := _dict_color(a, "ambient_color").lerp(
        _dict_color(b, "ambient_color"),
        blend
    )
    var ambient_energy := lerp(
        float(a.ambient_energy),
        float(b.ambient_energy),
        blend
    )
    var sun_color := _dict_color(a, "sun_color").lerp(
        _dict_color(b, "sun_color"),
        blend
    )
    var sun_energy := lerp(float(a.sun_energy), float(b.sun_energy), blend)
    var moon_energy := lerp(float(a.moon_energy), float(b.moon_energy), blend)

    _material.set_shader_parameter(
        "sun_color",
        Vector3(sun_color.r, sun_color.g, sun_color.b)
    )
    _material.set_shader_parameter("sun_intensity", sun_energy * 1.7)
    _material.set_shader_parameter("moon_intensity", moon_energy)

    sun_light.visible = sun_energy > 0.001
    sun_light.light_energy = sun_energy
    sun_light.light_color = sun_color
    var target_direction := -sun_direction
    var up := Vector3.UP if abs(target_direction.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
    sun_light.basis = Basis.looking_at(target_direction, up)

    var environment := world_environment.environment
    if environment != null:
        environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
        environment.ambient_light_color = ambient_color
        environment.ambient_light_energy = ambient_energy


func _dict_color(data: Dictionary, key: String) -> Color:
    var values: Array = data[key]
    return Color(float(values[0]), float(values[1]), float(values[2]), 1.0)
