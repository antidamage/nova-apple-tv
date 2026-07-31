#include <metal_stdlib>
using namespace metal;

struct PhonoscopeParticle {
    float4 positionSize;
    float4 color;
    float4 colorEnd;
    float4 glowColor;
    float4 glowColorEnd;
    float4 meta;
    float4 trail;
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
    float4 colorEnd;
    float4 glowColor;
    float4 glowColorEnd;
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
    float4 background;
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

    PhonoscopeVertexOut out;
    if (particle.meta.y > 5.5 && particle.trail.w > 0.0) {
        float2 delta = particle.trail.xy;
        if (is3D <= 0.5) {
            float2 extent = max(float2(0.0001), (uniforms.boundsMax.xy - uniforms.boundsMin.xy) * 0.5);
            delta /= extent;
        }
        float2 screenDelta = float2(delta.x * aspect, delta.y);
        float deltaLength = length(screenDelta);
        float2 screenDirection = deltaLength > 0.00001
            ? screenDelta / deltaLength
            : float2(1.0, 0.0);
        float2 clipNormal = float2(-screenDirection.y / aspect, screenDirection.x);
        float progress = (corners[vertexID].x + 1.0) * 0.5;
        float2 lineCenter = p.xy - delta * (1.0 - progress);
        out.position = float4(
            lineCenter + clipNormal * corners[vertexID].y * particle.positionSize.w,
            0,
            1
        );
    } else if (particle.meta.y > 4.5 && particle.trail.w > 0.0) {
        float2 direction = particle.trail.xy;
        if (is3D <= 0.5) {
            float2 extent = max(float2(0.0001), (uniforms.boundsMax.xy - uniforms.boundsMin.xy) * 0.5);
            direction /= extent;
        }
        float2 screenDirection = float2(direction.x * aspect, direction.y);
        float directionLength = length(screenDirection);
        screenDirection = directionLength > 0.00001
            ? screenDirection / directionLength
            : float2(1.0, 0.0);
        float2 clipDirection = float2(screenDirection.x / aspect, screenDirection.y);
        float2 clipNormal = float2(-screenDirection.y / aspect, screenDirection.x);
        float progress = (corners[vertexID].x + 1.0) * 0.5;
        float sourceRadius = particle.positionSize.w;
        float2 trailHead = p.xy - clipDirection * sourceRadius * 0.9;
        float2 trailTail = trailHead - clipDirection * sourceRadius * particle.trail.w;
        float2 trailCenter = mix(trailTail, trailHead, progress);
        float halfWidth = sourceRadius * progress;
        out.position = float4(
            trailCenter + clipNormal * corners[vertexID].y * halfWidth,
            0,
            1
        );
    } else {
        float2 offset = corners[vertexID] * particle.positionSize.w;
        offset.x /= aspect;
        out.position = float4(p.xy + offset, 0, 1);
    }
    out.local = corners[vertexID];
    out.color = particle.color;
    out.colorEnd = particle.colorEnd;
    out.glowColor = particle.glowColor;
    out.glowColorEnd = particle.glowColorEnd;
    out.glow = particle.meta.x;
    out.primitive = particle.meta.y;
    out.material = particle.meta.z;
    return out;
}

fragment float4 phonoscope_fragment(PhonoscopeVertexOut in [[stage_in]]) {
    float radius = length(in.local);
    float gradientProgress = clamp(radius, 0.0, 1.0);
    float core;
    float halo;
    if (in.primitive < 0.5) {
        if (radius > 1.0) discard_fragment();
        core = smoothstep(1.0, 0.08, radius);
        halo = exp(-radius * radius * 3.2) * in.glow;
    } else if (in.primitive < 1.5) {
        if (radius > 1.0) discard_fragment();
        core = smoothstep(0.16, 0.02, abs(radius - 0.70));
        halo = exp(-radius * radius * 3.2) * in.glow;
    } else if (in.primitive < 2.5) {
        core = smoothstep(1.0, 0.78, max(abs(in.local.x), abs(in.local.y)));
        halo = exp(-radius * radius * 3.2) * in.glow;
    } else if (in.primitive < 3.5) {
        float edge = 1.0 - abs(in.local.x);
        if (in.local.y < -1.0 || in.local.y > edge * 2.0 - 1.0) discard_fragment();
        core = smoothstep(0.08, 0.22, min(in.local.y + 1.0, edge * 2.0 - 1.0 - in.local.y));
        halo = exp(-radius * radius * 3.2) * in.glow;
    } else if (in.primitive < 4.5) {
        float edge = max(abs(in.local.x), abs(in.local.y));
        core = smoothstep(0.15, 0.015, abs(edge - 0.82));
        halo = exp(-radius * radius * 3.2) * in.glow;
    } else if (in.primitive < 5.5) {
        float progress = clamp((in.local.x + 1.0) * 0.5, 0.0, 1.0);
        // A trail starts at the dot (the quad's head at progress 1) and ends
        // at its tail, so Primary remains the start colour.
        gradientProgress = 1.0 - progress;
        float brightness = pow(progress, 1.45);
        core = smoothstep(1.0, 0.08, abs(in.local.y)) * brightness;
        halo = exp(-in.local.y * in.local.y * 3.2) * in.glow * brightness;
    } else {
        // Grid wires are emitted source-to-destination.
        gradientProgress = clamp((in.local.x + 1.0) * 0.5, 0.0, 1.0);
        // The wire is an alpha-shaped quad, so MSAA alone only smooths the
        // quad's geometry and cannot reliably soften this shader-defined
        // boundary. Convert one screen pixel into local coordinates with
        // fwidth and integrate coverage across that edge. This remains visible
        // when adaptive rendering drops the scene to a single sample.
        float signedEdgeDistance = 1.0 - abs(in.local.y);
        float edgePixelWidth = max(fwidth(in.local.y), 0.0001);
        core = smoothstep(
            -edgePixelWidth * 0.5,
            edgePixelWidth * 0.5,
            signedEdgeDistance
        );
        halo = 0.0;
    }
    float lighting = 1.0;
    if (in.material > 0.5 && in.material < 1.5 && radius <= 1.0) {
        float z = sqrt(max(0.0, 1.0 - radius * radius));
        lighting = 0.28 + 0.72 * max(0.0, dot(normalize(float3(in.local, z)), normalize(float3(-0.35, 0.45, 1.0))));
    }
    // All shader output is premultiplied because the Metal pipelines use
    // source-one blending. Slot opacity therefore affects both energy and
    // coverage without changing the selected hue.
    float4 coreColor = mix(in.color, in.colorEnd, gradientProgress);
    float4 glowColor = mix(in.glowColor, in.glowColorEnd, gradientProgress);
    float coreAlpha = coreColor.a * core;
    float glowAlpha = glowColor.a * halo * 0.38;
    float alpha = clamp(coreAlpha + glowAlpha, 0.0, 1.0);
    float3 rgb = coreColor.rgb * coreAlpha * lighting
        + glowColor.rgb * glowAlpha;
    return float4(rgb, alpha);
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
    float3 foreground = base.rgb + glow.rgb;
    float foregroundAlpha = clamp(max(base.a, glow.a), 0.0, 1.0);
    float backgroundAlpha = clamp(uniforms.background.a, 0.0, 1.0);
    float3 color = foreground
        + uniforms.background.rgb * backgroundAlpha * (1.0 - foregroundAlpha);
    float alpha = foregroundAlpha + backgroundAlpha * (1.0 - foregroundAlpha);
    return float4(clamp(color, 0.0, 1.0), clamp(alpha, 0.0, 1.0));
}
