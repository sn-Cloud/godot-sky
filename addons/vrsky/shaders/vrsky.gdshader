shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, fog_disabled;

// 该空间 Shader 保留给显式网格集成场景；标准 vrsky.tscn 使用
// vrsky_environment.gdshader 和 Environment.sky，不会创建近距离天空球。
uniform sampler2D sky_texture_a : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sky_texture_b : source_color, filter_linear_mipmap, repeat_enable;
uniform float blend_factor : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_uv_offset_a = 0.0;
uniform float cloud_uv_offset_b = 0.0;

uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 moon_direction = vec3(0.0, -1.0, 0.0);
uniform vec3 sun_color : source_color = vec3(1.0, 0.86, 0.62);
uniform vec3 moon_color : source_color = vec3(0.72, 0.80, 1.0);
uniform float sun_intensity : hint_range(0.0, 8.0) = 2.0;
uniform float moon_intensity : hint_range(0.0, 2.0) = 0.45;
uniform float sun_inner_cos = 0.99994;
uniform float sun_outer_cos = 0.99990;
uniform float moon_inner_cos = 0.99997;
uniform float moon_outer_cos = 0.99994;

varying vec3 local_direction;

const float SEAM_BLEND_WIDTH = 0.01;


vec3 sample_seamless_sky(sampler2D sky_texture, vec2 uv) {
    // 只环绕经度，并在左右边界的小范围内混合两侧采样以隐藏接缝。
    uv.x = fract(uv.x);
    if (uv.x >= SEAM_BLEND_WIDTH && uv.x <= 1.0 - SEAM_BLEND_WIDTH) {
        return texture(sky_texture, uv).rgb;
    }

    float seam_distance;
    if (uv.x < SEAM_BLEND_WIDTH) {
        seam_distance = uv.x + SEAM_BLEND_WIDTH;
    } else {
        seam_distance = uv.x - (1.0 - SEAM_BLEND_WIDTH);
    }

    vec3 right_strip = texture(
        sky_texture,
        vec2(1.0 - SEAM_BLEND_WIDTH + seam_distance * 0.5, uv.y)
    ).rgb;
    vec3 left_strip = texture(
        sky_texture,
        vec2(seam_distance * 0.5, uv.y)
    ).rgb;
    float seam_position = seam_distance / (2.0 * SEAM_BLEND_WIDTH);
    return mix(right_strip, left_strip, smoothstep(0.0, 1.0, seam_position));
}

void vertex() {
    // 移除模型视图矩阵中的平移，使天空网格视觉上始终位于无限远；
    // 强制最远深度则保证它不会遮挡场景中的真实几何体。
    local_direction = normalize(VERTEX);
    mat4 rotation_only = mat4(mat3(MODELVIEW_MATRIX));
    POSITION = PROJECTION_MATRIX * rotation_only * vec4(VERTEX, 1.0);
    POSITION.z = 0.0;
}

void fragment() {
    // 关键帧贴图先按统一云层相位采样，再做时间插值，避免云层双影。
    vec3 direction = normalize(local_direction);
    vec3 color = mix(
        sample_seamless_sky(sky_texture_a, UV + vec2(cloud_uv_offset_a, 0.0)),
        sample_seamless_sky(sky_texture_b, UV + vec2(cloud_uv_offset_b, 0.0)),
        blend_factor
    );
    // 解析天体圆盘独立于离线背景，方向由 VrSkyController 低频更新。
    float sun = smoothstep(
        sun_outer_cos,
        sun_inner_cos,
        dot(direction, sun_direction)
    );
    float moon = smoothstep(
        moon_outer_cos,
        moon_inner_cos,
        dot(direction, moon_direction)
    );
    color += sun_color * sun * sun_intensity;
    color += moon_color * moon * moon_intensity;
    ALBEDO = color;
}
