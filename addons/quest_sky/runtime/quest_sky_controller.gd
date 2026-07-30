@tool
class_name QuestSkyController
extends Node3D

## True: follow the device clock. False: use manual_time_minutes.
@export var sync_system_clock := true
## 0..1439.999. Used when sync_system_clock is false.
@export_range(0.0, 1439.999, 0.1) var manual_time_minutes := 720.0
## One minute is the intended Quest setting.
@export_range(1.0, 600.0, 1.0) var update_interval_seconds := 60.0
## Artistic rotation around the world Y axis.
@export_range(-180.0, 180.0, 0.1) var sun_azimuth_offset_degrees := -25.0
## External timeline keeps art data separate from runtime code.
@export_file("*.json") var timeline_path := "res://addons/quest_sky/assets/sky/sky_timeline.json"

@onready var sky_mesh: MeshInstance3D = $SkyMesh
@onready var sun_light: DirectionalLight3D = $SunLight
@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var update_timer: Timer = $UpdateTimer

var _frames: Array = []
var _material: ShaderMaterial
var _native: Object
var _loaded_frame_a := -1
var _loaded_frame_b := -1
var _texture_a: Texture2D
var _texture_b: Texture2D

func _ready() -> void:
    sky_mesh.custom_aabb = AABB(Vector3(-1.0e20, -1.0e20, -1.0e20), Vector3(2.0e20, 2.0e20, 2.0e20))
    sky_mesh.ignore_occlusion_culling = true
    _material = sky_mesh.material_override as ShaderMaterial
    _load_timeline()
    _initialize_native_companion()
    update_timer.wait_time = update_interval_seconds
    if not update_timer.timeout.is_connected(refresh_sky_state):
        update_timer.timeout.connect(refresh_sky_state)
    update_timer.start()
    refresh_sky_state()

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_IN and is_inside_tree():
        refresh_sky_state()

func refresh_sky_state() -> void:
    if not is_instance_valid(_material) or _frames.size() < 2:
        return

    var minutes := _get_current_minutes()
    var pair := _find_keyframe_pair(minutes)
    var frame_a := int(pair.x)
    var frame_b := int(pair.y)
    var blend := pair.z

    _ensure_textures(frame_a, frame_b)
    if _texture_a == null or _texture_b == null:
        return

    _material.set_shader_parameter("sky_texture_a", _texture_a)
    _material.set_shader_parameter("sky_texture_b", _texture_b)
    _material.set_shader_parameter("blend_factor", blend)

    var sun_direction := _calculate_sun_direction(minutes)
    var moon_direction := -sun_direction
    _material.set_shader_parameter("sun_direction", sun_direction)
    _material.set_shader_parameter("moon_direction", moon_direction)
    _material.set_shader_parameter("sun_inner_cos", cos(0.0105))
    _material.set_shader_parameter("sun_outer_cos", cos(0.0142))
    _material.set_shader_parameter("moon_inner_cos", cos(0.0080))
    _material.set_shader_parameter("moon_outer_cos", cos(0.0108))

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

func _get_current_minutes() -> float:
    if not sync_system_clock:
        return fposmod(manual_time_minutes, 1440.0)
    var now := Time.get_datetime_dict_from_system()
    return float(now.hour * 60 + now.minute) + float(now.second) / 60.0

func _load_timeline() -> void:
    _frames.clear()
    if not FileAccess.file_exists(timeline_path):
        push_error("Quest Sky timeline does not exist: %s" % timeline_path)
        return
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(timeline_path))
    if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("frames"):
        push_error("Quest Sky timeline is invalid: %s" % timeline_path)
        return
    _frames = parsed.frames
    _frames.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.minute) < int(b.minute))

func _initialize_native_companion() -> void:
    if ClassDB.class_exists("QuestSkyNative"):
        _native = ClassDB.instantiate("QuestSkyNative")
        if _native is Node:
            add_child(_native)
            _native.azimuth_offset_degrees = sun_azimuth_offset_degrees

func _ensure_textures(frame_a: int, frame_b: int) -> void:
    if frame_a == _loaded_frame_a and frame_b == _loaded_frame_b:
        return
    _texture_a = load(str(_frames[frame_a].texture)) as Texture2D
    _texture_b = load(str(_frames[frame_b].texture)) as Texture2D
    if _texture_a == null or _texture_b == null:
        push_error("Quest Sky failed to load keyframe textures %d and %d" % [frame_a, frame_b])
        return
    _loaded_frame_a = frame_a
    _loaded_frame_b = frame_b

func _find_keyframe_pair(minutes: float) -> Vector3:
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
    return Vector3.ZERO

func _calculate_sun_direction(minutes: float) -> Vector3:
    if _native != null:
        _native.azimuth_offset_degrees = sun_azimuth_offset_degrees
        return _native.calculate_sun_direction(minutes)
    var phase := TAU * (minutes / 1440.0 - 0.25)
    var base_direction := Vector3(cos(phase), sin(phase), 0.18).normalized()
    return base_direction.rotated(Vector3.UP, deg_to_rad(sun_azimuth_offset_degrees))

func _apply_art_parameters(a: Dictionary, b: Dictionary, blend: float, sun_direction: Vector3) -> void:
    var ambient_color := _dict_color(a, "ambient_color").lerp(_dict_color(b, "ambient_color"), blend)
    var ambient_energy := lerp(float(a.ambient_energy), float(b.ambient_energy), blend)
    var sun_color := _dict_color(a, "sun_color").lerp(_dict_color(b, "sun_color"), blend)
    var sun_energy := lerp(float(a.sun_energy), float(b.sun_energy), blend)
    var moon_energy := lerp(float(a.moon_energy), float(b.moon_energy), blend)

    _material.set_shader_parameter("sun_color", Vector3(sun_color.r, sun_color.g, sun_color.b))
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
