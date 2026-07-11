#version 450

layout(location = 0) in vec3 inPosition;
layout(set = 0, binding = 1, std140) uniform ChunkShared {
    mat4 viewProj;
    mat4 shadowMat;
    vec4 light;
    vec4 fog;
    vec4 fogColor;
    vec4 misc;
} sharedU;
layout(push_constant) uniform ChunkDraw { vec4 origin; vec4 render; } drawU;

void main() {
    gl_Position = sharedU.shadowMat * vec4(inPosition + drawU.origin.xyz, 1.0);
}
