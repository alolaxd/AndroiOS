#include <metal_stdlib>
using namespace metal;

// Draws the guest framebuffer (an IOSurface-backed BGRA texture) into the
// aspect-fit rectangle computed on the CPU.

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct Viewport {
    float2 origin;   // NDC of the top-left corner
    float2 size;     // NDC extent (positive)
};

vertex VertexOut guest_vertex(uint vid [[vertex_id]], constant Viewport &vp [[buffer(0)]]) {
    const float2 corners[4] = { {0, 0}, {1, 0}, {0, 1}, {1, 1} };
    float2 c = corners[vid];
    VertexOut o;
    o.position = float4(vp.origin.x + c.x * vp.size.x, vp.origin.y - c.y * vp.size.y, 0, 1);
    o.uv = c;
    return o;
}

fragment float4 guest_fragment(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(tex.sample(s, in.uv).rgb, 1.0);
}
