mod math;

use godot::classes::{INode, Node};
use godot::prelude::*;

struct QuestSkyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for QuestSkyExtension {}

/// Optional native companion for the once-per-minute sun-direction update.
///
/// Rendering stays in one lightweight Godot shader. Timeline lookup remains in
/// GDScript because the timeline supports arbitrary keyframe spacing.
#[derive(GodotClass)]
#[class(base = Node)]
pub struct QuestSkyNative {
    #[export]
    azimuth_offset_degrees: f64,
    base: Base<Node>,
}

#[godot_api]
impl INode for QuestSkyNative {
    fn init(base: Base<Node>) -> Self {
        Self {
            azimuth_offset_degrees: -25.0,
            base,
        }
    }
}

#[godot_api]
impl QuestSkyNative {
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
}
