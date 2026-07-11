#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec2 inUV;
layout(location = 2) in uint inPackedA;
layout(location = 3) in uint inPackedB;

layout(set = 0, binding = 1, std140) uniform ChunkShared {
    mat4 viewProj;
    mat4 shadowMat;
    vec4 light;
    vec4 fog;
    vec4 fogColor;
    vec4 misc;
} sharedU;

layout(push_constant) uniform ChunkDraw { vec4 origin; vec4 render; } drawU;

layout(location = 0) out vec2 uv;
layout(location = 1) flat out uint packedA;
layout(location = 2) flat out uint packedB;
layout(location = 3) out vec3 shadowPosition;
layout(location = 4) out float fogDistance;

void main() {
    vec3 position = inPosition + drawU.origin.xyz;
    gl_Position = sharedU.viewProj * vec4(position, 1.0);
    vec4 shadowClip = sharedU.shadowMat * vec4(position, 1.0);
    shadowPosition = shadowClip.xyz / max(0.00001, shadowClip.w);
    uv = inUV;
    packedA = inPackedA;
    packedB = inPackedB;
    fogDistance = length(position);
}
