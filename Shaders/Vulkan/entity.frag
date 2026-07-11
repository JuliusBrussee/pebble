#version 450

layout(location = 0) in vec2 uv;
layout(location = 1) in vec3 normal;
layout(location = 2) in float fogDistance;
layout(set = 0, binding = 0) uniform sampler2D skinTexture;
layout(push_constant) uniform EntityDraw {
    mat4 model;
    vec4 light;
    vec4 misc;
    vec4 overlay;
    vec4 fogColor;
} drawU;
layout(location = 0) out vec4 outColor;

void main() {
    vec4 texel = texture(skinTexture, uv);
    if (texel.a < 0.05) discard;
    float illumination = max(drawU.misc.x, max(drawU.light.x, drawU.light.y) * drawU.light.z);
    float shade = 0.62 + 0.38 * clamp(normalize(normal).y * 0.7 + 0.55, 0.0, 1.0);
    vec3 color = texel.rgb * illumination * shade;
    color = mix(color, drawU.overlay.rgb, drawU.overlay.a);
    float fog = smoothstep(drawU.misc.z, drawU.misc.w, fogDistance);
    color = mix(color, drawU.fogColor.rgb, fog);
    outColor = vec4(color, texel.a * drawU.misc.y);
}
