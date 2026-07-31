mod math;
mod timeline;

use std::collections::HashSet;

use godot::classes::resource_loader::ThreadLoadStatus;
use godot::classes::{
    DirectionalLight3D, INode3D, MeshInstance3D, Node3D, Resource, ResourceLoader, ShaderMaterial,
    Texture2D, Time, Timer, WorldEnvironment,
};
use godot::global::Error;
use godot::prelude::*;
use timeline::SkyFrame;

const DEFAULT_TIMELINE_PATH: &str = "res://addons/quest_sky/assets/sky/sky_timeline.json";

struct QuestSkyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for QuestSkyExtension {}

/// Pure-Rust runtime controller for the Quest-oriented texture sky.
#[derive(GodotClass)]
#[class(base = Node3D)]
pub struct QuestSkyController {
    #[export]
    sync_system_clock: bool,
    #[export]
    manual_time_minutes: f64,
    #[export]
    update_interval_seconds: f64,
    #[export]
    sun_azimuth_offset_degrees: f64,
    #[export]
    timeline_path: GString,

    frames: Vec<SkyFrame>,
    sky_mesh: Option<Gd<MeshInstance3D>>,
    sun_light: Option<Gd<DirectionalLight3D>>,
    world_environment: Option<Gd<WorldEnvironment>>,
    update_timer: Option<Gd<Timer>>,
    material: Option<Gd<ShaderMaterial>>,

    loaded_frame_a: Option<usize>,
    loaded_frame_b: Option<usize>,
    texture_a: Option<Gd<Texture2D>>,
    texture_b: Option<Gd<Texture2D>>,
    failed_texture_paths: HashSet<String>,
    prefetch_path: Option<String>,

    base: Base<Node3D>,
}

#[godot_api]
impl INode3D for QuestSkyController {
    fn init(base: Base<Node3D>) -> Self {
        Self {
            sync_system_clock: true,
            manual_time_minutes: 720.0,
            update_interval_seconds: 60.0,
            sun_azimuth_offset_degrees: -25.0,
            timeline_path: GString::from(DEFAULT_TIMELINE_PATH),
            frames: Vec::new(),
            sky_mesh: None,
            sun_light: None,
            world_environment: None,
            update_timer: None,
            material: None,
            loaded_frame_a: None,
            loaded_frame_b: None,
            texture_a: None,
            texture_b: None,
            failed_texture_paths: HashSet::new(),
            prefetch_path: None,
            base,
        }
    }

    fn ready(&mut self) {
        if !self.bind_scene_nodes() {
            self.base_mut().set_process(false);
            return;
        }

        self.set_static_shader_parameters();
        if !self.reload_timeline_internal() {
            self.set_sky_visible(false);
            return;
        }

        let callable = self.base().callable("refresh_sky_state");
        let target_interval = self.clamped_update_interval();
        if let Some(timer) = self.update_timer.as_mut() {
            timer.set_wait_time(target_interval);
            if !timer.is_connected("timeout", &callable) {
                let result = timer.connect("timeout", &callable);
                if result != Error::OK {
                    godot_error!("Quest Sky failed to connect update timer: {result:?}");
                    return;
                }
            }
            timer.start();
        }

        self.refresh_sky_state();
    }
}

#[godot_api]
impl QuestSkyController {
    #[func]
    pub fn refresh_sky_state(&mut self) {
        if self.frames.is_empty() || self.material.is_none() {
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
            self.set_sky_visible(false);
            return;
        }
        self.set_sky_visible(true);

        let current = self.frames[frame_a].clone();
        let next = self.frames[frame_b].clone();
        let texture_a = self.texture_a.clone().expect("validated texture A");
        let texture_b = self.texture_b.clone().expect("validated texture B");
        let sun_direction = self.calculate_sun_direction(minutes);

        if let Some(material) = self.material.as_mut() {
            material.set_shader_parameter("sky_texture_a", &texture_a.to_variant());
            material.set_shader_parameter("sky_texture_b", &texture_b.to_variant());
            material.set_shader_parameter("blend_factor", &blend.to_variant());
            material.set_shader_parameter("sun_direction", &sun_direction.to_variant());
            material.set_shader_parameter("moon_direction", &(-sun_direction).to_variant());
        }

        self.apply_art_parameters(&current, &next, blend, sun_direction);
    }

    #[func]
    pub fn reload_timeline(&mut self) -> bool {
        let loaded = self.reload_timeline_internal();
        if loaded {
            self.refresh_sky_state();
        } else {
            self.set_sky_visible(false);
        }
        loaded
    }

