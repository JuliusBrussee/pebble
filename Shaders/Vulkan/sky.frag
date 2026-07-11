#version 450

layout(location = 0) in vec2 uv;
layout(push_constant) uniform SkyFrame {
    vec4 fogColor;
    vec4 lightTime;
    vec4 dimension;
} frame;
layout(location = 0) out vec4 outColor;

void main() {
    float day = clamp(frame.lightTime.x, 0.0, 1.0);
    float dimension = frame.dimension.y;
    float horizon = clamp(1.0 - abs(uv.y - 0.48) * 1.8, 0.0, 1.0);
    vec3 zenith = mix(vec3(0.008, 0.012, 0.035), vec3(0.18, 0.43, 0.82), day);
    vec3 sky = mix(zenith, frame.fogColor.rgb * 1.08, horizon);
    if (dimension > 0.5 && dimension < 1.5) {
        sky = mix(vec3(0.08, 0.012, 0.008), frame.fogColor.rgb, horizon * 0.45);
        day = 0.45;
    } else if (dimension >= 1.5) {
        sky = mix(vec3(0.012, 0.006, 0.026), frame.fogColor.rgb, horizon * 0.3);
        day = 0.18;
    }
    float angle = frame.lightTime.y * 0.006;
    vec2 sunPosition = vec2(0.5 + cos(angle) * 0.34, 0.52 - sin(angle) * 0.34);
    float sun = smoothstep(0.04, 0.0, distance(uv, sunPosition));
    sky += vec3(1.0, 0.72, 0.38) * sun * day * step(dimension, 0.5);
    float stars = step(0.997, fract(sin(dot(floor(uv * vec2(480, 270)), vec2(12.9898, 78.233))) * 43758.5453));
    sky += vec3(stars * (1.0 - day) * 0.72);
    if (frame.dimension.x > 0.5 && dimension < 0.5) {
        vec2 cloudCell = floor((uv + vec2(frame.lightTime.y * 0.002, 0.0)) * vec2(34.0, 18.0));
        float cloudNoise = fract(sin(dot(cloudCell, vec2(127.1, 311.7))) * 43758.5453);
        float cloudBand = smoothstep(0.22, 0.38, uv.y) * (1.0 - smoothstep(0.68, 0.82, uv.y));
        float cloud = smoothstep(0.58, 0.78, cloudNoise) * cloudBand;
        sky = mix(sky, mix(vec3(0.3), vec3(0.96), day), cloud * 0.72);
    }
    if (frame.dimension.z > 0.5) {
        sky = mix(sky, vec3(dot(sky, vec3(0.28, 0.48, 0.24))) * vec3(0.72, 0.78, 0.86), 0.38);
    }
    outColor = vec4(sky, 1.0);
}
