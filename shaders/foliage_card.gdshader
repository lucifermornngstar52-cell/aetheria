shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

// Alpha-cut foliage cards (leaves, blossoms, needles, ferns) with wind sway and cheap translucency.
uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float sway_amount = 0.08;
uniform float sway_speed = 1.2;
uniform float height_ref = 11.0;
uniform float alpha_cut = 0.42;
uniform float translucency = 0.30;

varying vec4 v_col;

void vertex() {
    vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    float m = smoothstep(1.0, height_ref, VERTEX.y);
    float t = TIME * sway_speed;
    VERTEX.x += sin(t + wp.x * 0.30 + wp.z * 0.20) * sway_amount * m;
    VERTEX.z += cos(t * 0.87 + wp.z * 0.27 + wp.x * 0.13) * sway_amount * m * 0.7;
    v_col = COLOR;
}

void fragment() {
    vec4 tx = texture(tex, UV);
    ALBEDO = tx.rgb * v_col.rgb;
    ALPHA = tx.a;
    ALPHA_SCISSOR_THRESHOLD = alpha_cut;
    ROUGHNESS = 0.85;
    METALLIC = 0.0;
    BACKLIGHT = ALBEDO * translucency;
}
