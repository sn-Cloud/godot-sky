mod math;

use godot::classes::{INode, Node};
use godot::prelude::*;

struct QuestSkyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for QuestSkyExtension {}

/// Native math/control companion for the texture sky.
///
/// Rendering deliberately remains in one tiny Godot shader. This class exposes
/// deterministic time/keyframe math without adding any per-frame native work.
#[derive(GodotClass)]
#[class(base = Node)]
pub struct QuestSkyNative {
    #[export]
    manual_time_minutes: f64,
    #[export]
    azimuth_offset_degrees: f64,
    base: Base<Node>,
}

#[godot_api]
impl INode for QuestSkyNative {
    fn init(base: Base<Node>) -> Self {
        Self {
            manual_time_minutes: 720.0,
            azimuth_offset_degrees: -25.0,
            base,
        }
    }
}

#[godot_api]
impl QuestSkyNative {
    #[func]
    fn normalized_minutes(&self, minutes: f64) -> f64 {
        math::normalize_minutes(minutes)
    }

    /// Returns Vector3(current_index, next_index, blend).
    #[func]
    fn equal_keyframe_pair(&self, minutes: f64, frame_count: i64) -> Vector3 {
        if frame_count <= 0 {
            godot_error!("frame_count must be positive");
            return Vector3::ZERO;
        }

        let (current, next, blend) = math::equal_keyframe_pair(minutes, frame_count);
        Vector3::new(current as f32, next as f32, blend as f32)
    }

    #[func]
    fn calculate_sun_direction(&self, minutes: f64) -> Vector3 {
        let radians = self.azimuth_offset_degrees.to_radians();
        let direction = math::sun_direction(minutes, radians);
        Vector3::new(
            direction[0] as f32,
            direction[1] as f32,
            direction[2] as f32,
        )
    }

    #[func]
    fn calculate_moon_direction(&self, minutes: f64) -> Vector3 {
        -self.calculate_sun_direction(minutes)
    }
}
