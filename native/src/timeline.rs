use godot::classes::{FileAccess, ResourceLoader};
use godot::prelude::*;
use serde::Deserialize;
use serde_json::Value;

#[derive(Clone, Debug)]
pub struct SkyFrame {
    pub minute: f64,
    pub texture: String,
    pub cloud_phase: f64,
    pub ambient_color: Color,
    pub ambient_energy: f32,
    pub sun_color: Color,
    pub sun_energy: f32,
    pub moon_energy: f32,
}

#[derive(Deserialize)]
struct RawSkyFrame {
    minute: f64,
    texture: String,
    #[serde(default)]
    cloud_phase: Option<f64>,
    ambient_color: Vec<f32>,
    ambient_energy: f32,
    sun_color: Vec<f32>,
    sun_energy: f32,
    moon_energy: f32,
}

pub fn load_timeline(path: &GString) -> Result<Vec<SkyFrame>, String> {
    if path.is_empty() {
        return Err("timeline path is empty".to_owned());
    }
    if !FileAccess::file_exists(path) {
        return Err(format!("timeline does not exist: {path}"));
    }

    let text = FileAccess::get_file_as_string(path);
    if text.is_empty() {
        return Err(format!("timeline is empty or unreadable: {path}"));
    }

    let root: Value = serde_json::from_str(&text.to_string())
        .map_err(|error| format!("invalid JSON in {path}: {error}"))?;
    let raw_frames = root
        .get("frames")
        .and_then(Value::as_array)
        .ok_or_else(|| format!("timeline must contain a frames array: {path}"))?;

    let mut frames = Vec::with_capacity(raw_frames.len());
    for (index, value) in raw_frames.iter().enumerate() {
        let raw: RawSkyFrame = match serde_json::from_value(value.clone()) {
            Ok(frame) => frame,
            Err(error) => {
                godot_error!("Quest Sky skipped frame {index}: {error}");
                continue;
            }
        };

        match validate_frame(raw) {
            Ok(frame) => frames.push(frame),
            Err(error) => godot_error!("Quest Sky skipped frame {index}: {error}"),
        }
    }

    frames.sort_by(|left, right| left.minute.total_cmp(&right.minute));
    frames.dedup_by(|left, right| {
        let duplicate = (left.minute - right.minute).abs() <= 0.000_001;
        if duplicate {
            godot_error!(
                "Quest Sky skipped duplicate timeline minute {:.3}",
                right.minute
            );
        }
        duplicate
    });

    if frames.is_empty() {
        return Err(format!("timeline has no valid frames: {path}"));
    }

    Ok(frames)
}

fn validate_frame(raw: RawSkyFrame) -> Result<SkyFrame, String> {
    if !raw.minute.is_finite() || !(0.0..1440.0).contains(&raw.minute) {
        return Err(format!(
            "minute must be finite and inside 0..1439.999, got {}",
            raw.minute
        ));
    }
    if raw.texture.is_empty() {
        return Err("texture path is empty".to_owned());
    }

    let cloud_phase = raw.cloud_phase.unwrap_or(raw.minute / 1440.0);
    if !cloud_phase.is_finite() || !(0.0..1.0).contains(&cloud_phase) {
        return Err(format!(
            "cloud_phase must be finite and inside 0..1, got {cloud_phase}"
        ));
    }

    let texture_path = GString::from(raw.texture.as_str());
    if !ResourceLoader::singleton().exists(&texture_path) {
        return Err(format!("texture does not exist: {}", raw.texture));
    }

    let ambient_color = parse_color(&raw.ambient_color, "ambient_color")?;
    let sun_color = parse_color(&raw.sun_color, "sun_color")?;
    for (name, value) in [
        ("ambient_energy", raw.ambient_energy),
        ("sun_energy", raw.sun_energy),
        ("moon_energy", raw.moon_energy),
    ] {
        if !value.is_finite() {
            return Err(format!("{name} must be finite"));
        }
    }

    Ok(SkyFrame {
        minute: raw.minute,
        texture: raw.texture,
        cloud_phase,
        ambient_color,
        ambient_energy: raw.ambient_energy,
        sun_color,
        sun_energy: raw.sun_energy,
        moon_energy: raw.moon_energy,
    })
}

fn parse_color(values: &[f32], name: &str) -> Result<Color, String> {
    if values.len() < 3 || values[..3].iter().any(|value| !value.is_finite()) {
        return Err(format!("{name} must contain at least three finite numbers"));
    }
    Ok(Color::from_rgb(values[0], values[1], values[2]))
}