    #[func]
    pub fn set_manual_time(&mut self, hour: i64, minute: i64) {
        self.sync_system_clock = false;
        self.manual_time_minutes = ((hour * 60 + minute) as f64).rem_euclid(1440.0);
        self.refresh_sky_state();
    }

    #[func]
    pub fn set_manual_minutes(&mut self, minutes: f64) {
        self.sync_system_clock = false;
        self.manual_time_minutes = minutes.rem_euclid(1440.0);
        self.refresh_sky_state();
    }
}

impl QuestSkyController {
    fn bind_scene_nodes(&mut self) -> bool {
        let (sky_mesh, sun_light, world_environment, update_timer) = {
            let base = self.base();
            (
                base.try_get_node_as::<MeshInstance3D>("SkyMesh"),
                base.try_get_node_as::<DirectionalLight3D>("SunLight"),
                base.try_get_node_as::<WorldEnvironment>("WorldEnvironment"),
                base.try_get_node_as::<Timer>("UpdateTimer"),
            )
        };

        self.sky_mesh = sky_mesh;
        self.sun_light = sun_light;
        self.world_environment = world_environment;
        self.update_timer = update_timer;

        if self.sky_mesh.is_none()
            || self.sun_light.is_none()
            || self.world_environment.is_none()
            || self.update_timer.is_none()
        {
            godot_error!(
                "Quest Sky native scene is incomplete. Expected SkyMesh, SunLight, WorldEnvironment and UpdateTimer."
            );
            return false;
        }

        self.material = self
            .sky_mesh
            .as_ref()
            .and_then(|mesh| mesh.get_material_override())
            .and_then(|material| material.try_cast::<ShaderMaterial>().ok());
        if self.material.is_none() {
            godot_error!("Quest Sky SkyMesh must use a ShaderMaterial override.");
            return false;
        }

        true
    }

    fn set_static_shader_parameters(&mut self) {
        if let Some(material) = self.material.as_mut() {
            material.set_shader_parameter("sun_inner_cos", &(0.0105_f64).cos().to_variant());
            material.set_shader_parameter("sun_outer_cos", &(0.0142_f64).cos().to_variant());
            material.set_shader_parameter("moon_inner_cos", &(0.0080_f64).cos().to_variant());
            material.set_shader_parameter("moon_outer_cos", &(0.0108_f64).cos().to_variant());
        }
    }

    fn reload_timeline_internal(&mut self) -> bool {
        self.reset_texture_state();
        match timeline::load_timeline(&self.timeline_path) {
            Ok(frames) => {
                self.frames = frames;
                true
            }
            Err(error) => {
                self.frames.clear();
                godot_error!("Quest Sky timeline error: {error}");
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

        godot_error!("Quest Sky could not resolve timeline minute {current:.3}");
        (0, 0, 0.0)
    }

    fn ensure_textures(&mut self, frame_a: usize, frame_b: usize) -> bool {
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
        if self.failed_texture_paths.insert(path.to_owned()) {
            godot_error!("Quest Sky texture failure ({reason}): {path}");
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
        let ambient_color = lerp_color(current.ambient_color, next.ambient_color, blend);
        let ambient_energy = lerp_f32(current.ambient_energy, next.ambient_energy, blend);
        let sun_color = lerp_color(current.sun_color, next.sun_color, blend);
        let sun_energy = lerp_f32(current.sun_energy, next.sun_energy, blend);
        let moon_energy = lerp_f32(current.moon_energy, next.moon_energy, blend);

        if let Some(material) = self.material.as_mut() {
            let shader_sun_color = Vector3::new(sun_color.r, sun_color.g, sun_color.b);
            material.set_shader_parameter("sun_color", &shader_sun_color.to_variant());
            material
                .set_shader_parameter("sun_intensity", &(f64::from(sun_energy) * 1.7).to_variant());
            material.set_shader_parameter("moon_intensity", &f64::from(moon_energy).to_variant());
        }

        if let Some(light) = self.sun_light.as_mut() {
            light.set_visible(sun_energy > 0.001);
            light.set("light_energy", &f64::from(sun_energy).to_variant());
            light.set("light_color", &sun_color.to_variant());
            light.set_basis(light_basis(-sun_direction));
        }

        if let Some(world_environment) = self.world_environment.as_mut() {
            if let Some(mut environment) = world_environment.get_environment() {
                environment.set("ambient_light_source", &3_i64.to_variant());
                environment.set("ambient_light_color", &ambient_color.to_variant());
                environment.set(
                    "ambient_light_energy",
                    &f64::from(ambient_energy).to_variant(),
                );
            }
        }
    }

    fn set_sky_visible(&mut self, visible: bool) {
        if let Some(sky_mesh) = self.sky_mesh.as_mut() {
            sky_mesh.set_visible(visible);
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
