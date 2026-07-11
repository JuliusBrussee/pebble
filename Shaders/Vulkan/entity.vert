#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inUV;
layout(location = 3) in float inPart;

layout(set = 0, binding = 1, std140) uniform EntityFrame { mat4 viewProj; } frame;
layout(set = 0, binding = 2, std140) uniform EntityParts { mat4 part[24]; } pose;
layout(push_constant) uniform EntityDraw {
    mat4 model;
    vec4 light;
    vec4 misc;
    vec4 overlay;
    vec4 fogColor;
} drawU;

layout(location = 0) out vec2 uv;
layout(location = 1) out vec3 normal;
layout(location = 2) out float fogDistance;

void main() {
    int partIndex = clamp(int(inPart + 0.5), 0, 23);
    mat4 localModel = drawU.model * pose.part[partIndex];
    vec4 position = localModel * vec4(inPosition, 1.0);
    gl_Position = frame.viewProj * position;
    uv = inUV;
    normal = mat3(localModel) * inNormal;
    fogDistance = length(position.xyz);
}
