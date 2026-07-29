shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, fog_disabled;

uniform sampler2D sky_texture_a : source_color, filter_linear_mipmap;
uniform sampler2D sky_texture_b : source_color, filter_linear_mipmap;
uniform float blend_factor : hint_range(0.0, 1.0) = 0.0;

uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 moon_direction = vec3(0.0, -1.0, 0.0);
uniform vec3 sun_color : source_color = vec3(1.0, 0.86, 0.62);
uniform vec3 moon_color : source_color = vec3(0.72, 0.80, 1.0);
uniform float sun_intensity : hint_range(0.0, 8.0) = 2.0;
uniform float moon_intensity : hint_range(0.0, 2.0) = 0.45;
uniform float sun_radius = 0.0105;
uniform float moon_radius = 0.0080;

varying vec3 local_direction;

vec2 octahedral_uv(vec3 n) {
    n /= max(abs(n.x) + abs(n.y) + abs(n.z), 0.0001);
    vec2 p = n.xz;
    if (n.y < 0.0) {
        p = (1.0 - abs(p.yx)) * sign(p.xy);
    }
    return p * 0.5 + 0.5;
}

float disk_mask(vec3 direction, vec3 body_direction, float angular_radius) {
    float inner = cos(angular_radius);
    float outer = cos(angular_radius * 1.35);
    return smoothstep(outer, inner, dot(direction, body_direction));
}

void vertex() {
    local_direction = normalize(VERTEX);

    // Strip camera translation. The cube remains infinitely far away and does not
    // require a per-frame CPU transform update.
    mat4 rotation_only = mat4(mat3(MODELVIEW_MATRIX));
    POSITION = PROJECTION_MATRIX * rotation_only * vec4(VERTEX, 1.0);
    // Godot 4.3+ uses reversed-Z: clip-space Z=0 is the far plane.
    POSITION.z = 0.0;
}

void fragment() {
    vec3 direction = normalize(local_direction);
    vec2 uv = octahedral_uv(direction);

    vec3 color_a = texture(sky_texture_a, uv).rgb;
    vec3 color_b = texture(sky_texture_b, uv).rgb;
    vec3 color = mix(color_a, color_b, blend_factor);

    float sun = disk_mask(direction, normalize(sun_direction), sun_radius);
    float moon = disk_mask(direction, normalize(moon_direction), moon_radius);

    // The body disks are intentionally analytical: no ray marching, no atmosphere,
    // and no extra texture lookup for the sun or moon.
    color += sun_color * sun * sun_intensity;
    color += moon_color * moon * moon_intensity;

    ALBEDO = color;
}
