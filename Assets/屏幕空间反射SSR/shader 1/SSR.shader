Shader "Hidden/SSR"
{
    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
        }

        Cull Off
        ZWrite Off
        ZTest Always

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"
        #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

        TEXTURE2D_X(_SSRSourceTexture);
        TEXTURE2D_X(_HierarchicalZBufferTexture);

        CBUFFER_START(UnityPerMaterial)
            float4 _SourceSize;     // xy: pixels, zw: 1 / pixels
            float4 _SSRParams0;     // x: max distance, y: pixel stride, z: max steps, w: thickness
            float4 _SSRParams1;     // x: binary search count, y: intensity
            float4 _SSRParams2;     // x: ray bias, y: distance fade, z: edge fade, w: fresnel strength
            float4 _SSRBlurRadius;  // xy: blur radius in pixels
        CBUFFER_END

        float4 _HiZSourceSize; // xy: previous HiZ mip pixels, zw: 1 / pixels
        float _HierarchicalZBufferTextureFromMipLevel;
        float _MaxHierarchicalZBufferTextureMipLevel;

        half4 SampleSource(float2 uv)
        {
            return SAMPLE_TEXTURE2D_X_LOD(_SSRSourceTexture, sampler_LinearClamp, uv, 0.0);
        }

        half4 SampleBlit(float2 uv)
        {
            return SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, sampler_LinearClamp, uv, _BlitMipLevel);
        }

        bool IsSkyDepth(float rawDepth)
        {
        #if UNITY_REVERSED_Z
            return rawDepth <= 0.000001;
        #else
            return rawDepth >= 0.999999;
        #endif
        }

        void SwapFloat(inout float a, inout float b)
        {
            float t = a;
            a = b;
            b = t;
        }

        float Dither4x4(float2 pixel)
        {
            int x = (int)fmod(abs(pixel.x), 4.0);
            int y = (int)fmod(abs(pixel.y), 4.0);
            const float dither[16] = {
                0.0, 0.5, 0.125, 0.625,
                0.75, 0.25, 0.875, 0.375,
                0.1875, 0.6875, 0.0625, 0.5625,
                0.9375, 0.4375, 0.8125, 0.3125
            };
            return dither[y * 4 + x];
        }

        float SampleHierarchicalDepth(float2 uv, float mipLevel)
        {
            return SAMPLE_TEXTURE2D_X_LOD(_HierarchicalZBufferTexture, sampler_PointClamp, uv, mipLevel).r;
        }

        float4 ProjectViewToScreen(float3 positionVS)
        {
            float4 positionCS = mul(UNITY_MATRIX_P, float4(positionVS, 1.0));
            float invW = rcp(max(positionCS.w, 0.000001));
            float2 uv = positionCS.xy * invW;
            uv.y *= _ProjectionParams.x;
            uv = uv * 0.5 + 0.5;
            return float4(uv * _SourceSize.xy, positionCS.z, positionCS.w);
        }

        bool IsScreenPixelValid(float2 pixel)
        {
            return pixel.x >= 0.0 && pixel.y >= 0.0 && pixel.x <= _SourceSize.x && pixel.y <= _SourceSize.y;
        }

        float2 PixelToUV(float2 pixel)
        {
            return pixel * _SourceSize.zw;
        }

        float2 BinarySearchHitUV(float2 lowP, float3 lowQ, float lowK, float2 highP, float3 highQ, float highK, bool permute, int binaryCount)
        {
            float2 hitUV = PixelToUV(permute ? highP.yx : highP);

            UNITY_LOOP
            for (int i = 0; i < binaryCount; i++)
            {
                float2 midP = (lowP + highP) * 0.5;
                float3 midQ = (lowQ + highQ) * 0.5;
                float midK = (lowK + highK) * 0.5;
                float2 midPixel = permute ? midP.yx : midP;

                if (!IsScreenPixelValid(midPixel))
                {
                    highP = midP;
                    highQ = midQ;
                    highK = midK;
                    continue;
                }

                float2 midUV = PixelToUV(midPixel);
                float rawDepth = SampleSceneDepth(midUV);
                if (IsSkyDepth(rawDepth))
                {
                    lowP = midP;
                    lowQ = midQ;
                    lowK = midK;
                    continue;
                }

                float rayZ = midQ.z / midK;
                float sceneZ = -LinearEyeDepth(rawDepth, _ZBufferParams);

                if (rayZ <= sceneZ)
                {
                    highP = midP;
                    highQ = midQ;
                    highK = midK;
                    hitUV = midUV;
                }
                else
                {
                    lowP = midP;
                    lowQ = midQ;
                    lowK = midK;
                }
            }

            return hitUV;
        }

        half4 FragGenerateHiZ(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

            float2 uv = input.texcoord;
            float2 texel = _HiZSourceSize.zw;
            float4 depths = float4(
                SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, sampler_PointClamp, uv + texel * float2(-0.5, -0.5), _HierarchicalZBufferTextureFromMipLevel).r,
                SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, sampler_PointClamp, uv + texel * float2(-0.5, 0.5), _HierarchicalZBufferTextureFromMipLevel).r,
                SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, sampler_PointClamp, uv + texel * float2(0.5, -0.5), _HierarchicalZBufferTextureFromMipLevel).r,
                SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, sampler_PointClamp, uv + texel * float2(0.5, 0.5), _HierarchicalZBufferTextureFromMipLevel).r
            );

        #if UNITY_REVERSED_Z
            float depth = max(max(depths.x, depths.y), max(depths.z, depths.w));
        #else
            float depth = min(min(depths.x, depths.y), min(depths.z, depths.w));
        #endif

            return half4(depth, depth, depth, depth);
        }

        half4 FragRaymarching(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

            float2 uv = input.texcoord;
            float rawDepth = SampleSceneDepth(uv);
            if (IsSkyDepth(rawDepth))
                return half4(0.0, 0.0, 0.0, 0.0);

            float3 positionWS = ComputeWorldSpacePosition(uv, rawDepth, UNITY_MATRIX_I_VP);
            float3 normalWS = normalize(SampleSceneNormals(uv));
            float3 viewDirWS = normalize(positionWS - _WorldSpaceCameraPos);
            float3 rayDirWS = normalize(reflect(viewDirWS, normalWS));

            float3 startVS = TransformWorldToView(positionWS);
            float3 rayDirVS = normalize(TransformWorldToViewDir(rayDirWS));

            if (rayDirVS.z >= -0.0001)
                return half4(0.0, 0.0, 0.0, 0.0);

            float rayBias = max(_SSRParams2.x, 0.0);
            float maxDistance = max(_SSRParams0.x, 0.001);
            float stride = max(_SSRParams0.y, 1.0);
            float thickness = max(_SSRParams0.w, 0.001);
            float intensity = saturate(_SSRParams1.y);
            int stepCount = max(1, min(128, (int)_SSRParams0.z));
            int binaryCount = max(0, min(8, (int)_SSRParams1.x));

            startVS += rayDirVS * rayBias;
            float3 endVS = startVS + rayDirVS * maxDistance;

            float4 startScreen = ProjectViewToScreen(startVS);
            float4 endScreen = ProjectViewToScreen(endVS);

            float k0 = rcp(max(startScreen.w, 0.000001));
            float k1 = rcp(max(endScreen.w, 0.000001));
            float3 q0 = startVS * k0;
            float3 q1 = endVS * k1;

            float2 p0 = startScreen.xy;
            float2 p1 = endScreen.xy;
            float2 diff = p1 - p0;

            bool permute = abs(diff.x) < abs(diff.y);
            if (permute)
            {
                diff = diff.yx;
                p0 = p0.yx;
                p1 = p1.yx;
            }

            float dir = sign(diff.x);
            if (dir == 0.0)
                dir = 1.0;

            float invdx = dir / max(abs(diff.x), 0.000001);
            float2 dp = float2(dir, diff.y * invdx) * stride;
            float3 dq = (q1 - q0) * invdx * stride;
            float dk = (k1 - k0) * invdx * stride;

            float2 p = p0;
            float3 q = q0;
            float k = k0;
            float prevZ = startVS.z;
            float end = p1.x * dir;

            float jitter = 1.0;
        #if defined(_JITTER_ON)
            jitter = lerp(0.1, 1.0, Dither4x4(uv * _SourceSize.xy));
        #endif

            float mipLevel = 0.0;
            float maxMipLevel = max(0.0, _MaxHierarchicalZBufferTextureMipLevel);

            UNITY_LOOP
            for (int i = 0; i < stepCount && p.x * dir <= end; i++)
            {
                float stepScale = (i == 0) ? jitter : 1.0;
            #if defined(_HIZ_ON)
                stepScale *= exp2(mipLevel);
            #endif
                float2 prevP = p;
                float3 prevQ = q;
                float prevK = k;
                float previousRayZ = prevZ;

                p += dp * stepScale;
                q += dq * stepScale;
                k += dk * stepScale;

                float rayZMin = prevZ;
                float rayZMax = q.z / k;
                prevZ = rayZMax;
                if (rayZMin > rayZMax)
                    SwapFloat(rayZMin, rayZMax);

                float2 hitPixel = permute ? p.yx : p;
                if (!IsScreenPixelValid(hitPixel))
                    break;

                float2 hitUV = PixelToUV(hitPixel);
            #if defined(_HIZ_ON)
                float hitRawDepth = SampleHierarchicalDepth(hitUV, mipLevel);
            #else
                float hitRawDepth = SampleSceneDepth(hitUV);
            #endif
                if (IsSkyDepth(hitRawDepth))
                    continue;

                float sceneZ = -LinearEyeDepth(hitRawDepth, _ZBufferParams);
                bool isBehindSurface = rayZMin + rayBias <= sceneZ;
                bool intersectsSurface = isBehindSurface && rayZMax >= sceneZ - thickness;

            #if defined(_HIZ_ON)
                if (!isBehindSurface)
                {
                    mipLevel = min(mipLevel + 1.0, maxMipLevel);
                    continue;
                }

                if (mipLevel > 0.0)
                {
                    p = prevP;
                    q = prevQ;
                    k = prevK;
                    prevZ = previousRayZ;
                    mipLevel -= 1.0;
                    continue;
                }
            #endif

                if (intersectsSurface)
                {
                    float2 refinedUV = BinarySearchHitUV(prevP, prevQ, prevK, p, q, k, permute, binaryCount);

                    float edge = min(min(refinedUV.x, 1.0 - refinedUV.x), min(refinedUV.y, 1.0 - refinedUV.y));
                    float edgeFade = _SSRParams2.z <= 0.0 ? 1.0 : saturate(edge * _SSRParams2.z);
                    float distanceFade = exp2(-((float)i / max(1.0, (float)stepCount)) * _SSRParams2.y);
                    float fresnel = pow(1.0 - saturate(dot(normalWS, -viewDirWS)), 5.0);
                    float fresnelFade = lerp(1.0, fresnel, saturate(_SSRParams2.w));
                    float weight = saturate(intensity * edgeFade * distanceFade * fresnelFade);

                    return half4(SampleSource(refinedUV).rgb * weight, weight);
                }
            }

            return half4(0.0, 0.0, 0.0, 0.0);
        }

        half4 FragBlur(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

            float2 offset = _SSRBlurRadius.xy * _SourceSize.zw;
            half4 color = SampleBlit(input.texcoord) * 0.4026;
            color += SampleBlit(input.texcoord + offset * 1.3846) * 0.2442;
            color += SampleBlit(input.texcoord - offset * 1.3846) * 0.2442;
            color += SampleBlit(input.texcoord + offset * 3.2308) * 0.0545;
            color += SampleBlit(input.texcoord - offset * 3.2308) * 0.0545;
            return color;
        }

        half4 FragAdditive(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

            half4 source = SampleSource(input.texcoord);
            half4 reflection = SampleBlit(input.texcoord);
            return half4(source.rgb + reflection.rgb, source.a);
        }

        half4 FragBalance(Varyings input) : SV_Target
        {
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

            half4 source = SampleSource(input.texcoord);
            half4 reflection = SampleBlit(input.texcoord);
            return half4(source.rgb * (1.0 - saturate(reflection.a)) + reflection.rgb, source.a);
        }
        ENDHLSL

        Pass
        {
            Name "Generate HiZ"

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragGenerateHiZ
            ENDHLSL
        }

        Pass
        {
            Name "Raymarching"

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragRaymarching
            #pragma shader_feature_local_fragment _JITTER_ON
            #pragma shader_feature_local_fragment _HIZ_ON
            ENDHLSL
        }

        Pass
        {
            Name "Blur"

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragBlur
            ENDHLSL
        }

        Pass
        {
            Name "Additive"

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragAdditive
            ENDHLSL
        }

        Pass
        {
            Name "Balance"

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragBalance
            ENDHLSL
        }
    }
}
