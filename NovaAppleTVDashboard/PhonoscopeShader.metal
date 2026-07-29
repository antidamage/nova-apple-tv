#include <metal_stdlib>
using namespace metal;

struct PhonoscopeParticle {
    float4 positionSize;
    float4 color;
    float4 meta;
};

struct PhonoscopeUniforms {
    float4 viewport;
    float4 boundsMin;
    float4 boundsMax;
    float4 signal;
};

struct PhonoscopeVertexOut {
    float4 position [[position]];
    float2 local;
    float4 color;
    float glow;
    float primitive;
    float material;
};

struct PhonoscopeFullscreenOut {
    float4 position [[position]];
    float2 uv;
};

struct PhonoscopeBloomUniforms {
    float2 texelStep;
    float intensity;
    float padding;
};

vertex PhonoscopeVertexOut phonoscope_vertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant PhonoscopeParticle *particles [[buffer(0)]],
    constant PhonoscopeUniforms &uniforms [[buffer(1)]]
) {
    constexpr float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    PhonoscopeParticle particle = particles[instanceID];
    float3 p = particle.positionSize.xyz;
    float is3D = uniforms.signal.z;
    if (is3D > 0.5) {
        float angle = uniforms.signal.x * 0.055;
        float c = cos(angle);
        float s = sin(angle);
        p.xz = float2(p.x * c - p.z * s, p.x * s + p.z * c);
        float depth = max(1.0, p.z + 3.2);
        p.xy /= depth * 0.62;
    } else {
        float2 center = (uniforms.boundsMin.xy + uniforms.boundsMax.xy) * 0.5;
        float2 extent = max(float2(0.0001), (uniforms.boundsMax.xy - uniforms.boundsMin.xy) * 0.5);
        p.xy = (p.xy - center) / extent;
    }
    float aspect = max(0.01, uniforms.viewport.x / max(1.0, uniforms.viewport.y));
    float2 offset = corners[vertexID] * particle.positionSize.w;
    offset.x /= aspect;

    PhonoscopeVertexOut out;
    out.position = float4(p.xy + offset, 0, 1);
    out.local = corners[vertexID];
    out.color = particle.color;
    out.glow = particle.meta.x;
    out.primitive = particle.meta.y;
    out.material = particle.meta.z;
    return out;
}

fragment float4 phonoscope_fragment(PhonoscopeVertexOut in [[stage_in]]) {
    float radius = length(in.local);
    float core;
    if (in.primitive < 0.5) {
        if (radius > 1.0) discard_fragment();
        core = smoothstep(1.0, 0.08, radius);
    } else if (in.primitive < 1.5) {
        if (radius > 1.0) discard_fragment();
        core = smoothstep(0.16, 0.02, abs(radius - 0.70));
    } else if (in.primitive < 2.5) {
        core = smoothstep(1.0, 0.78, max(abs(in.local.x), abs(in.local.y)));
    } else if (in.primitive < 3.5) {
        float edge = 1.0 - abs(in.local.x);
        if (in.local.y < -1.0 || in.local.y > edge * 2.0 - 1.0) discard_fragment();
        core = smoothstep(0.08, 0.22, min(in.local.y + 1.0, edge * 2.0 - 1.0 - in.local.y));
    } else if (in.primitive < 4.5) {
        float edge = max(abs(in.local.x), abs(in.local.y));
        core = smoothstep(0.15, 0.015, abs(edge - 0.82));
    } else {
        core = smoothstep(1.0, 0.1, abs(in.local.y)) * smoothstep(1.0, -0.8, in.local.x);
    }
    float halo = exp(-radius * radius * 3.2) * in.glow;
    float lighting = 1.0;
    if (in.material > 0.5 && in.material < 1.5 && radius <= 1.0) {
        float z = sqrt(max(0.0, 1.0 - radius * radius));
        lighting = 0.28 + 0.72 * max(0.0, dot(normalize(float3(in.local, z)), normalize(float3(-0.35, 0.45, 1.0))));
    }
    float alpha = clamp(in.color.a * (core + halo * 0.38), 0.0, 1.0);
    float3 rgb = in.color.rgb * (core * lighting + halo);
    return float4(rgb * alpha, alpha);
}

vertex PhonoscopeFullscreenOut phonoscope_fullscreen_vertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[3] = {
        float2(-1, -1),
        float2(3, -1),
        float2(-1, 3)
    };
    constexpr float2 texCoords[3] = {
        float2(0, 1),
        float2(2, 1),
        float2(0, -1)
    };
    PhonoscopeFullscreenOut out;
    out.position = float4(positions[vertexID], 0, 1);
    out.uv = texCoords[vertexID];
    return out;
}

fragment float4 phonoscope_bloom_extract(
    PhonoscopeFullscreenOut in [[stage_in]],
    texture2d<float> source [[texture(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 sample = source.sample(linearSampler, in.uv);
    float brightness = max(sample.r, max(sample.g, sample.b));
    float contribution = max(0.0, brightness - 0.16);
    return float4(sample.rgb * contribution * 1.45, contribution);
}

fragment float4 phonoscope_bloom_blur(
    PhonoscopeFullscreenOut in [[stage_in]],
    texture2d<float> source [[texture(0)]],
    constant PhonoscopeBloomUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 color = source.sample(linearSampler, in.uv) * 0.227027;
    color += source.sample(linearSampler, in.uv + uniforms.texelStep * 1.384615) * 0.316216;
    color += source.sample(linearSampler, in.uv - uniforms.texelStep * 1.384615) * 0.316216;
    color += source.sample(linearSampler, in.uv + uniforms.texelStep * 3.230769) * 0.070270;
    color += source.sample(linearSampler, in.uv - uniforms.texelStep * 3.230769) * 0.070270;
    return color;
}

fragment float4 phonoscope_composite(
    PhonoscopeFullscreenOut in [[stage_in]],
    texture2d<float> scene [[texture(0)]],
    texture2d<float> bloom [[texture(1)]],
    constant PhonoscopeBloomUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float4 base = scene.sample(linearSampler, in.uv);
    float4 glow = bloom.sample(linearSampler, in.uv) * uniforms.intensity;
    float3 color = clamp(base.rgb + glow.rgb, 0.0, 1.0);
    float alpha = clamp(max(base.a, max(glow.a, max(color.r, max(color.g, color.b)))), 0.0, 1.0);
    return float4(color, alpha);
}
