#version 450

layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 color;
layout(set = 0, binding = 2) uniform sampler2D uiTexture;
layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(uiTexture, uv) * color;
}
