@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;

struct V { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> };

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> V {
    let uv = vec2(f32((vi << 1u) & 2u), f32(vi & 2u));
    return V(vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0), uv);
}

@fragment
fn fs(in: V) -> @location(0) vec4<f32> {
    // A bilinear tap at the destination texel centre averages the 2×2 source block.
    return textureSampleLevel(src, samp, in.uv, 0.0);
}
