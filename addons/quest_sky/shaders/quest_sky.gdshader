shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, fog_disabled;

uniform sampler2D sky_texture_a : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sky_texture_b : source_color, filter_linear_mipmap, repeat_enable;
uniform float blend_factor : hint_range(0.0, 1.0) = 0.0;

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

void vertex() {
    local_direction = normalize(VERTEX);
    mat4 rotation_only = mat4(mat3(MODELVIEW_MATRIX));
    POSITION = PROJECTION_MATRIX * rotation_only * vec4(VERTEX, 1.0);
    POSITION.z = 0.0;
}

void fragment() {
    vec3 direction = normalize(local_direction);
    vec3 color = mix(
        texture(sky_texture_a, UV).rgb,
        texture(sky_texture_b, UV).rgb,
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
    color += sun_color * sun * sun_intensity;
    color += moon_color * moon * moon_intensity;
    ALBEDO = color;
}
