shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

// Vertex COLOR: r = (depth + 2) / 12  [metres], g/b = flow direction (0.5 = still)
uniform sampler2D normal_tex : hint_normal, repeat_enable, filter_linear_mipmap;
uniform vec3 shallow_color : source_color = vec3(0.30, 0.72, 0.78);
uniform vec3 deep_color : source_color = vec3(0.03, 0.26, 0.44);
uniform vec3 foam_color : source_color = vec3(0.95, 0.98, 1.0);
uniform float flow_speed = 0.30;
uniform float normal_strength = 0.9;

varying vec3 v_wpos;

void vertex() {
    v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    float depth = COLOR.r * 12.0 - 2.0;
    vec2 flow = (COLOR.gb - vec2(0.5)) * 2.0;
    float t = TIME * flow_speed;
    vec2 uv1 = v_wpos.xz * 0.055 + flow * t + vec2(t * 0.04, 0.0);
    vec2 uv2 = v_wpos.xz * 0.13 - flow * t * 0.6 + vec2(0.0, t * 0.05);
    vec3 n1 = texture(normal_tex, uv1).rgb * 2.0 - 1.0;
    vec3 n2 = texture(normal_tex, uv2).rgb * 2.0 - 1.0;
    vec3 n = normalize(vec3((n1.xy + n2.xy) * normal_strength, 1.0));
    NORMAL_MAP = n * 0.5 + 0.5;
    float dd = clamp(depth / 3.0, 0.0, 1.0);
    vec3 col = mix(shallow_color, deep_color, smoothstep(0.0, 1.0, dd));
    float foam = (1.0 - smoothstep(0.0, 0.5, depth)) * (0.65 + 0.35 * sin(TIME * 2.0 + v_wpos.x * 0.8 + v_wpos.z * 0.6));
    col = mix(col, foam_color, clamp(foam, 0.0, 1.0) * 0.85);
    ALBEDO = col;
    ALPHA = clamp(smoothstep(-0.05, 0.4, depth) * 0.88 + foam * 0.12, 0.0, 0.93);
    ROUGHNESS = 0.06;
    METALLIC = 0.0;
    SPECULAR = 0.65;
}
