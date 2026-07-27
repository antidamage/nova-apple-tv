#include <metal_stdlib>
using namespace metal;

struct OrbVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct OrbGPUCommand {
    float4 meta;          // kind, blend, opacity, clip
    float4 geometry0;
    float4 geometry1;
    float4 geometry2;
    float4 geometry3;
    float4 stopPositions0;
    float4 stopPositions1;
    float4 color0;
    float4 color1;
    float4 color2;
    float4 color3;
    float4 color4;
    float4 color5;
    float4 color6;
    float4 color7;
    float4 points0;
    float4 points1;
    float4 points2;
    float4 points3;
    float4 points4;
    float4 points5;
    float4 points6;
    float4 points7;
};

struct OrbGPUUniforms {
    float4 viewport;       // width, height, radiusPixels, load
    float4 background;
    float4 accent;
    float4 highlight;
    float4 voiceGlow;
    float4 glass0;         // enabled, displacement, stretch, flipVertical
    float4 glass1;         // curve, smoothness, imageBlur, refractionOpacity
    float4 glass2;         // clarity, gloss, shadow, reflection
    float4 glass3;         // drift, commandCount, glowActive, hasTexture
    float4 background0;    // peak, falloff, warp, hueSpread
    float4 background1;    // apex, textureScale, uiScale, time
};

constexpr sampler orbTextureSampler(address::repeat, filter::linear);

vertex OrbVertexOut orbVertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0)
    };
    OrbVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = positions[vertexID] * 0.5 + 0.5;
    return out;
}

static float hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float3 hsvToRgbOrb(float3 c) {
    float4 k = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + k.xyz) * 6.0 - k.www);
    return c.z * mix(k.xxx, clamp(p - k.xxx, 0.0, 1.0), c.y);
}

static float3 rgbToHsvOrb(float3 c) {
    float4 k = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, k.wz), float4(c.gb, k.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

static float3 hueShiftOrb(float3 color, float amount) {
    float3 hsv = rgbToHsvOrb(max(color, float3(0.0)));
    hsv.x = fract(hsv.x + amount);
    return hsvToRgbOrb(hsv);
}

static float fluidPeak(float2 p, float2 center, float radius, float time, float seed, float warp, float falloff) {
    float2 warped = p;
    warped.x += sin(p.y * 4.4 + time * 0.18 + seed) * 0.056 * warp;
    warped.y += cos(p.x * 3.8 - time * 0.15 + seed * 1.7) * 0.048 * warp;
    float peak = smoothstep(radius, 0.0, length(warped - center));
    float ridge = 0.5 + 0.5 * sin(p.x * 7.0 + p.y * 5.0 + time * 0.22 + seed);
    return pow(peak, max(0.4, falloff)) * (0.70 + ridge * 0.45);
}

static float3 fluidBackground(float2 uv,
                              constant OrbGPUUniforms &u,
                              texture2d<float> mosaicTexture) {
    float aspect = max(1.0, u.viewport.x / max(1.0, u.viewport.y));
    float time = u.background1.w;
    if (u.glass3.w > 0.5) {
        float tileScale = max(0.25, u.background1.y) * max(0.001, u.background1.z);
        float2 tileUV = fract(float2(uv.x * aspect, uv.y) * tileScale);
        float3 map = mosaicTexture.sample(orbTextureSampler, tileUV).rgb;
        float grout = (1.0 - smoothstep(0.004, 0.025, max(map.r, map.g))) *
            smoothstep(0.965, 0.995, map.b);
        float2 offset = (map.rg * 2.0 - 1.0) * (1.0 - grout);
        uv += offset * float2(1.0 / aspect, 1.0) * (0.034 / max(0.001, u.background1.z));
    }
    float2 p = (uv - 0.5) * float2(aspect, 1.0);
    float3 color = u.background.rgb;
    const float seeds[4] = {0.0, 1.8, 3.4, 5.2};
    const float radii[4] = {0.48, 0.43, 0.46, 0.38};
    for (int i = 0; i < 4; ++i) {
        float seed = seeds[i];
        float2 center = float2(
            sin(time * 0.055 + seed) * 0.50 + sin(time * 0.019 + seed * 2.1) * 0.10,
            cos(time * 0.047 + seed * 1.3) * 0.31 + sin(time * 0.027 + seed) * 0.11
        );
        center.x *= aspect;
        float peak = fluidPeak(p, center, radii[i], time, seed, u.background0.z, u.background0.y);
        float apex = smoothstep(0.62, 1.0, peak);
        float pulse = 0.5 + 0.5 * sin(time * 0.12 + seed);
        float3 tint = mix(u.accent.rgb, u.highlight.rgb, pulse);
        float hue = (sin(seed * 12.9898 + time * 0.018) * 0.5 + sin(seed * 4.531) * 0.5) *
            0.11 * u.background0.w;
        tint = hueShiftOrb(tint, hue);
        color += tint * peak * (0.22 + pulse * 0.16) * u.background0.x;
        color += tint * apex * 0.18 * u.background1.x;
    }
    float vignette = smoothstep(0.34, 1.16, length(p));
    color = mix(color, u.background.rgb * 0.76, vignette * 0.42);
    return saturate(color);
}

static float4 commandColor(const device OrbGPUCommand &c, int index) {
    switch (index) {
        case 0: return c.color0;
        case 1: return c.color1;
        case 2: return c.color2;
        case 3: return c.color3;
        case 4: return c.color4;
        case 5: return c.color5;
        case 6: return c.color6;
        default: return c.color7;
    }
}

static float commandStop(const device OrbGPUCommand &c, int index) {
    return index < 4 ? c.stopPositions0[index] : c.stopPositions1[index - 4];
}

static float4 gradientColor(const device OrbGPUCommand &c, float at, int count) {
    count = clamp(count, 1, 8);
    float4 previous = commandColor(c, 0);
    float previousAt = commandStop(c, 0);
    if (at <= previousAt) return previous;
    for (int i = 1; i < count; ++i) {
        float nextAt = commandStop(c, i);
        float4 next = commandColor(c, i);
        if (at <= nextAt) {
            float amount = saturate((at - previousAt) / max(0.0001, nextAt - previousAt));
            return mix(previous, next, amount);
        }
        previous = next;
        previousAt = nextAt;
    }
    return previous;
}

static float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = saturate(dot(pa, ba) / max(0.000001, dot(ba, ba)));
    return length(pa - ba * h);
}

