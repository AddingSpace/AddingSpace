#version 460
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec3 inNormal;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec3 inFactor;
layout(location = 3) in vec3 inLightVec;
layout(location = 4) in vec3 inViewVec;
layout(location = 5) flat in uint inInstanceIndex;

layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 0) uniform sampler2D textures[];

void main() {
    vec3 N = normalize(inNormal);
    vec3 L = normalize(inLightVec);
    vec3 V = normalize(inViewVec);
    vec3 H = normalize(L + V);

    float NdotL = max(dot(N, L), 0.0);
    float NdotH = max(dot(N, H), 0.0);

    vec3 ambient = vec3(0.15);
    vec3 diffuse = vec3(NdotL);
    vec3 specular = vec3(pow(NdotH, 32.0) * 0.5) * NdotL;

    vec3 texColor = texture(textures[0], inUV).rgb * inFactor;
    outColor = vec4((ambient + diffuse) * texColor + specular, 1.0);
}
