mod math;
mod timeline;

use std::collections::HashSet;

use godot::classes::resource_loader::ThreadLoadStatus;
use godot::classes::{
    DirectionalLight3D, Engine, INode3D, Node3D, Resource, ResourceLoader, ShaderMaterial,
    Texture2D, Time, Timer, WorldEnvironment,
};
use godot::global::Error;
use godot::prelude::*;
use timeline::SkyFrame;

// 默认资源路径属于插件公开安装约定。目标项目只需复制 addons/vrsky，
// 不应依赖源码仓库目录或 user:// 下的临时文件。
const DEFAULT_TIMELINE_PATH: &str = "res://addons/vrsky/assets/sky/sky_timeline.json";

// GDExtension 入口只负责向 Godot 注册本 crate 中的原生类型；
// 天空生命周期全部由 VrSkyController 管理，不在入口阶段访问场景树。
struct VrSkyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for VrSkyExtension {}

/// VRSky 的纯 Rust 运行时控制器。
///
/// 该节点是场景内天空状态的唯一协调者：读取时间轴、管理有限数量的贴图、
/// 更新 Environment.sky 的 Shader 参数，并同步太阳光、月光和环境光。
/// 它不创建目标项目的相机或 XR 原点，也不接管项目的输入和 OpenXR 生命周期。
#[derive(GodotClass)]
#[class(tool, base = Node3D)]
pub struct VrSkyController {
    /// 为 true 时读取设备时钟；为 false 时使用 manual_time_minutes。
    #[export]
    #[var(set = set_sync_system_clock)]
    sync_system_clock: bool,
    /// 手动预览时间，以当天零点后的分钟数表示，写入时归一化到 0..1440。
    #[export]
    #[var(set = set_manual_time_minutes)]
    manual_time_minutes: f64,
    /// 天空状态刷新周期。它不是渲染帧率，避免把低频天空变化变成逐帧开销。
    #[export]
    #[var(set = set_update_interval_seconds)]
    update_interval_seconds: f64,
    /// 围绕世界 Y 轴旋转太阳轨迹，用于对齐目标项目的美术朝向。
    #[export]
    #[var(set = set_sun_azimuth_offset_degrees)]
    sun_azimuth_offset_degrees: f64,
    /// 时间轴 JSON 的 Godot 资源路径；修改后会重新校验全部关键帧。
    #[export]
    #[var(set = set_timeline_path)]
    timeline_path: GString,

    // 时间轴与场景引用只在初始化或属性变化时重建，正常刷新不重复查找节点。
    frames: Vec<SkyFrame>,
    sun_light: Option<Gd<DirectionalLight3D>>,
    moon_light: Option<Gd<DirectionalLight3D>>,
    world_environment: Option<Gd<WorldEnvironment>>,
    update_timer: Option<Gd<Timer>>,
    environment_material: Option<Gd<ShaderMaterial>>,

    // 运行时最多强引用当前与下一张贴图，并异步预取再下一张。
    // 失败路径集合用于阻止坏资源在每次 Timer 触发时反复加载和刷屏。
    loaded_frame_a: Option<usize>,
    loaded_frame_b: Option<usize>,
    texture_a: Option<Gd<Texture2D>>,
    texture_b: Option<Gd<Texture2D>>,
    failed_texture_paths: HashSet<String>,
    prefetch_path: Option<String>,
    editor_refresh_elapsed: f64,

    // godot-rust 要求原生 Node3D 持有基类句柄；所有场景树操作都经由它完成。
    base: Base<Node3D>,
}

#[godot_api]
impl INode3D for VrSkyController {
    // init 只建立无场景依赖的安全默认值。子节点尚不可访问，绑定工作留给 ready。
    fn init(base: Base<Node3D>) -> Self {
        Self {
            sync_system_clock: true,
            manual_time_minutes: 720.0,
            update_interval_seconds: 60.0,
            sun_azimuth_offset_degrees: -25.0,
            timeline_path: GString::from(DEFAULT_TIMELINE_PATH),
            frames: Vec::new(),
            sun_light: None,
            moon_light: None,
            world_environment: None,
            update_timer: None,
            environment_material: None,
            loaded_frame_a: None,
            loaded_frame_b: None,
            texture_a: None,
            texture_b: None,
            failed_texture_paths: HashSet::new(),
            prefetch_path: None,
            editor_refresh_elapsed: 0.0,
            base,
        }
    }

