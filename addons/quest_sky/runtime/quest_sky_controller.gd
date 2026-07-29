@tool
class_name QuestSkyController
extends Node3D

## True: follow the device clock. False: use manual_time_minutes.
@export var sync_system_clock := true
## 0..1439.999. Used when sync_system_clock is false.
@export_range(0.0, 1439.999, 0.1) var manual_time_minutes := 720.0
## Runtime state refresh interval. One minute is the intended Quest setting.
@export_range(1.0, 600.0, 1.0) var update_interval_seconds := 60.0
## Artistic rotation around the world Y axis.
@export_range(-180.0, 180.0, 0.1) var sun_azimuth_offset_degrees := -25.0
## Maximum sun DirectionalLight3D energy.
@export_range(0.0, 8.0, 0.05) var maximum_sun_energy := 1.25
## Ambient energy at midnight and noon.
@export_range(0.0, 2.0, 0.01) var night_ambient_energy := 0.12
@export_range(0.0, 2.0, 0.01) var day_ambient_energy := 0.72

const KEYFRAME_MINUTES := PackedInt32Array([0, 360, 720, 1080])
const SKY_TEXTURE_PATHS := PackedStringArray([
    "res://addons/quest_sky/assets/sky/sky_00.svg",
    "res://addons/quest_sky/assets/sky/sky_06.svg",
    "res://addons/quest_sky/assets/sky/sky_12.svg",
    "res://addons/quest_sky/assets/sky/sky_18.svg"
])

@onready var sky_mesh: MeshInstance3D = $SkyMesh
@onready var sun_light: DirectionalLight3D = $SunLight
@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var update_timer: Timer = $UpdateTimer

var _textures: Array[Texture2D] = []
var _material: ShaderMaterial

func _ready() -> void:
    sky_mesh.custom_aabb = AABB(Vector3(-1.0e20, -1.0e20, -1.0e20), Vector3(2.0e20, 2.0e20, 2.0e20))
    sky_mesh.ignore_occlusion_culling = true
    _load_textures()
    _material = sky_mesh.material_override as ShaderMaterial
    update_timer.wait_time = update_interval_seconds
    update_timer.timeout.connect(refresh_sky_state)
    update_timer.start()
    refresh_sky_state()

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_IN and is_inside_tree():
        refresh_sky_state()

func refresh_sky_state() -> void:
    if not is_instance_valid(_material) or _textures.size() != SKY_TEXTURE_PATHS.size():
        return

    var minutes := _get_current_minutes()
    var pair := _find_keyframe_pair(minutes)
    var frame_a := int(pair.x)
    var frame_b := int(pair.y)
    var blend := pair.z

    _material.set_shader_parameter("sky_texture_a", _textures[frame_a])
    _material.set_shader_parameter("sky_texture_b", _textures[frame_b])
    _material.set_shader_parameter("blend_factor", blend)

    var sun_direction := _calculate_sun_direction(minutes)
    var moon_direction := -sun_direction
    _material.set_shader_parameter("sun_direction", sun_direction)
    _material.set_shader_parameter("moon_direction", moon_direction)

    _update_sun_light(sun_direction)
    _update_environment(sun_direction)

func set_manual_time(hour: int, minute: int = 0) -> void:
    sync_system_clock = false
    manual_time_minutes = fposmod(float(hour * 60 + minute), 1440.0)
    refresh_sky_state()

func _get_current_minutes() -> float:
    if not sync_system_clock:
        return fposmod(manual_time_minutes, 1440.0)

    var now := Time.get_datetime_dict_from_system()
    return float(now.hour * 60 + now.minute) + float(now.second) / 60.0

func _load_textures() -> void:
    _textures.clear()
    for path in SKY_TEXTURE_PATHS:
        var texture := load(path) as Texture2D
        if texture == null:
            push_error("Quest Sky failed to load: %s" % path)
            return
        _textures.append(texture)

func _find_keyframe_pair(minutes: float) -> Vector3:
    var current := fposmod(minutes, 1440.0)
    for index in range(KEYFRAME_MINUTES.size()):
        var next_index := (index + 1) % KEYFRAME_MINUTES.size()
        var start := float(KEYFRAME_MINUTES[index])
        var end := float(KEYFRAME_MINUTES[next_index])
        if next_index == 0:
            end += 1440.0

        var comparable := current
        if next_index == 0 and comparable < start:
            comparable += 1440.0

        if comparable >= start and comparable < end:
            var blend := inverse_lerp(start, end, comparable)
            return Vector3(index, next_index, blend)

    return Vector3.ZERO

func _calculate_sun_direction(minutes: float) -> Vector3:
    # Artistic 24-hour path: sunrise at 06:00, zenith at 12:00,
    # sunset at 18:00, nadir at 00:00.
    var phase := TAU * (minutes / 1440.0 - 0.25)
    var base_direction := Vector3(cos(phase), sin(phase), 0.18).normalized()
    return base_direction.rotated(Vector3.UP, deg_to_rad(sun_azimuth_offset_degrees))

func _update_sun_light(sun_direction: Vector3) -> void:
    var daylight := smoothstep(-0.04, 0.12, sun_direction.y)
    sun_light.visible = daylight > 0.001
    sun_light.light_energy = maximum_sun_energy * daylight
    sun_light.light_color = Color(1.0, 0.58, 0.33).lerp(Color(1.0, 0.96, 0.90), smoothstep(0.0, 0.65, sun_direction.y))

    var target_direction := -sun_direction
    var up := Vector3.UP if abs(target_direction.dot(Vector3.UP)) < 0.98 else Vector3.FORWARD
    sun_light.basis = Basis.looking_at(target_direction, up)

func _update_environment(sun_direction: Vector3) -> void:
    var environment := world_environment.environment
    if environment == null:
        return

    var daylight := smoothstep(-0.12, 0.30, sun_direction.y)
    var horizon := 1.0 - smoothstep(0.0, 0.45, abs(sun_direction.y))
    var night_color := Color(0.035, 0.045, 0.075)
    var day_color := Color(0.52, 0.61, 0.72)
    var sunset_color := Color(0.72, 0.34, 0.20)

    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = night_color.lerp(day_color, daylight).lerp(
        sunset_color,
        horizon * (1.0 - abs(daylight - 0.5) * 2.0) * 0.35
    )
    environment.ambient_light_energy = lerp(night_ambient_energy, day_ambient_energy, daylight)
