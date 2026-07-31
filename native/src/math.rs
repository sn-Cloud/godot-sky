use std::f64::consts::TAU;

pub const MINUTES_PER_DAY: f64 = 1440.0;

pub fn normalize_minutes(minutes: f64) -> f64 {
    minutes.rem_euclid(MINUTES_PER_DAY)
}

pub fn equal_keyframe_pair(minutes: f64, frame_count: i64) -> (i64, i64, f64) {
    assert!(frame_count > 0);

    let normalized = normalize_minutes(minutes);
    let frame_length = MINUTES_PER_DAY / frame_count as f64;
    let position = normalized / frame_length;
    let current = position.floor() as i64;
    let next = (current + 1) % frame_count;
    let blend = position - current as f64;
    (current, next, blend)
}

pub fn sun_direction(minutes: f64, azimuth_offset_radians: f64) -> [f64; 3] {
    let phase = TAU * (normalize_minutes(minutes) / MINUTES_PER_DAY - 0.25);
    let x = phase.cos();
    let y = phase.sin();
    let z = 0.18;

    let cos_a = azimuth_offset_radians.cos();
    let sin_a = azimuth_offset_radians.sin();
    normalize3([x * cos_a + z * sin_a, y, -x * sin_a + z * cos_a])
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
    fn selects_wrapped_keyframes() {
        assert_eq!(equal_keyframe_pair(0.0, 12), (0, 1, 0.0));
        let pair = equal_keyframe_pair(1439.0, 12);
        assert_eq!(pair.0, 11);
        assert_eq!(pair.1, 0);
        assert!(pair.2 > 0.99);
    }

    #[test]
    fn noon_is_above_horizon() {
        let direction = sun_direction(720.0, 0.0);
        assert!(direction[1] > 0.98);
    }
}