static float2 commandPoint(const device OrbGPUCommand &c, int index) {
    float4 packed;
    switch (index / 2) {
        case 0: packed = c.points0; break;
        case 1: packed = c.points1; break;
        case 2: packed = c.points2; break;
        case 3: packed = c.points3; break;
        case 4: packed = c.points4; break;
        case 5: packed = c.points5; break;
        case 6: packed = c.points6; break;
        default: packed = c.points7; break;
    }
    return (index & 1) == 0 ? packed.xy : packed.zw;
}

static float4 shadeCommand(const device OrbGPUCommand &c, float2 p, float aa, float time) {
    int kind = int(c.meta.x + 0.5);
    float distance = 1000.0;
    float4 color = c.color0;
    float fillAlpha = 0.0;
    float sourceWidth = aa * 2.0;
    bool solidShape = false;

    if (kind == 0) { // disc / ellipse
        solidShape = true;
        float2 center = c.geometry0.xy;
        float radius = max(0.0001, c.geometry0.z);
        float scaleY = max(0.01, c.geometry0.w);
        float rotation = c.geometry1.x * M_PI_F * 2.0;
        float2 q = p - center;
        float cs = cos(-rotation);
        float sn = sin(-rotation);
        q = float2(q.x * cs - q.y * sn, q.x * sn + q.y * cs);
        q.y /= scaleY;
        distance = length(q) - radius;
        float2 fromCenter = c.geometry1.yz;
        float fromRadius = c.geometry1.w;
        float2 toCenter = c.geometry2.xy;
        float toRadius = max(0.0001, c.geometry2.z);
        float at = saturate((length(p - toCenter) - fromRadius) / max(0.0001, toRadius - fromRadius));
        color = gradientColor(c, at, int(c.geometry3.x + 0.5));
    } else if (kind == 1) { // ring, optionally turbulent
        float radius = c.geometry0.x;
        float width = c.geometry0.y;
        sourceWidth = width;
        int fibers = clamp(int(c.geometry0.z + 0.5), 1, 12);
        float chaos = saturate(c.geometry0.w / 100.0);
        float weave = saturate(c.geometry1.x / 100.0);
        float speed = saturate(c.geometry1.y / 100.0);
        float breathe = saturate(c.geometry1.z / 100.0);
        float softness = saturate(c.geometry1.w / 100.0);
        float angle = atan2(p.y, p.x);
        float radial = length(p);
        distance = 1000.0;
        for (int fiber = 0; fiber < fibers; ++fiber) {
            float phase = float(fiber) * (0.7 + weave * 2.7);
            float noise = sin(angle * (5.0 + chaos * 13.0) + time * (0.25 + speed * 5.0) + phase);
            noise += 0.5 * sin(angle * (17.0 + weave * 19.0) - time * (0.4 + speed * 7.0) + phase * 1.9);
            float pulse = sin(time * (0.8 + speed * 3.0) + phase) * breathe * 0.045;
            float strandRadius = radius + pulse + noise * chaos * 0.075;
            distance = min(distance, abs(radial - strandRadius) - width * (0.5 + softness * 0.32));
        }
        color = c.color0;
    } else if (kind == 2) { // arc
        float radius = c.geometry0.x;
        float width = c.geometry0.y;
        sourceWidth = width;
        float from = c.geometry0.z;
        float to = c.geometry0.w;
        float angle = atan2(p.y, p.x) / (M_PI_F * 2.0);
        if (angle < 0) angle += 1.0;
        float sweep = to - from;
        if (sweep < 0) sweep += ceil(-sweep);
        float rel = angle - fract(from);
        if (rel < 0) rel += 1.0;
        float radialDistance = abs(length(p) - radius) - width * 0.5;
        float2 start = float2(cos(from * M_PI_F * 2.0), sin(from * M_PI_F * 2.0)) * radius;
        float2 end = float2(cos(to * M_PI_F * 2.0), sin(to * M_PI_F * 2.0)) * radius;
        distance = rel <= sweep ? radialDistance : min(length(p - start), length(p - end)) - width * 0.5;
        float at = saturate(rel / max(0.0001, sweep));
        if (c.geometry1.x > 0.5) at = 1.0 - at;
        color = gradientColor(c, at, int(c.geometry3.x + 0.5));
    } else if (kind == 3) { // line
        sourceWidth = c.geometry1.x;
        distance = sdSegment(p, c.geometry0.xy, c.geometry0.zw) - c.geometry1.x * 0.5;
        color = c.color0;
    } else if (kind == 4) { // polygon/polyline
        int count = clamp(int(c.geometry0.x + 0.5), 3, 16);
        bool filled = c.geometry0.y > 0.5;
        solidShape = filled;
        sourceWidth = c.geometry0.z;
        bool closed = c.geometry0.w > 0.5;
        bool inside = false;
        float edgeDistance = 1000.0;
        int edgeCount = closed ? count : count - 1;
        for (int i = 0; i < edgeCount; ++i) {
            float2 a = commandPoint(c, i);
            float2 b = commandPoint(c, (i + 1) % count);
            edgeDistance = min(edgeDistance, sdSegment(p, a, b));
            if (((a.y > p.y) != (b.y > p.y)) &&
                (p.x < (b.x - a.x) * (p.y - a.y) / max(0.000001, b.y - a.y) + a.x)) {
                inside = !inside;
            }
        }
        distance = filled ? (inside ? -edgeDistance : edgeDistance) : edgeDistance - c.geometry0.z * 0.5;
        color = c.color0;
    }

    float core = 1.0 - smoothstep(-aa, aa, distance);
    float glowRadius = max(0.0, c.geometry2.w);
    // Canvas shadowBlur is a normalized Gaussian convolution: a hairline with
    // a wide blur has a faint halo because the source energy is spread across
    // that radius. An unnormalised exponential tail makes dozens of additive
    // arc-field layers saturate into a solid disc (especially the Halo module).
    // Approximate the canvas result analytically from the signed-distance field,
    // including the source-width normalization for stroked primitives.
    float glowSigma = max(aa, glowRadius * 0.5);
    float glowEnergy = solidShape
        ? 0.5
        : saturate(sourceWidth / max(aa, glowSigma * 2.506628));
    float glow = glowRadius > 0.0001 && distance > 0
        ? exp(-0.5 * pow(distance / glowSigma, 2.0)) * glowEnergy
        : 0.0;
    fillAlpha = max(core, glow);
    if (c.meta.w > 0.5 && length(p) > 1.0) fillAlpha = 0.0;
    color.a *= fillAlpha * c.meta.z;
    color.rgb *= color.a;
    return color;
}

