#version 450

layout(location = 0) in vec2 uv;
layout(location = 1) flat in uint packedA;
layout(location = 2) flat in uint packedB;
layout(location = 3) in vec3 shadowPosition;
layout(location = 4) in float fogDistance;

layout(set = 0, binding = 1, std140) uniform ChunkShared {
    mat4 viewProj;
    mat4 shadowMat;
    vec4 light;
    vec4 fog;
    vec4 fogColor;
    vec4 misc;
} sharedU;
layout(set = 0, binding = 3) uniform sampler2DArray atlasTexture;
layout(set = 0, binding = 4) uniform sampler2DShadow shadowTexture;
layout(push_constant) uniform ChunkDraw { vec4 origin; vec4 render; } drawU;

layout(location = 0) out vec4 outColor;

void main() {
    uint layer = packedA & 0xfffu;
    uint sky = (packedA >> 17u) & 0xfu;
    uint block = (packedA >> 21u) & 0xfu;
    uint tint = packedB & 0xffffffu;
    vec3 tintColor = vec3(float(tint & 255u), float((tint >> 8u) & 255u), float((tint >> 16u) & 255u)) / 255.0;
    vec4 texel = texture(atlasTexture, vec3(uv, float(layer)));
    if (texel.a < drawU.render.x) discard;
    float illumination = max(sharedU.light.z, max(float(sky), float(block)) / 15.0 * sharedU.light.x);
    float shadow = 1.0;
    if (sharedU.light.w > 0.5) {
        vec3 coordinate = shadowPosition * vec3(0.5, -0.5, 1.0) + vec3(0.5, 0.5, 0.0);
        shadow = mix(0.55, 1.0, texture(shadowTexture, coordinate));
    }
    vec3 lit = texel.rgb * tintColor * illumination * shadow;
    lit = pow(max(lit, vec3(0.0)), vec3(1.0 / max(0.1, sharedU.light.y)));
    float fogFactor = smoothstep(sharedU.fog.x, sharedU.fog.y, fogDistance);
    outColor = vec4(mix(lit, sharedU.fogColor.rgb, fogFactor), texel.a * drawU.render.y);
}
