extends SceneTree

## 为每个关键时间点把 Sky3D 直接渲染成六张高分辨率立方体面。
## 这里有意绕过 RenderingServer.sky_bake_panorama()，因为后者的细节上限
## 会受到 Sky.radiance_size 限制，无法满足 VRSky 离线全景贴图的清晰度要求。

const DEFAULT_OUTPUT_DIR: String = "F:/3rdLib/godot-sky/.sky3d-cubemaps"
const DEFAULT_FACE_SIZE: int = 2048
const SKY3D_DEMO_SCENE: String = "res://demo/Sky3DDemo.tscn"
const SOURCE_SHADER_PATH: String = "res://addons/sky_3d/shaders/SkyMaterial.gdshader"
const CAPTURE_SHADER_PATH: String = "user://vrsky_direct_capture.gdshader"
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
	# SceneTree 脚本没有普通场景的 ready 生命周期；参数校验成功后延迟一帧，
	# 确保根窗口和 RenderingServer 已准备好，再开始创建离屏视口。
	if not _parse_arguments():
		return
	call_deferred("_capture_all")


func _parse_arguments() -> bool:
	# 只接受明确列出的离线工具参数。未知参数立即失败，避免拼写错误后把大图写入默认目录。
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

	# 只从演示场景抽取 Sky3D 环境层级。演示几何体和相机绝不能进入离线立方体贴图，
	# 否则它们会被永久烘焙进 VRSky 的无穷远背景。
	var demo_scene: Node = packed_scene.instantiate()
	var sky3d: Variant = demo_scene.get_node_or_null("Sky3D")
	if sky3d == null:
		_fail("Sky3D demo does not contain a Sky3D node")
		return
	demo_scene.remove_child(sky3d)
	demo_scene.free()

	var viewport: SubViewport = SubViewport.new()
	# 独立 World3D 隔离外部场景状态；90° 相机配合六个轴向恰好覆盖完整球面。
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

	# 太阳和月亮由 VRSky 运行时按设备时间连续移动，不能烘焙进任何关键帧。
	# 同时关闭辅助网格，确保输出只包含大气、星空和云层本身。
	sky_dome.sun_disk_intensity = 0.0
	sky_dome.moon_size = 0.0
	sky_dome.atm_sun_mie_intensity = 0.0
	sky_dome.atm_moon_mie_intensity = 0.0
	material.set_shader_parameter("show_azimuthal_grid", false)
	material.set_shader_parameter("show_equatorial_grid", false)

	for minute: int in frame_minutes:
		# 每次修改 Sky3D 时间后等待两帧，使 tool 脚本、材质参数和离屏渲染全部收敛。
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
			# 每个面再次等待两帧并强制同步，防止读取到上一相机方向的 GPU 结果。
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
	# 捕获 Shader 从 Sky3D 原始源码派生，但只存在于 user:// 临时目录，
	# 不修改第三方插件，也不让离线专用采样成本进入目标项目运行时。
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
	# 下列英文注释属于待匹配的 Sky3D 上游 Shader 原文，不是本工具自身注释；
	# 保留它们才能在上游结构变化时可靠地拒绝生成错误资源。
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
	var hidden_celestial_block: String = """// 离线天空贴图有意排除天体圆盘，交由 VRSky 运行时绘制。
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
	# 曝光只服务于离线贴图动态范围：白天压高光，夜间保留星空和云层暗部。
	# 运行时仍由时间轴控制环境光与天体能量，不在这里烘焙光照强度逻辑。
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
