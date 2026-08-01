shader_type sky;

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

const float QUEST_PI = 3.14159265358979323846;
const float SEAM_BLEND_WIDTH = 0.01;


vec2 equirectangular_uv(vec3 direction) {
    vec3 normalized_direction = normalize(direction);
    return vec2(
        atan(normalized_direction.z, normalized_direction.x) / (2.0 * QUEST_PI) + 0.5,
        acos(clamp(normalized_direction.y, -1.0, 1.0)) / QUEST_PI
    );
}


vec3 sample_seamless_sky(sampler2D sky_texture, vec2 uv) {
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


void sky() {
    vec3 direction = normalize(EYEDIR);
    vec2 uv = equirectangular_uv(direction);
    vec3 color = mix(
        sample_seamless_sky(sky_texture_a, uv + vec2(cloud_uv_offset_a, 0.0)),
        sample_seamless_sky(sky_texture_b, uv + vec2(cloud_uv_offset_b, 0.0)),
        blend_factor
    );
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
