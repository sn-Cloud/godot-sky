shader_type sky;

// 两张关键帧贴图与 blend_factor 构成时间轴的视觉插值端点。
// repeat_enable 允许经度方向环绕，mipmap 过滤用于压低 Quest 视野中的远处闪烁。
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

// 仅在经度接缝两侧各 1% 范围内交叉采样，避免扩大模糊区域。
const float SEAM_BLEND_WIDTH = 0.01;


vec3 sample_seamless_sky(sampler2D sky_texture, vec2 uv) {
    // 纬度不允许环绕；这里只规范化经度，防止极点上下互相污染。
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

    // 同时读取接缝左右两侧的窄条，并在跨缝坐标中连续混合。
    // 该修正只掩盖贴图边缘的小误差，不能替代真正连续的 2:1 美术资源。
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


void sky() {
    // EYEDIR 是每只眼睛独立的无穷远视线方向，用于天体圆盘的空间定位；
    // 直接使用 Environment.sky 可避免近距离天空球在 XR 中产生双目视差。
    vec3 direction = normalize(EYEDIR);
    // SKY_COORDS 是 Godot 为当前天空像素提供的全景 UV。使用它可保持离线烘焙贴图
    // 的半球朝向；若从 EYEDIR 再次推导纬度，XR 中会把烘焙全景上下颠倒。
    vec2 uv = SKY_COORDS;
    vec3 color = mix(
        sample_seamless_sky(sky_texture_a, uv + vec2(cloud_uv_offset_a, 0.0)),
        sample_seamless_sky(sky_texture_b, uv + vec2(cloud_uv_offset_b, 0.0)),
        blend_factor
    );
    // 太阳和月亮不烘焙进贴图，而是用方向点积生成解析圆盘，
    // 因而能够随设备时间连续移动，并保持八张关键帧之间的天体位置一致。
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
    COLOR = color
        + sun_color * sun * sun_intensity
        + moon_color * moon * moon_intensity;
}