    fn ready(&mut self) {
        // 初始化失败时停用编辑器 process，避免残缺场景持续触发刷新与错误日志。
        if !self.initialize_scene() {
            self.base_mut().set_process(false);
        }
    }

    fn process(&mut self, delta: f64) {
        // 游戏运行时由 Timer 驱动；编辑器没有稳定的运行时 Timer 生命周期，
        // 因此 tool 预览单独在 process 中累计时间，两个驱动不能同时工作。
        if !Engine::singleton().is_editor_hint() {
            return;
        }

        self.editor_refresh_elapsed += delta;
        if self.editor_refresh_elapsed >= self.clamped_update_interval() {
            self.editor_refresh_elapsed = 0.0;
            self.refresh_sky_state();
        }
    }
}

#[godot_api]
impl VrSkyController {
    /// 切换设备时间同步，并立即刷新编辑器或运行中实例。
    #[func]
    pub fn set_sync_system_clock(&mut self, enabled: bool) {
        self.sync_system_clock = enabled;
        self.refresh_after_property_change(false);
    }

    /// 设置手动分钟数。rem_euclid 同时正确处理负数和超过一天的输入。
    #[func]
    pub fn set_manual_time_minutes(&mut self, minutes: f64) {
        self.manual_time_minutes = minutes.rem_euclid(1440.0);
        self.refresh_after_property_change(false);
    }

    /// 设置低频更新间隔，限制在 1 到 600 秒以避免失控刷新或长时间不更新。
    #[func]
    pub fn set_update_interval_seconds(&mut self, seconds: f64) {
        self.update_interval_seconds = seconds.clamp(1.0, 600.0);
        self.editor_refresh_elapsed = 0.0;
        self.refresh_after_property_change(false);
    }

    /// 设置太阳方位偏移，限制为一圈内唯一的 -180 到 180 度表示。
    #[func]
    pub fn set_sun_azimuth_offset_degrees(&mut self, degrees: f64) {
        self.sun_azimuth_offset_degrees = degrees.clamp(-180.0, 180.0);
        self.refresh_after_property_change(false);
    }

    /// 替换时间轴资源，并在节点已进入场景树时重新加载。
    #[func]
    pub fn set_timeline_path(&mut self, path: GString) {
        self.timeline_path = path;
        self.refresh_after_property_change(true);
    }

    /// 根据当前时间把天空、天体方向和环境光原子式应用到同一帧状态。
    /// 任一关键贴图尚不可用时保持上一帧，不提交半更新的视觉状态。
    #[func]
    pub fn refresh_sky_state(&mut self) {
        if self.frames.is_empty() || self.environment_material.is_none() {
            return;
        }

        let target_interval = self.clamped_update_interval();
        if let Some(timer) = self.update_timer.as_mut() {
            if (timer.get_wait_time() - target_interval).abs() > f64::EPSILON {
                timer.set_wait_time(target_interval);
            }
        }

        let minutes = self.current_minutes();
        let (frame_a, frame_b, blend) = self.find_keyframe_pair(minutes);
        if !self.ensure_textures(frame_a, frame_b) {
            return;
        }

        let current = self.frames[frame_a].clone();
        let next = self.frames[frame_b].clone();
        let texture_a = self.texture_a.clone().expect("validated texture A");
        let texture_b = self.texture_b.clone().expect("validated texture B");
        let sun_direction = self.calculate_sun_direction(minutes);
        let cloud_offsets = math::cloud_sample_offsets(
            current.cloud_phase,
            next.cloud_phase,
            blend,
            frame_b <= frame_a,
        );

        // 可见背景与环境辐照共用同一个 Sky ShaderMaterial，保证模型受光和背景一致。
        if let Some(material) = self.environment_material.as_mut() {
            material.set_shader_parameter("sky_texture_a", &texture_a.to_variant());
            material.set_shader_parameter("sky_texture_b", &texture_b.to_variant());
            material.set_shader_parameter("blend_factor", &blend.to_variant());
            material.set_shader_parameter("cloud_uv_offset_a", &cloud_offsets[0].to_variant());
            material.set_shader_parameter("cloud_uv_offset_b", &cloud_offsets[1].to_variant());
            material.set_shader_parameter("sun_direction", &sun_direction.to_variant());
            material.set_shader_parameter("moon_direction", &(-sun_direction).to_variant());
        }

        self.apply_art_parameters(&current, &next, blend, sun_direction);
    }

