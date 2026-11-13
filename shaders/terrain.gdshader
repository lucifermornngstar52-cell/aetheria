shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

// Splat terrain: vertex COLOR = weights (grass, dirt, rock, sand), UV.x = cobble weight.
// Normal detail is added as a world-space bump (no tangents needed).
uniform sampler2D tex_grass : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_dirt : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_rock : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_sand : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_cobble : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_dirt_n : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D tex_rock_n : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D tex_cobble_n : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D tex_noise : repeat_enable, filter_linear_mipmap;
uniform float grass_scale = 0.21;
uniform float dirt_scale = 0.19;
uniform float rock_scale = 0.12;
uniform float sand_scale = 0.2;
uniform float cobble_scale = 0.33;
uniform float bump_strength = 0.9;
uniform float snow_start = 150.0;
uniform float snow_end = 185.0;
uniform vec3 snow_color : source_color = vec3(0.93, 0.95, 0.98);
uniform vec3 grass_tint : source_color = vec3(1.0, 1.0, 1.0);

varying vec3 v_wpos;
varying vec3 v_wnrm;

void vertex() {
    v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
    vec4 w = COLOR;
    float cob = clamp(UV.x, 0.0, 1.0);
    vec2 p = v_wpos.xz;
    float macro = texture(tex_noise, p * 0.0027).r;
    vec3 g = mix(texture(tex_grass, p * grass_scale).rgb, texture(tex_grass, p * grass_scale * 0.23 + vec2(0.37, 0.11)).rgb, 0.45);
    g *= mix(0.84, 1.18, macro) * grass_tint;
    g = mix(g, g * vec3(1.14, 1.05, 0.78), smoothstep(0.55, 0.85, macro));
    vec3 d = texture(tex_dirt, p * dirt_scale).rgb;
    vec2 side_uv = abs(v_wnrm.x) > abs(v_wnrm.z) ? v_wpos.zy : v_wpos.xy;
    float steep = 1.0 - clamp(v_wnrm.y, 0.0, 1.0);
    float sidew = smoothstep(0.35, 0.6, steep);
    vec3 r = texture(tex_rock, mix(p, side_uv, sidew) * rock_scale).rgb;
    vec3 s = texture(tex_sand, p * sand_scale).rgb;
    vec3 col = g * w.r + d * w.g + r * w.b + s * w.a;
    if (cob > 0.01) {
        vec3 c = texture(tex_cobble, p * cobble_scale).rgb;
        col = mix(col, c * vec3(0.98, 0.96, 0.92), cob);
    }
    float snow = smoothstep(snow_start, snow_end, v_wpos.y + (macro - 0.5) * 40.0) * smoothstep(0.55, 0.85, v_wnrm.y);
    col = mix(col, snow_color, snow);
    vec3 nd = texture(tex_dirt_n, p * dirt_scale).rgb * 2.0 - 1.0;
    vec3 nr = texture(tex_rock_n, p * rock_scale).rgb * 2.0 - 1.0;
    vec3 nc = texture(tex_cobble_n, p * cobble_scale).rgb * 2.0 - 1.0;
    vec2 bump = nd.xy * w.g * 0.7 + nr.xy * w.b * (1.0 - sidew) + nc.xy * cob;
    vec3 nw = normalize(v_wnrm + vec3(bump.x, 0.0, -bump.y) * bump_strength);
    NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
    ALBEDO = col;
    ROUGHNESS = 1.0;
    METALLIC = 0.0;
}
