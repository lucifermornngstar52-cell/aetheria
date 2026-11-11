shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

// Leaves / grass: vertex COLOR.rgb = tint (x instance tint), COLOR.a = wind sway mask.
uniform sampler2D tex : source_color, repeat_enable, filter_linear_mipmap;
uniform float tex_scale = 0.5;
uniform float sway_amount = 0.12;
uniform float sway_speed = 1.25;

varying vec4 v_col;

void vertex() {
    vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    float m = COLOR.a;
    float t = TIME * sway_speed;
    VERTEX.x += sin(t + wp.x * 0.30 + wp.z * 0.20) * sway_amount * m;
    VERTEX.z += cos(t * 0.87 + wp.z * 0.27 + wp.x * 0.13) * sway_amount * m * 0.7;
    v_col = COLOR;
}

void fragment() {
    vec3 tx = texture(tex, UV * tex_scale).rgb;
    ALBEDO = v_col.rgb * tx;
    ROUGHNESS = 0.92;
    METALLIC = 0.0;
}