    /// 重新读取并校验时间轴；仅在成功后刷新，失败时不伪造默认帧。
    #[func]
    pub fn reload_timeline(&mut self) -> bool {
        let loaded = self.reload_timeline_internal();
        if loaded {
            self.refresh_sky_state();
        }
        loaded
    }

    /// 以小时和分钟切换到手动时间，供 GDScript 测试界面直接调用。
    #[func]
    pub fn set_manual_time(&mut self, hour: i64, minute: i64) {
        self.sync_system_clock = false;
        self.manual_time_minutes = ((hour * 60 + minute) as f64).rem_euclid(1440.0);
        self.refresh_sky_state();
    }

    /// 以分钟切换到手动时间，适合滑杆和自动化测试。
    #[func]
    pub fn set_manual_minutes(&mut self, minutes: f64) {
        self.sync_system_clock = false;
        self.manual_time_minutes = minutes.rem_euclid(1440.0);
        self.refresh_sky_state();
    }
}

impl VrSkyController {
    // 初始化顺序有意固定：先验证场景契约，再加载数据，最后启动更新驱动。
    // 任何一步失败都不会留下一个仍在周期运行的半初始化控制器。
    fn initialize_scene(&mut self) -> bool {
        if !self.bind_scene_nodes() {
            return false;
        }

        self.set_static_shader_parameters();
        if !self.reload_timeline_internal() {
            return false;
        }

        if !self.configure_update_driver() {
            return false;
        }

        self.refresh_sky_state();
        true
    }

    fn refresh_after_property_change(&mut self, reload_timeline: bool) {
        // Inspector setter 可能在节点进入场景树前执行，此时只保存属性值，
        // 等 ready 统一绑定资源，避免访问尚不存在的子节点。
        if !self.base().is_inside_tree() {
            return;
        }

        if self.environment_material.is_none() && !self.bind_scene_nodes() {
            return;
        }
        self.set_static_shader_parameters();

        if reload_timeline || self.frames.is_empty() {
            if !self.reload_timeline_internal() {
                return;
            }
        }

        if self.configure_update_driver() {
            self.refresh_sky_state();
        }
    }

    fn configure_update_driver(&mut self) -> bool {
        let editor_hint = Engine::singleton().is_editor_hint();
        let target_interval = self.clamped_update_interval();
        let callable = self.base().callable("refresh_sky_state");

        if let Some(timer) = self.update_timer.as_mut() {
            timer.set_wait_time(target_interval);
            if editor_hint {
                // 编辑器预览由 process 驱动，停止 Timer 可防止 tool 场景重复更新。
                timer.stop();
            } else {
                if !timer.is_connected("timeout", &callable) {
                    let result = timer.connect("timeout", &callable);
                    if result != Error::OK {
                        godot_error!("VRSky failed to connect update timer: {result:?}");
                        return false;
                    }
                }
                timer.start();
            }
        }

        self.base_mut().set_process(editor_hint);
        true
    }

    fn bind_scene_nodes(&mut self) -> bool {
        // 子节点名称是 vrsky.tscn 对原生类的内部契约。插件使用者可以移动整个
        // VRSky 根节点，但不应删除或重命名这些直属子节点。
        let (sun_light, moon_light, world_environment, update_timer) = {
            let base = self.base();
            (
                base.try_get_node_as::<DirectionalLight3D>("SunLight"),
                base.try_get_node_as::<DirectionalLight3D>("MoonLight"),
                base.try_get_node_as::<WorldEnvironment>("WorldEnvironment"),
                base.try_get_node_as::<Timer>("UpdateTimer"),
            )
        };

        self.sun_light = sun_light;
        self.moon_light = moon_light;
        self.world_environment = world_environment;
        self.update_timer = update_timer;

        if self.sun_light.is_none()
            || self.moon_light.is_none()
            || self.world_environment.is_none()
            || self.update_timer.is_none()
        {
            godot_error!(
                "VRSky native scene is incomplete. Expected SunLight, MoonLight, WorldEnvironment and UpdateTimer."
            );
            return false;
        }

        self.environment_material = self
            .world_environment
            .as_ref()
            .and_then(|world| world.get_environment())
            .and_then(|environment| environment.get_sky())
            .and_then(|sky| sky.get_material())
            .and_then(|material| material.try_cast::<ShaderMaterial>().ok());
        // 这里只接受 ShaderMaterial，因为后续更新依赖明确的参数名称；
        // 自动降级到普通 SkyMaterial 会产生背景存在但昼夜状态不更新的隐蔽错误。
        if self.environment_material.is_none() {
            godot_error!("VRSky Environment must use a Sky with a ShaderMaterial.");
            return false;
        }

        true
    }

