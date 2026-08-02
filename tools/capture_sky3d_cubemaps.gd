extends SceneTree

## Directly renders Sky3D into six high-resolution camera faces per keyframe.
## This deliberately avoids RenderingServer.sky_bake_panorama(), whose detail
## is capped by Sky.radiance_size.

const DEFAULT_OUTPUT_DIR: String = "F:/3rdLib/godot-sky/.sky3d-cubemaps"
const DEFAULT_FACE_SIZE: int = 2048
const SKY3D_DEMO_SCENE: String = "res://demo/Sky3DDemo.tscn"
const SOURCE_SHADER_PATH: String = "res://addons/sky_3d/shaders/SkyMaterial.gdshader"
const CAPTURE_SHADER_PATH: String = "user://quest_sky_direct_capture.gdshader"
const DEFAULT_FRAME_MINUTES: Array[int] = [0, 300, 360, 480, 720, 1020, 1140, 1260]
const FACE_SET: Array[Dictionary] = [
	{"name": "px", "direction": Vector3.RIGHT, "up": Vector3.UP},
	{"name": "nx", "direction": Vector3.LEFT, "up": Vector3.UP},
	{"name": "py", "direction": Vector3.UP, "up": Vector3.FORWARD},
	{"name": "ny", "direction": Vector3.DOWN, "up": Vector3.BACK},
	{"name": "pz", "direction": Vector3.BACK, "up": Vector3.UP},
	{"name": "nz", "direction": Vector3.FORWARD, "up": Vector3.UP},
]

var output_dir: String = DEFAULT_OUTPUT_DIR
var face_size: int = DEFAULT_FACE_SIZE
var frame_minutes: Array[int] = DEFAULT_FRAME_MINUTES.duplicate()


func _initialize() -> void:
	if not _parse_arguments():
		return
	call_deferred("_capture_all")


func _parse_arguments() -> bool:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var index: int = 0
	while index < args.size():
		match args[index]:
			"--output-dir":
				index += 1
				if index >= args.size():
					return _fail("--output-dir requires a path")
				output_dir = args[index].replace("\\", "/").trim_suffix("/")
			"--face-size":
				index += 1
				if index >= args.size() or not args[index].is_valid_int():
					return _fail("--face-size requires an integer")
				face_size = args[index].to_int()
			"--minutes":
				index += 1
				if index >= args.size():
					return _fail("--minutes requires comma-separated minute values")
				frame_minutes.clear()
				for value: String in args[index].split(",", false):
					if not value.is_valid_int():
						return _fail("invalid minute value: %s" % value)
					frame_minutes.append(value.to_int())
			_:
				return _fail("unknown argument: %s" % args[index])
		index += 1

	if face_size < 512 or face_size > 4096 or face_size % 2 != 0:
		return _fail("--face-size must be an even integer from 512 to 4096")
	if frame_minutes.is_empty():
		return _fail("at least one minute value is required")
	for minute: int in frame_minutes:
		if minute < 0 or minute >= 1440:
			return _fail("minute values must be in the range 0..1439")
	return true


func _capture_all() -> void:
	var mkdir_error: Error = DirAccess.make_dir_recursive_absolute(output_dir)
	if mkdir_error != OK:
		_fail("cannot create output directory %s: %s" % [output_dir, error_string(mkdir_error)])
		return

	var packed_scene: PackedScene = load(SKY3D_DEMO_SCENE) as PackedScene
	if packed_scene == null:
		_fail("cannot load %s" % SKY3D_DEMO_SCENE)
		return

	# Extract only the Sky3D environment hierarchy from the demo. Geometry and
	# demo cameras must never appear in the offline cubemap.
	var demo_scene: Node = packed_scene.instantiate()
	var sky3d: Variant = demo_scene.get_node_or_null("Sky3D")
	if sky3d == null:
		_fail("Sky3D demo does not contain a Sky3D node")
		return
	demo_scene.remove_child(sky3d)
	demo_scene.free()

	var viewport: SubViewport = SubViewport.new()
	viewport.name = "SkyCaptureViewport"
	viewport.size = Vector2i(face_size, face_size)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	root.add_child(viewport)
	viewport.add_child(sky3d)

	var camera: Camera3D = Camera3D.new()
	camera.name = "SkyCaptureCamera"
	camera.fov = 90.0
	camera.near = 0.05
	camera.far = 10.0
	camera.current = true
	viewport.add_child(camera)

	await process_frame
	await process_frame

	var sky_dome: Variant = sky3d.get_node_or_null("SkyDome")
	var time_of_day: Variant = sky3d.get_node_or_null("TimeOfDay")
	if sky_dome == null or time_of_day == null:
		_fail("Sky3D hierarchy is missing SkyDome or TimeOfDay")
		return

	sky3d.game_time_enabled = false
	sky3d.fog_enabled = false
	time_of_day.pause()
	sky_dome.set_process(false)
	sky_dome.set_physics_process(false)
	sky3d.camera_attributes = null

	var environment: Environment = sky3d.environment
	var material: ShaderMaterial = environment.sky.sky_material as ShaderMaterial
	if material == null or not _install_high_quality_capture_shader(material):
		return

	# Celestial bodies remain dynamic in Quest Sky and must not be baked.
	sky_dome.sun_disk_intensity = 0.0
	sky_dome.moon_size = 0.0
	sky_dome.atm_sun_mie_intensity = 0.0
	sky_dome.atm_moon_mie_intensity = 0.0
	material.set_shader_parameter("show_azimuthal_grid", false)
	material.set_shader_parameter("show_equatorial_grid", false)

	for minute: int in frame_minutes:
		time_of_day.set_time(minute / 60, minute % 60, 0)
		_apply_capture_look(material, minute)
		await process_frame
		await process_frame
		var frame_dir: String = output_dir.path_join("%04d" % minute)
		var frame_error: Error = DirAccess.make_dir_recursive_absolute(frame_dir)
		if frame_error != OK:
			_fail("cannot create frame directory %s: %s" % [frame_dir, error_string(frame_error)])
			return

		for face: Dictionary in FACE_SET:
			camera.look_at(face["direction"], face["up"])
			await process_frame
			await process_frame
			RenderingServer.force_sync()
			var image: Image = viewport.get_texture().get_image()
			if image == null or image.is_empty():
				_fail("empty capture for minute %d face %s" % [minute, face["name"]])
				return
			if image.get_format() != Image.FORMAT_RGB8:
				image.convert(Image.FORMAT_RGB8)
			var face_path: String = frame_dir.path_join("%s.png" % face["name"])
			var save_error: Error = image.save_png(face_path)
			if save_error != OK:
				_fail("cannot save %s: %s" % [face_path, error_string(save_error)])
				return
			print("Captured minute %04d face %s (%dx%d)" % [minute, face["name"], face_size, face_size])

	print("Captured %d direct-rendered Sky3D cubemap keyframes." % frame_minutes.size())
	quit(0)


