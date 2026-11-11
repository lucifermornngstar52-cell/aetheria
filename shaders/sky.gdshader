shader_type sky;

// Stylised anime sky: gradient + sun + layered procedural clouds + stars. No TIME use (cheap radiance update).
uniform vec3 sun_dir = vec3(0.3, 0.7, 0.2);
uniform vec3 zenith_color : source_color = vec3(0.22, 0.45, 0.85);
uniform vec3 horizon_color : source_color = vec3(0.72, 0.84, 0.95);
uniform vec3 ground_color : source_color = vec3(0.35, 0.40, 0.35);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.8);
uniform vec3 cloud_light : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shade : source_color = vec3(0.58, 0.65, 0.80);
uniform float cloud_cover = 0.55;
uniform vec2 cloud_offset = vec2(0.0);
uniform float stars = 0.0;
uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;

float cloud_density(vec2 uv, float lod) {
    float n = textureLod(noise_tex, uv, lod).r * 0.62 + textureLod(noise_tex, uv * 2.3 + vec2(0.37, 0.71), lod).r * 0.28 + textureLod(noise_tex, uv * 5.1 + vec2(0.13, 0.53), lod).r * 0.10;
    return smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.26, n);
}

void sky() {
    vec3 dir = normalize(EYEDIR);
    float h = dir.y;
    vec3 col = mix(horizon_color, zenith_color, pow(clamp(h, 0.0, 1.0), 0.5));
    col = mix(col, ground_color, smoothstep(0.0, -0.2, h));
    vec3 sd = normalize(sun_dir);
    float sdot = max(dot(dir, sd), 0.0);
    col += sun_color * (pow(sdot, 1200.0) * 8.0 + pow(sdot, 14.0) * 0.16);
    if (!AT_CUBEMAP_PASS && h > 0.0) {
        float lod = (1.0 - h) * 3.5;
        vec2 uv = dir.xz / (h + 0.2) * 0.42 + cloud_offset;
        float d = cloud_density(uv, lod);
        float d2 = cloud_density(uv + sd.xz * 0.018, lod);
        float lit = clamp(0.62 + (d - d2) * 2.4, 0.0, 1.0);
        vec3 ccol = mix(cloud_shade, cloud_light, lit);
        ccol += sun_color * pow(sdot, 6.0) * 0.18 * d;
        col = mix(col, ccol, d * smoothstep(0.0, 0.14, h) * 0.93);
        vec3 q = floor(dir * 170.0);
        float hs = fract(sin(dot(q, vec3(127.1, 311.7, 74.7))) * 43758.5453);
        col += vec3(1.0) * step(0.9972, hs) * stars * smoothstep(0.02, 0.2, h) * (1.0 - d);
    }
    COLOR = col;
}