    fn set_static_shader_parameters(&mut self) {
        // 圆盘边缘使用角半径的余弦阈值。参数只与美术尺寸有关，
        // 不随时间变化，因此不放进每次 refresh_sky_state 的热路径。
        if let Some(material) = self.environment_material.as_mut() {
            material.set_shader_parameter("sun_inner_cos", &(0.0105_f64).cos().to_variant());
            material.set_shader_parameter("sun_outer_cos", &(0.0142_f64).cos().to_variant());
            material.set_shader_parameter("moon_inner_cos", &(0.0080_f64).cos().to_variant());
            material.set_shader_parameter("moon_outer_cos", &(0.0108_f64).cos().to_variant());
        }
    }

    fn reload_timeline_internal(&mut self) -> bool {
        // 时间轴切换后旧索引与旧贴图不再具有语义，必须先整体失效。
        self.reset_texture_state();
        match timeline::load_timeline(&self.timeline_path) {
            Ok(frames) => {
                self.frames = frames;
                true
            }
            Err(error) => {
                self.frames.clear();
                godot_error!("VRSky timeline error: {error}");
                false
            }
        }
    }

    fn reset_texture_state(&mut self) {
        self.loaded_frame_a = None;
        self.loaded_frame_b = None;
        self.texture_a = None;
        self.texture_b = None;
        self.failed_texture_paths.clear();
        self.prefetch_path = None;
    }

    fn clamped_update_interval(&self) -> f64 {
        self.update_interval_seconds.clamp(1.0, 600.0)
    }

    fn current_minutes(&self) -> f64 {
        if !self.sync_system_clock {
            return self.manual_time_minutes.rem_euclid(1440.0);
        }

        // 使用 Godot Time API 而不是 Rust 本地时区库，保持编辑器与导出平台行为一致。
        let now = Time::singleton().get_time_dict_from_system();
        let hour = now
            .get("hour")
            .and_then(|value| value.try_to::<i64>().ok())
            .unwrap_or(0);
        let minute = now
            .get("minute")
            .and_then(|value| value.try_to::<i64>().ok())
            .unwrap_or(0);
        let second = now
            .get("second")
            .and_then(|value| value.try_to::<i64>().ok())
            .unwrap_or(0);
        (hour * 60 + minute) as f64 + second as f64 / 60.0
    }

    fn find_keyframe_pair(&self, minutes: f64) -> (usize, usize, f64) {
        if self.frames.len() == 1 {
            return (0, 0, 0.0);
        }

        let current = minutes.rem_euclid(1440.0);
        // 最后一帧到第一帧跨越午夜，把结束时间和必要时的当前时间展开到第二天，
        // 从而沿同一条连续区间计算插值权重。
        for index in 0..self.frames.len() {
            let next_index = (index + 1) % self.frames.len();
            let start = self.frames[index].minute;
            let mut end = self.frames[next_index].minute;
            if next_index == 0 {
                end += 1440.0;
            }

            let mut comparable = current;
            if next_index == 0 && comparable < start {
                comparable += 1440.0;
            }
            if comparable >= start && comparable < end {
                return (index, next_index, (comparable - start) / (end - start));
            }
        }

        godot_error!("VRSky could not resolve timeline minute {current:.3}");
        (0, 0, 0.0)
    }

