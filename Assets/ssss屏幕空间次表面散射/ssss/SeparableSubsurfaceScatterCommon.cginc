#ifndef SEPARABLE_SUBSURFACE_SCATTER_COMMON_INCLUDED
#define SEPARABLE_SUBSURFACE_SCATTER_COMMON_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

#define SSS_MAX_SAMPLES 25

TEXTURE2D_X(_SSSSSourceTex);
SAMPLER(sampler_SSSSSourceTex);

TEXTURE2D_X(_SSSOriginalTex);
SAMPLER(sampler_SSSOriginalTex);

CBUFFER_START(UnityPerMaterial)
float4 _Kernel[SSS_MAX_SAMPLES];
float _SSSScale;
float _SSSDepthEdgeFalloff;
float _SSSProjectionDistance;
int _SampleCount;
CBUFFER_END

float4 _SourceTexelSize;

struct Attributes
{
    uint vertexID : SV_VertexID;
};

struct Varyings
{
    float4 positionCS : SV_POSITION;
    float2 uv : TEXCOORD0;
};

Varyings Vert(Attributes input)
{
    Varyings output;
    output.positionCS = GetFullScreenTriangleVertexPosition(input.vertexID);
    output.uv = GetFullScreenTriangleTexCoord(input.vertexID);
    return output;
}

float4 SampleSource(float2 uv)
{
    return SAMPLE_TEXTURE2D_X(_SSSSSourceTex, sampler_SSSSSourceTex, uv);
}

float SceneLinearEyeDepth(float2 uv)
{
    float rawDepth = SampleSceneDepth(uv);
    return LinearEyeDepth(rawDepth, _ZBufferParams);
}

float4 ApplySSS(float4 centerColor, float2 uv, float2 axis)
{
    float centerDepth = SceneLinearEyeDepth(uv);
    float blurLength = _SSSProjectionDistance / max(centerDepth, 1.0e-4);
    float2 stepVector = axis * blurLength;
    float edgeScale = _SSSDepthEdgeFalloff * max(length(axis), 1.0e-6);
    float4 result = centerColor * _Kernel[0];
    int sampleCount = clamp(_SampleCount, 1, SSS_MAX_SAMPLES);

    [loop]
    for (int i = 1; i < SSS_MAX_SAMPLES; i++)
    {
        if (i >= sampleCount)
            break;

        float2 sampleUV = uv + stepVector * _Kernel[i].w;
        float4 sampleColor = SampleSource(sampleUV);
        float sampleDepth = SceneLinearEyeDepth(sampleUV);

        float depthDelta = abs(centerDepth - sampleDepth);
        float edgeFactor = saturate(depthDelta * edgeScale);
        sampleColor.rgb = lerp(sampleColor.rgb, centerColor.rgb, edgeFactor);

        result += sampleColor * _Kernel[i];
    }

    return result;
}

float4 FragX(Varyings input) : SV_Target
{
    float4 centerColor = SampleSource(input.uv);
    float2 axis = float2(_SourceTexelSize.x * _SSSScale, 0.0);
    return ApplySSS(centerColor, input.uv, axis);
}

float4 FragY(Varyings input) : SV_Target
{
    float4 centerColor = SampleSource(input.uv);
    float2 axis = float2(0.0, _SourceTexelSize.y * _SSSScale);
    return ApplySSS(centerColor, input.uv, axis);
}

float4 FragComposite(Varyings input) : SV_Target
{
    return SampleSource(input.uv);
}

float4 FragDebugStencil(Varyings input) : SV_Target
{
    float3 original = SAMPLE_TEXTURE2D_X(_SSSOriginalTex, sampler_SSSOriginalTex, input.uv).rgb;
    return float4(lerp(original, float3(1.0, 0.05, 0.45), 0.75), 1.0);
}

float4 FragDebugTint(Varyings input) : SV_Target
{
    return float4(1.0, 0.05, 0.45, 1.0);
}

#endif
