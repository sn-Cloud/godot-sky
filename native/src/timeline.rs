use godot::classes::{FileAccess, ResourceLoader};
use godot::prelude::*;
use serde::Deserialize;
use serde_json::Value;

/// 经过完整校验、可直接参与运行时插值的天空关键帧。
/// 该结构不保留未知 JSON 字段，运行时只接触已确认的有限数值和有效资源路径。
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

// 原始反序列化结构与运行时结构分离：JSON 可以缺省 cloud_phase，
// 但进入 SkyFrame 前必须补齐默认值并通过范围、颜色和资源存在性校验。
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

/// 从 Godot 资源路径读取时间轴，逐帧校验后按分钟排序并去重。
///
/// 单个坏帧会被隔离并记录，仍允许其余有效帧工作；只有最终没有任何有效帧时
/// 才让整个加载失败。这一边界保证配置局部损坏不会直接导致天空系统不可用。
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

    // 先解析为 Value 是为了逐帧容错；直接反序列化 Vec 会让一个坏帧拖垮整条时间轴。
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
                godot_error!("VRSky skipped frame {index}: {error}");
                continue;
            }
        };

        match validate_frame(raw) {
            Ok(frame) => frames.push(frame),
            Err(error) => godot_error!("VRSky skipped frame {index}: {error}"),
        }
    }

    // 排序是后续相邻帧查找的前置条件；total_cmp 在已校验有限数值后具有稳定顺序。
    frames.sort_by(|left, right| left.minute.total_cmp(&right.minute));
    frames.dedup_by(|left, right| {
        let duplicate = (left.minute - right.minute).abs() <= 0.000_001;
        if duplicate {
            godot_error!(
                "VRSky skipped duplicate timeline minute {:.3}",
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

    // 旧或简化配置未填写相位时，以时间在全天的比例作为连续默认值。
    let cloud_phase = raw.cloud_phase.unwrap_or(raw.minute / 1440.0);
    if !cloud_phase.is_finite() || !(0.0..1.0).contains(&cloud_phase) {
        return Err(format!(
            "cloud_phase must be finite and inside 0..1, got {cloud_phase}"
        ));
    }

    // 在加载时间轴阶段只检查资源是否存在，不提前把所有大贴图载入内存。
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
    // JSON 允许附带额外通道，但运行时环境色和太阳色只消费前三个 RGB 分量。
    if values.len() < 3 || values[..3].iter().any(|value| !value.is_finite()) {
        return Err(format!("{name} must contain at least three finite numbers"));
    }
    Ok(Color::from_rgb(values[0], values[1], values[2]))
}
