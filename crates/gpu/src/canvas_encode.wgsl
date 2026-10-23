@group(0) @binding(0) var acc: texture_2d<f32>;
@group(0) @binding(1) var<uniform> offset: vec4<i32>; // x, y, encode sRGB, keep values above 1.0

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    let uv = vec2(f32((vi << 1u) & 2u), f32(vi & 2u));
    return vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
}

fn srgb_encode(c: vec3<f32>) -> vec3<f32> {
    return select(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, c <= vec3(0.0031308));
}

@fragment
fn fs(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let c = textureLoad(acc, vec2<i32>(floor(pos.xy)) - offset.xy, 0);
    let a = clamp(c.a, 0.0, 1.0);
    var rgb = max(c.rgb, vec3(0.0));
    if (offset.w == 0) {
        rgb = min(rgb, vec3(1.0));
    }
    if (offset.z != 0) {
        // Linear composite: store its sRGB encoding (8-bit precision where it matters).
        rgb = srgb_encode(rgb);
    }
    return vec4(rgb * a, a);
}
