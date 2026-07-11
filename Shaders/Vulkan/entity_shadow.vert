#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 3) in float inPart;
layout(set = 0, binding = 1, std140) uniform EntityFrame {
    mat4 viewProj;
    mat4 shadowMat;
} frame;
layout(set = 0, binding = 2, std140) uniform EntityParts { mat4 part[24]; } pose;
layout(push_constant) uniform EntityDraw {
    mat4 model;
    vec4 light;
    vec4 misc;
    vec4 overlay;
    vec4 fogColor;
} drawU;

void main() {
    int partIndex = clamp(int(inPart + 0.5), 0, 23);
    gl_Position = frame.shadowMat * drawU.model * pose.part[partIndex] * vec4(inPosition, 1.0);
}
