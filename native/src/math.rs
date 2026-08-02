use std::f64::consts::TAU;

// 全部时间计算统一使用“当天零点后的分钟数”，避免小时、秒和归一化相位混用。
pub const MINUTES_PER_DAY: f64 = 1440.0;

/// 把任意分钟数环绕到单日范围。rem_euclid 能正确处理负数，`%` 不能。
pub fn normalize_minutes(minutes: f64) -> f64 {
    minutes.rem_euclid(MINUTES_PER_DAY)
}

/// 计算世界空间中的太阳方向。
///
/// 6:00 位于地平线、12:00 接近天顶、18:00 再次落到地平线；
/// 方位偏移只绕 Y 轴旋转轨迹，不改变太阳高度随时间的变化。
pub fn sun_direction(minutes: f64, azimuth_offset_radians: f64) -> [f64; 3] {
    let phase = TAU * (normalize_minutes(minutes) / MINUTES_PER_DAY - 0.25);
    let x = phase.cos();
    let y = phase.sin();
    let z = 0.18;

    let cos_a = azimuth_offset_radians.cos();
    let sin_a = azimuth_offset_radians.sin();
    normalize3([x * cos_a + z * sin_a, y, -x * sin_a + z * cos_a])
}

/// 计算两张关键帧贴图共同使用的经度采样偏移。
///
/// 两端都对齐到同一个插值后相位，再由 Shader 混合颜色。这样云层不会因为
/// 两张离线贴图各自携带不同相位而出现双影；跨午夜时先展开后一帧以保持连续。
pub fn cloud_sample_offsets(
    phase_a: f64,
    phase_b: f64,
    blend: f64,
    wraps_midnight: bool,
) -> [f64; 2] {
    let mut unwrapped_b = phase_b;
    if wraps_midnight || unwrapped_b < phase_a {
        unwrapped_b += 1.0;
    }

    let current_phase = phase_a + (unwrapped_b - phase_a) * blend.clamp(0.0, 1.0);
    [-current_phase, -current_phase]
}

fn normalize3(value: [f64; 3]) -> [f64; 3] {
    let length = (value[0] * value[0] + value[1] * value[1] + value[2] * value[2]).sqrt();
    [value[0] / length, value[1] / length, value[2] / length]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_negative_and_overflow_minutes() {
        assert_eq!(normalize_minutes(-1.0), 1439.0);
        assert_eq!(normalize_minutes(1441.0), 1.0);
    }

    #[test]
    fn noon_is_above_horizon() {
        let direction = sun_direction(720.0, 0.0);
        assert!(direction[1] > 0.98);
    }

    #[test]
    fn cloud_offsets_align_both_keyframes_to_interpolated_phase() {
        assert_eq!(cloud_sample_offsets(0.25, 0.5, 0.0, false), [-0.25, -0.25]);
        assert_eq!(cloud_sample_offsets(0.25, 0.5, 1.0, false), [-0.5, -0.5]);
        assert_eq!(
            cloud_sample_offsets(0.25, 0.5, 0.5, false),
            [-0.375, -0.375]
        );
    }

    #[test]
    fn cloud_offsets_remain_continuous_across_midnight() {
        assert_eq!(
            cloud_sample_offsets(0.875, 0.0, 0.5, true),
            [-0.9375, -0.9375]
        );
    }
}