func _install_high_quality_capture_shader(material: ShaderMaterial) -> bool:
	var source: String = FileAccess.get_file_as_string(SOURCE_SHADER_PATH)
	if source.is_empty():
		return _fail("cannot read %s" % SOURCE_SHADER_PATH)
	if not source.contains("const int CUMULUS_STEP = 10;"):
		return _fail("Sky3D cumulus shader layout changed")

	source = source.replace(
		"#include \"Common.gdshaderinc\"",
		"#include \"res://addons/sky_3d/shaders/Common.gdshaderinc\""
	)
	source = source.replace("const int CUMULUS_STEP = 10;", "const int CUMULUS_STEP = 32;")
	source = source.replace(
		"float march_step = float(CUMULUS_STEP) * cumulus_thickness;",
		"float march_step = (100.0 / float(CUMULUS_STEP)) * cumulus_thickness;"
	)
	var original_fbm_tail: String = """p *= l;
	ret += 0.06255931 * sample_cumulus_noise(p);
	return ret;"""
	var capture_fbm_tail: String = """p *= l;
	ret += 0.06255931 * sample_cumulus_noise(p);
	p *= l;
	ret += 0.03127966 * sample_cumulus_noise(p);
	p *= l;
	ret += 0.01563983 * sample_cumulus_noise(p);
	return ret / 1.00810085;"""
	if not source.contains(original_fbm_tail):
		return _fail("Sky3D cumulus FBM layout changed")
	source = source.replace(original_fbm_tail, capture_fbm_tail)
	var celestial_block: String = """// Sun
	vec3 sun_disk = calc_disk_mask(world_pos, sun_pos, sun_disk_size) * sun_disk_color.rgb * scatter.rgb;
	sun_disk *= sun_disk_intensity;

	// Moon
	float moon_intersect = simple_sphere_intersect(world_pos, moon_pos, moon_size);
	float moon_mask = moon_intersect > (-1. + sqrt(moon_size)) ? 1.0 : 0.0;
	vec3 moon_normal = normalize(world_pos * moon_intersect - moon_pos);

	float moon_ndotl = clamp(dot(moon_normal, sun_pos), 0.0, 1.0);
	vec3 moon_tex = sample_moon_texture(moon_normal);
	vec3 moon_output = moon_mask * moon_ndotl * exp2(1.0) * moon_tex * moon_color.rgb;
	float moonMask = (1.0 - moon_mask);"""
	var hidden_celestial_block: String = """// Celestial disks are intentionally omitted from offline captures.
	vec3 sun_disk = vec3(0.0);
	vec3 moon_output = vec3(0.0);
	float moonMask = 1.0;"""
	if not source.contains(celestial_block):
		return _fail("Sky3D celestial shader layout changed")
	source = source.replace(celestial_block, hidden_celestial_block)

	var shader_file: FileAccess = FileAccess.open(CAPTURE_SHADER_PATH, FileAccess.WRITE)
	if shader_file == null:
		return _fail("cannot create temporary capture shader")
	shader_file.store_string(source)
	shader_file.close()

	var capture_shader: Shader = load(CAPTURE_SHADER_PATH) as Shader
	if capture_shader == null:
		return _fail("cannot load temporary capture shader")
	material.shader = capture_shader
	return true


func _apply_capture_look(material: ShaderMaterial, minute: int) -> void:
	var tonemap_level: float
	var exposure: float
	if minute >= 420 and minute <= 960:
		tonemap_level = 0.72
		exposure = 0.90
	elif minute >= 330 and minute < 420 or minute > 960 and minute <= 1110:
		tonemap_level = 0.65
		exposure = 0.90
	else:
		tonemap_level = 0.45
		exposure = 1.10
	material.set_shader_parameter("color_correction", Vector2(tonemap_level, exposure))


func _fail(message: String) -> bool:
	push_error("Sky3D direct cubemap capture: %s" % message)
	quit(1)
	return false