    fn ensure_textures(&mut self, frame_a: usize, frame_b: usize) -> bool {
        // 缓存完全命中时不触碰 ResourceLoader，也不重复设置强引用。
        if self.loaded_frame_a == Some(frame_a)
            && self.loaded_frame_b == Some(frame_b)
            && self.texture_a.is_some()
            && self.texture_b.is_some()
        {
            return true;
        }

        let mut texture_a = self.texture_for_frame(frame_a);
        let mut texture_b = if frame_b == frame_a {
            texture_a.clone()
        } else {
            self.texture_for_frame(frame_b)
        };

        if texture_a.is_none() && texture_b.is_none() {
            self.loaded_frame_a = None;
            self.loaded_frame_b = None;
            self.texture_a = None;
            self.texture_b = None;
            return false;
        }

        let mut actual_frame_a = frame_a;
        let mut actual_frame_b = frame_b;
        // 单张失败时复制另一张作为双端输入，使背景保持可见且 blend 仍然安全；
        // 两张都失败才放弃本次刷新并保留 Shader 上一次成功状态。
        if texture_a.is_none() {
            texture_a = texture_b.clone();
            actual_frame_a = frame_b;
        }
        if texture_b.is_none() {
            texture_b = texture_a.clone();
            actual_frame_b = actual_frame_a;
        }

        self.loaded_frame_a = Some(actual_frame_a);
        self.loaded_frame_b = Some(actual_frame_b);
        self.texture_a = texture_a;
        self.texture_b = texture_b;
        if actual_frame_a == frame_a && actual_frame_b == frame_b {
            // 只有当前插值对完整可用时才预取下一帧，避免坏帧造成无意义的加载链。
            self.request_prefetch((frame_b + 1) % self.frames.len());
        }
        true
    }

    fn texture_for_frame(&mut self, frame_index: usize) -> Option<Gd<Texture2D>> {
        if self.loaded_frame_a == Some(frame_index) {
            return self.texture_a.clone();
        }
        if self.loaded_frame_b == Some(frame_index) {
            return self.texture_b.clone();
        }

        let path = self.frames[frame_index].texture.clone();
        self.load_texture(&path)
    }

    fn load_texture(&mut self, path: &str) -> Option<Gd<Texture2D>> {
        if self.failed_texture_paths.contains(path) {
            return None;
        }

        let godot_path = GString::from(path);
        if self.prefetch_path.as_deref() == Some(path) {
            // 异步请求尚未完成时本轮直接返回；调用者会保持现有天空，
            // 后续 Timer 或编辑器刷新再领取结果，绝不在渲染线程主动等待。
            let mut loader = ResourceLoader::singleton();
            let status = loader.load_threaded_get_status(&godot_path);
            match status {
                ThreadLoadStatus::LOADED => {
                    let resource = loader.load_threaded_get(&godot_path);
                    self.prefetch_path = None;
                    return self.cast_texture_or_record(path, resource);
                }
                ThreadLoadStatus::IN_PROGRESS => return None,
                ThreadLoadStatus::FAILED | ThreadLoadStatus::INVALID_RESOURCE => {
                    self.prefetch_path = None;
                    self.record_texture_failure(path, "threaded load failed");
                    return None;
                }
                _ => {}
            }
        }

        // 没有预取命中时允许一次同步加载，确保首次进入场景即可得到可见天空。
        let resource = ResourceLoader::singleton().load(&godot_path);
        self.cast_texture_or_record(path, resource)
    }

    fn cast_texture_or_record(
        &mut self,
        path: &str,
        resource: Option<Gd<Resource>>,
    ) -> Option<Gd<Texture2D>> {
        let texture = resource.and_then(|value| value.try_cast::<Texture2D>().ok());
        if texture.is_none() {
            self.record_texture_failure(path, "resource is missing or not a Texture2D");
        }
        texture
    }

    fn request_prefetch(&mut self, frame_index: usize) {
        if self.frames.len() < 2 {
            return;
        }

        let path = self.frames[frame_index].texture.clone();
        // 同一时刻只维护一个预取请求；已加载、已失败或正在预取的资源全部跳过。
        if self.failed_texture_paths.contains(&path)
            || self.prefetch_path.as_deref() == Some(path.as_str())
            || self
                .loaded_frame_a
                .is_some_and(|index| self.frames[index].texture == path)
            || self
                .loaded_frame_b
                .is_some_and(|index| self.frames[index].texture == path)
        {
            return;
        }

        let godot_path = GString::from(path.as_str());
        let result = ResourceLoader::singleton().load_threaded_request(&godot_path);
        if result == Error::OK {
            self.prefetch_path = Some(path);
        } else {
            self.record_texture_failure(&path, &format!("threaded request failed with {result:?}"));
        }
    }