static float4 blendCommand(float4 dst, float4 src, int mode) {
    if (src.a <= 0.0001) return dst;
    if (mode == 1) { // additive / plus-lighter
        return min(float4(1.0), dst + src);
    }
    float3 dstStraight = dst.a > 0.0001 ? dst.rgb / dst.a : float3(0.0);
    float3 srcStraight = src.rgb / max(0.0001, src.a);
    float outAlpha = src.a + dst.a * (1.0 - src.a);
    float3 blended;
    if (mode == 2) {
        blended = 1.0 - (1.0 - dstStraight) * (1.0 - srcStraight);
    } else if (mode == 3) {
        blended = dstStraight * srcStraight;
    } else {
        return src + dst * (1.0 - src.a);
    }
    float3 outStraight = mix(dstStraight, blended, src.a);
    return float4(outStraight * outAlpha, outAlpha);
}

fragment float4 orbFragment(
    OrbVertexOut in [[stage_in]],
    constant OrbGPUUniforms &u [[buffer(0)]],
    const device OrbGPUCommand *commands [[buffer(1)]],
    texture2d<float> mosaicTexture [[texture(0)]]
) {
    float2 p = (in.uv - 0.5) / 0.48;
    float aa = 1.2 / max(1.0, u.viewport.z);
    float time = u.background1.w;
    float4 orb = float4(0.0);
    int commandCount = min(512, int(u.glass3.y + 0.5));
    for (int index = 0; index < commandCount; ++index) {
        float4 src = shadeCommand(commands[index], p, aa, time);
        orb = blendCommand(orb, src, int(commands[index].meta.y + 0.5));
    }

    float radius = length(p);
    // The dashboard canvas is circular at the compositor, so even deliberately
    // large layer glows stop at the orb rim. Preserve that contract here while
    // still allowing the separate glass shadow and voice halo below to extend.
    if (radius > 1.0) {
        orb = float4(0.0);
    }
    float glassEnabled = u.glass0.x;
    float4 result = orb;
    if (glassEnabled > 0.5 && radius <= 1.0) {
        float stretch = max(0.05, 1.0 + u.glass0.z);
        float2 lensP = p / stretch;
        if (u.glass0.w > 0.5) lensP.y *= -1.0;
        float q = 0.15 + 0.84 * u.glass1.x;
        float s = q * min(1.0, radius);
        float magnitude = saturate(s / sqrt(max(0.000001, 1.0 - s * s)));
        float rimWindow = smoothstep(0.0, 0.24, 1.0 - radius);
        float2 refracted = lensP + normalize(p + 0.00001) * magnitude * rimWindow * u.glass0.y * 0.11;
        float2 screenUV = 0.5 + refracted * 0.16;
        float blur = u.glass1.z * 0.004 + u.glass1.y * 0.002;
        float3 backdrop = float3(0.0);
        const float2 taps[5] = {
            float2(0.0), float2(1.0, 0.0), float2(-1.0, 0.0),
            float2(0.0, 1.0), float2(0.0, -1.0)
        };
        for (int i = 0; i < 5; ++i) {
            backdrop += fluidBackground(screenUV + taps[i] * blur, u, mosaicTexture);
        }
        backdrop /= 5.0;
        float clarityMask = smoothstep(u.glass2.x * 0.55, 0.45 + u.glass2.x * 0.45, radius);
        float orbOpacity = mix(1.0, 0.65, u.glass2.x) * clarityMask;
        float3 orbStraight = orb.a > 0.0001 ? orb.rgb / orb.a : float3(0.0);
        float3 glassColor = mix(backdrop, orbStraight, saturate(orb.a * orbOpacity));

        float reflectionBand = smoothstep(0.25, 0.95, radius) *
            saturate(0.5 + 0.5 * sin(atan2(p.y, p.x) * 2.0 - 0.9 + sin(time * 0.18) * u.glass3.x));
        glassColor += float3(0.78, 0.86, 1.0) * reflectionBand * u.glass2.w * 0.22;
        float gloss = pow(saturate(1.0 - length((p - float2(-0.34, -0.42)) * float2(0.72, 1.35))), 4.0);
        glassColor += gloss * u.glass2.y * 0.38;
        float lensAlpha = max(orb.a, 0.76 * u.glass1.w);
        result = float4(glassColor * lensAlpha, lensAlpha);
    }

    if (u.glass3.z > 0.5) {
        float glow = exp(-pow((radius - 1.12) / 0.13, 2.0)) * 0.52;
        float4 voice = float4(u.voiceGlow.rgb * glow, glow);
        voice.rgb *= voice.a;
        result = blendCommand(voice, result, 0);
    }

    if (glassEnabled > 0.5 && radius > 1.0) {
        float shadowDistance = radius - 1.0;
        float shadow = exp(-shadowDistance * (8.0 + (1.0 - u.glass2.z) * 12.0)) *
            u.glass2.z * 0.42;
        float4 cast = float4(0.0, 0.0, 0.0, shadow);
        result = blendCommand(cast, result, 0);
    }

    return result;
}
