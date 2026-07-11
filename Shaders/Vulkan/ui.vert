#version 450

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec4 inColor;
layout(push_constant) uniform UIUniforms { vec4 screen; } ui;
layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;

void main() {
    vec2 ndc = vec2(inPosition.x / ui.screen.x * 2.0 - 1.0,
                    1.0 - inPosition.y / ui.screen.y * 2.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    uv = inUV;
    color = inColor;
}