    fn record_texture_failure(&mut self, path: &str, reason: &str) {
        // HashSet 同时承担去重和熔断职责，同一坏资源在本次时间轴生命周期只报一次。
        if self.failed_texture_paths.insert(path.to_owned()) {
            godot_error!("VRSky texture failure ({reason}): {path}");
        }
    }

    fn calculate_sun_direction(&self, minutes: f64) -> Vector3 {
        let radians = self.sun_azimuth_offset_degrees.to_radians();
        let direction = math::sun_direction(minutes, radians);
        Vector3::new(
            direction[0] as f32,
            direction[1] as f32,
            direction[2] as f32,
        )
    }

    fn apply_art_parameters(
        &mut self,
        current: &SkyFrame,
        next: &SkyFrame,
        blend: f64,
        sun_direction: Vector3,
    ) {
        // 光照参数与贴图采用相同权重插值，防止背景已进入下一时段而场景光仍停留在上一帧。
        let ambient_color = lerp_color(current.ambient_color, next.ambient_color, blend);
        let ambient_energy = lerp_f32(current.ambient_energy, next.ambient_energy, blend);
        let sun_color = lerp_color(current.sun_color, next.sun_color, blend);
        let sun_energy = lerp_f32(current.sun_energy, next.sun_energy, blend);
        let moon_energy = lerp_f32(current.moon_energy, next.moon_energy, blend);

        if let Some(material) = self.environment_material.as_mut() {
            let shader_sun_color = Vector3::new(sun_color.r, sun_color.g, sun_color.b);
            material.set_shader_parameter("sun_color", &shader_sun_color.to_variant());
            material
                .set_shader_parameter("sun_intensity", &(f64::from(sun_energy) * 1.7).to_variant());
            material.set_shader_parameter("moon_intensity", &f64::from(moon_energy).to_variant());
        }

        if let Some(light) = self.sun_light.as_mut() {
            // DirectionalLight3D 的本地 -Z 轴代表照射方向，所以太阳使用 -sun_direction。
            light.set_visible(sun_energy > 0.001);
            light.set("light_energy", &f64::from(sun_energy).to_variant());
            light.set("light_color", &sun_color.to_variant());
            light.set_basis(light_basis(-sun_direction));
        }

        if let Some(light) = self.moon_light.as_mut() {
            // 月亮位于太阳反方向，其光线传播方向因此使用 sun_direction。
            light.set_visible(moon_energy > 0.001);
            light.set("light_energy", &(f64::from(moon_energy) * 1.6).to_variant());
            light.set_basis(light_basis(sun_direction));
        }

        if let Some(world_environment) = self.world_environment.as_mut() {
            if let Some(mut environment) = world_environment.get_environment() {
                environment.set("ambient_light_source", &3_i64.to_variant());
                environment.set("ambient_light_color", &ambient_color.to_variant());
                environment.set(
                    "ambient_light_energy",
                    &f64::from(ambient_energy).to_variant(),
                );
                // 日间提高天空对环境光的贡献，夜间保留最低值以免室外模型完全失去层次。
                let daylight = (sun_energy / 0.36).clamp(0.0, 1.0);
                let sky_contribution = lerp_f32(0.25, 0.75, f64::from(daylight));
                environment.set(
                    "ambient_light_sky_contribution",
                    &f64::from(sky_contribution).to_variant(),
                );
                environment.set("reflected_light_source", &0_i64.to_variant());
            }
        }
    }
}

fn lerp_f32(left: f32, right: f32, weight: f64) -> f32 {
    left + (right - left) * weight as f32
}

fn lerp_color(left: Color, right: Color, weight: f64) -> Color {
    let weight = weight as f32;
    Color::from_rgba(
        left.r + (right.r - left.r) * weight,
        left.g + (right.g - left.g) * weight,
        left.b + (right.b - left.b) * weight,
        left.a + (right.a - left.a) * weight,
    )
}

fn light_basis(target_direction: Vector3) -> Basis {
    // 当方向接近世界上轴时改用 FORWARD 作为参考轴，避免叉积接近零导致无效 Basis。
    let forward = target_direction.normalized();
    let up = if forward.dot(Vector3::UP).abs() < 0.98 {
        Vector3::UP
    } else {
        Vector3::FORWARD
    };
    let z_axis = -forward;
    let x_axis = up.cross(z_axis).normalized();
    let y_axis = z_axis.cross(x_axis).normalized();
    Basis::from_cols(x_axis, y_axis, z_axis)
}
