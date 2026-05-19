Shader "Custom/StencilSurface"
{
    Properties
    {
        [MainColor] _Color ("Color", Color) = (1,1,1,1)
        [MainTexture] _MainTex ("Albedo", 2D) = "white" {}

        _Glossiness ("Smoothness", Range(0.0, 1.0)) = 0.5
        _GlossMapScale ("Smoothness Scale", Range(0.0, 1.0)) = 1.0
        [Enum(Metallic Alpha,0,Albedo Alpha,1)] _SmoothnessTextureChannel ("Smoothness texture channel", Float) = 0

        [Toggle(_NORMALMAP)] _UseNormalMap ("Use Normal Map", Float) = 0
        _BumpScale ("Normal Scale", Float) = 1.0
        _BumpMap ("Normal Map", 2D) = "bump" {}

        _OcclusionStrength ("Occlusion Strength", Range(0.0, 1.0)) = 1.0
        _OcclusionMap ("Occlusion", 2D) = "white" {}

        [Header(Specular Split)]
        _SpecularStrength ("Specular Strength", Range(0.0, 2.0)) = 1.0
        _IndirectSpecularStrength ("Indirect Specular Strength", Range(0.0, 2.0)) = 1.0

        [Header(Translucency)]
        [Toggle] _TranslucencyEnabled ("Use Translucency", Float) = 1.0
        _ThicknessMap ("Thickness Map", 2D) = "white" {}
        _ThicknessMapWeight ("Thickness Map Weight", Range(0.0, 1.0)) = 0.0
        _ThicknessScale ("Thickness Scale", Range(0.0, 2.0)) = 1.0
        _ThicknessBias ("Thickness Bias", Range(-1.0, 1.0)) = 0.0
        _TranslucencyColor ("Translucency Color", Color) = (1.0, 0.35, 0.22, 1.0)
        _TranslucencyStrength ("Translucency Strength", Range(0.0, 4.0)) = 0.65
        _TranslucencyProfileScale ("Profile Distance Scale", Range(0.001, 2.0)) = 0.35
        _TranslucencyPower ("Translucency Power", Range(0.5, 12.0)) = 3.0
        _TranslucencyDistortion ("Translucency Distortion", Range(0.0, 1.0)) = 0.35
        _TranslucencyShadowWeight ("Shadow Weight", Range(0.0, 1.0)) = 0.55
        _TranslucencyViewWeight ("View Weight", Range(0.0, 1.0)) = 0.65
        _TranslucencyWrap ("Backlight Wrap", Range(0.0, 1.0)) = 0.3

        _StencilRef ("Stencil Reference", Int) = 5
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "RenderType" = "Opaque"
            "Queue" = "Geometry"
        }

        LOD 300

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

        TEXTURE2D(_MainTex);
        SAMPLER(sampler_MainTex);
        TEXTURE2D(_BumpMap);
        SAMPLER(sampler_BumpMap);
        TEXTURE2D(_OcclusionMap);
        SAMPLER(sampler_OcclusionMap);
        TEXTURE2D(_ThicknessMap);
        SAMPLER(sampler_ThicknessMap);

        CBUFFER_START(UnityPerMaterial)
        float4 _MainTex_ST;
        float4 _BumpMap_ST;
        float4 _OcclusionMap_ST;
        half4 _Color;
        half4 _TranslucencyColor;
        half _Glossiness;
        half _GlossMapScale;
        half _BumpScale;
        half _OcclusionStrength;
        half _SpecularStrength;
        half _IndirectSpecularStrength;
        half _TranslucencyEnabled;
        half _ThicknessMapWeight;
        half _ThicknessScale;
        half _ThicknessBias;
        half _TranslucencyStrength;
        half _TranslucencyProfileScale;
        half _TranslucencyPower;
        half _TranslucencyDistortion;
        half _TranslucencyShadowWeight;
        half _TranslucencyViewWeight;
        half _TranslucencyWrap;
        CBUFFER_END

        struct Attributes
        {
            float4 positionOS : POSITION;
            float3 normalOS : NORMAL;
            float4 tangentOS : TANGENT;
            float2 uv : TEXCOORD0;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        struct Varyings
        {
            float4 positionCS : SV_POSITION;
            float3 positionWS : TEXCOORD0;
            half3 normalWS : TEXCOORD1;
            half4 tangentWS : TEXCOORD2;
            float2 uv : TEXCOORD3;
            float fogFactor : TEXCOORD4;
            float4 shadowCoord : TEXCOORD5;
            UNITY_VERTEX_INPUT_INSTANCE_ID
            UNITY_VERTEX_OUTPUT_STEREO
        };

        struct SkinSurfaceData
        {
            half3 albedo;
            half alpha;
            half3 normalWS;
            half occlusion;
            half smoothness;
        };

        half3 UnpackNormalScaleSafe(half4 packedNormal, half scale)
        {
            half3 normalTS;
            packedNormal.x *= packedNormal.w;
            normalTS.xy = packedNormal.xy * 2.0h - 1.0h;
            normalTS.xy *= scale;
            normalTS.z = sqrt(saturate(1.0h - dot(normalTS.xy, normalTS.xy)));
            return normalTS;
        }

        Varyings Vert(Attributes input)
        {
            Varyings output;
            UNITY_SETUP_INSTANCE_ID(input);
            UNITY_TRANSFER_INSTANCE_ID(input, output);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

            VertexPositionInputs positionInputs = GetVertexPositionInputs(input.positionOS.xyz);
            VertexNormalInputs normalInputs = GetVertexNormalInputs(input.normalOS, input.tangentOS);

            output.positionCS = positionInputs.positionCS;
            output.positionWS = positionInputs.positionWS;
            output.normalWS = NormalizeNormalPerVertex(normalInputs.normalWS);
            output.tangentWS = half4(NormalizeNormalPerVertex(normalInputs.tangentWS), input.tangentOS.w);
            output.uv = TRANSFORM_TEX(input.uv, _MainTex);
            output.fogFactor = ComputeFogFactor(output.positionCS.z);
            output.shadowCoord = TransformWorldToShadowCoord(output.positionWS);
            return output;
        }

        SkinSurfaceData SampleSkinSurface(Varyings input)
        {
            SkinSurfaceData surface;

            half4 baseSample = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv);
            surface.albedo = baseSample.rgb * _Color.rgb;
            surface.alpha = baseSample.a * _Color.a;

            surface.normalWS = NormalizeNormalPerPixel(input.normalWS);
            #if defined(_NORMALMAP)
                half3 normalTS = UnpackNormalScaleSafe(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, input.uv), _BumpScale);
                half3 bitangentWS = cross(input.normalWS, input.tangentWS.xyz) * input.tangentWS.w * GetOddNegativeScale();
                half3x3 tangentToWorld = half3x3(input.tangentWS.xyz, bitangentWS, input.normalWS);
                surface.normalWS = NormalizeNormalPerPixel(TransformTangentToWorld(normalTS, tangentToWorld));
            #endif

            half occlusionSample = SAMPLE_TEXTURE2D(_OcclusionMap, sampler_OcclusionMap, input.uv).r;
            surface.occlusion = lerp(1.0h, occlusionSample, _OcclusionStrength);
            surface.smoothness = saturate(_Glossiness * _GlossMapScale);
            return surface;
        }

        InputData BuildInputData(Varyings input, half3 normalWS)
        {
            InputData inputData = (InputData)0;
            inputData.positionWS = input.positionWS;
            inputData.normalWS = normalWS;
            inputData.viewDirectionWS = GetWorldSpaceNormalizeViewDir(input.positionWS);
            inputData.shadowCoord = input.shadowCoord;
            inputData.fogCoord = input.fogFactor;
            inputData.vertexLighting = VertexLighting(input.positionWS, normalWS);
            inputData.bakedGI = SampleSH(normalWS);
            inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(input.positionCS);
            inputData.shadowMask = half4(1.0h, 1.0h, 1.0h, 1.0h);
            return inputData;
        }

        SurfaceData BuildUniversalSurfaceData(SkinSurfaceData skin)
        {
            SurfaceData surfaceData = (SurfaceData)0;
            surfaceData.albedo = skin.albedo;
            surfaceData.specular = half3(0.0h, 0.0h, 0.0h);
            surfaceData.metallic = 0.0h;
            surfaceData.smoothness = skin.smoothness;
            surfaceData.normalTS = half3(0.0h, 0.0h, 1.0h);
            surfaceData.emission = half3(0.0h, 0.0h, 0.0h);
            surfaceData.occlusion = skin.occlusion;
            surfaceData.alpha = skin.alpha;
            surfaceData.clearCoatMask = 0.0h;
            surfaceData.clearCoatSmoothness = 0.0h;
            return surfaceData;
        }

        BRDFData BuildBRDFData(SkinSurfaceData skin)
        {
            half alpha = skin.alpha;
            BRDFData brdfData;
            InitializeBRDFData(skin.albedo, 0.0h, half3(0.0h, 0.0h, 0.0h), skin.smoothness, alpha, brdfData);
            return brdfData;
        }

        half3 DirectDiffuse(BRDFData brdfData, Light light, half3 normalWS)
        {
            half NdotL = saturate(dot(normalWS, light.direction));
            half3 radiance = light.color * (light.distanceAttenuation * light.shadowAttenuation * NdotL);
            return brdfData.diffuse * radiance;
        }

        half3 DirectSpecular(BRDFData brdfData, Light light, half3 normalWS, half3 viewDirectionWS)
        {
            half NdotL = saturate(dot(normalWS, light.direction));
            half3 radiance = light.color * (light.distanceAttenuation * light.shadowAttenuation * NdotL);
            return brdfData.specular * DirectBRDFSpecular(brdfData, normalWS, light.direction, viewDirectionWS) * radiance;
        }

        half3 ComputeDiffuseOnlyLighting(InputData inputData, SurfaceData surfaceData, BRDFData brdfData)
        {
            half4 shadowMask = CalculateShadowMask(inputData);
            AmbientOcclusionFactor aoFactor = CreateAmbientOcclusionFactor(inputData, surfaceData);
            Light mainLight = GetMainLight(inputData, shadowMask, aoFactor);
            MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI);

            uint meshRenderingLayers = GetMeshRenderingLayer();
            half3 color = inputData.bakedGI * brdfData.diffuse * aoFactor.indirectAmbientOcclusion;

            #ifdef _LIGHT_LAYERS
                if (IsMatchingLightLayer(mainLight.layerMask, meshRenderingLayers))
            #endif
            {
                color += DirectDiffuse(brdfData, mainLight, inputData.normalWS);
            }

            #if defined(_ADDITIONAL_LIGHTS)
                uint pixelLightCount = GetAdditionalLightsCount();

                #if USE_FORWARD_PLUS
                    for (uint lightIndex = 0; lightIndex < min(URP_FP_DIRECTIONAL_LIGHTS_COUNT, MAX_VISIBLE_LIGHTS); lightIndex++)
                    {
                        FORWARD_PLUS_SUBTRACTIVE_LIGHT_CHECK
                        Light light = GetAdditionalLight(lightIndex, inputData, shadowMask, aoFactor);

                        #ifdef _LIGHT_LAYERS
                            if (IsMatchingLightLayer(light.layerMask, meshRenderingLayers))
                        #endif
                        {
                            color += DirectDiffuse(brdfData, light, inputData.normalWS);
                        }
                    }
                #endif

                LIGHT_LOOP_BEGIN(pixelLightCount)
                    Light light = GetAdditionalLight(lightIndex, inputData, shadowMask, aoFactor);

                    #ifdef _LIGHT_LAYERS
                        if (IsMatchingLightLayer(light.layerMask, meshRenderingLayers))
                    #endif
                    {
                        color += DirectDiffuse(brdfData, light, inputData.normalWS);
                    }
                LIGHT_LOOP_END
            #endif

            #if defined(_ADDITIONAL_LIGHTS_VERTEX)
                color += inputData.vertexLighting * brdfData.diffuse;
            #endif

            return color * surfaceData.occlusion;
        }

        half3 ComputeSpecularOnlyLighting(InputData inputData, SurfaceData surfaceData, BRDFData brdfData)
        {
            half4 shadowMask = CalculateShadowMask(inputData);
            AmbientOcclusionFactor aoFactor = CreateAmbientOcclusionFactor(inputData, surfaceData);
            uint meshRenderingLayers = GetMeshRenderingLayer();

            half NoV = saturate(dot(inputData.normalWS, inputData.viewDirectionWS));
            half fresnelTerm = Pow4(1.0h - NoV);
            half3 reflectVector = reflect(-inputData.viewDirectionWS, inputData.normalWS);
            half3 indirectSpecular = GlossyEnvironmentReflection(
                reflectVector,
                inputData.positionWS,
                brdfData.perceptualRoughness,
                surfaceData.occlusion,
                inputData.normalizedScreenSpaceUV
            );

            half3 color = indirectSpecular * EnvironmentBRDFSpecular(brdfData, fresnelTerm) * _IndirectSpecularStrength;

            Light mainLight = GetMainLight(inputData, shadowMask, aoFactor);
            #ifdef _LIGHT_LAYERS
                if (IsMatchingLightLayer(mainLight.layerMask, meshRenderingLayers))
            #endif
            {
                color += DirectSpecular(brdfData, mainLight, inputData.normalWS, inputData.viewDirectionWS);
            }

            #if defined(_ADDITIONAL_LIGHTS)
                uint pixelLightCount = GetAdditionalLightsCount();

                #if USE_FORWARD_PLUS
                    for (uint lightIndex = 0; lightIndex < min(URP_FP_DIRECTIONAL_LIGHTS_COUNT, MAX_VISIBLE_LIGHTS); lightIndex++)
                    {
                        FORWARD_PLUS_SUBTRACTIVE_LIGHT_CHECK
                        Light light = GetAdditionalLight(lightIndex, inputData, shadowMask, aoFactor);

                        #ifdef _LIGHT_LAYERS
                            if (IsMatchingLightLayer(light.layerMask, meshRenderingLayers))
                        #endif
                        {
                            color += DirectSpecular(brdfData, light, inputData.normalWS, inputData.viewDirectionWS);
                        }
                    }
                #endif

                LIGHT_LOOP_BEGIN(pixelLightCount)
                    Light light = GetAdditionalLight(lightIndex, inputData, shadowMask, aoFactor);

                    #ifdef _LIGHT_LAYERS
                        if (IsMatchingLightLayer(light.layerMask, meshRenderingLayers))
                    #endif
                    {
                        color += DirectSpecular(brdfData, light, inputData.normalWS, inputData.viewDirectionWS);
                    }
                LIGHT_LOOP_END
            #endif

            return color * surfaceData.occlusion * _SpecularStrength;
        }

        half3 SkinTransmittanceProfile(float distance)
        {
            float dd = -distance * distance;
            return float3(0.233, 0.455, 0.649) * exp(dd / 0.0064)
                + float3(0.100, 0.336, 0.344) * exp(dd / 0.0484)
                + float3(0.118, 0.198, 0.000) * exp(dd / 0.1870)
                + float3(0.113, 0.007, 0.007) * exp(dd / 0.5670)
                + float3(0.358, 0.004, 0.000) * exp(dd / 1.9900)
                + float3(0.078, 0.000, 0.000) * exp(dd / 7.4100);
        }

        half3 ComputeSkinTranslucency(InputData inputData, half3 normalWS, half3 viewDirectionWS, half3 albedo, half2 uv, half occlusion)
        {
            Light mainLight = GetMainLight(inputData.shadowCoord);
            half3 lightDirectionWS = normalize(mainLight.direction);
            half3 distortedLightWS = normalize(lightDirectionWS + normalWS * _TranslucencyDistortion);

            half backLight = saturate(_TranslucencyWrap + dot(lightDirectionWS, -normalWS));
            half viewBackLight = pow(saturate(dot(viewDirectionWS, -distortedLightWS)), _TranslucencyPower);
            half directionTerm = backLight * lerp(1.0h, viewBackLight, _TranslucencyViewWeight);

            half mapThickness = SAMPLE_TEXTURE2D(_ThicknessMap, sampler_ThicknessMap, uv).r;
            mapThickness = saturate(mapThickness * _ThicknessScale + _ThicknessBias);

            half proceduralThickness = saturate(1.0h - backLight);
            half thickness = lerp(proceduralThickness, mapThickness, _ThicknessMapWeight);
            float profileDistance = max(0.0h, thickness) * max(0.001h, _TranslucencyProfileScale);
            half3 profile = SkinTransmittanceProfile(profileDistance);

            half shadowVisibility = lerp(1.0h, mainLight.shadowAttenuation, _TranslucencyShadowWeight);
            half3 lightColor = mainLight.color * mainLight.distanceAttenuation * shadowVisibility;

            return albedo
                * profile
                * _TranslucencyColor.rgb
                * lightColor
                * directionTerm
                * occlusion
                * _TranslucencyStrength
                * _TranslucencyEnabled;
        }

        half4 FragDiffuseOnly(Varyings input) : SV_Target
        {
            UNITY_SETUP_INSTANCE_ID(input);
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

            SkinSurfaceData skin = SampleSkinSurface(input);
            InputData inputData = BuildInputData(input, skin.normalWS);
            SurfaceData surfaceData = BuildUniversalSurfaceData(skin);
            BRDFData brdfData = BuildBRDFData(skin);

            half3 color = ComputeDiffuseOnlyLighting(inputData, surfaceData, brdfData);
            color += ComputeSkinTranslucency(inputData, skin.normalWS, inputData.viewDirectionWS, skin.albedo, input.uv, skin.occlusion);
            color = MixFog(color, inputData.fogCoord);
            return half4(color, skin.alpha);
        }

        half4 FragSpecularOnly(Varyings input) : SV_Target
        {
            UNITY_SETUP_INSTANCE_ID(input);
            UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

            SkinSurfaceData skin = SampleSkinSurface(input);
            InputData inputData = BuildInputData(input, skin.normalWS);
            SurfaceData surfaceData = BuildUniversalSurfaceData(skin);
            BRDFData brdfData = BuildBRDFData(skin);

            half3 color = ComputeSpecularOnlyLighting(inputData, surfaceData, brdfData);
            color *= ComputeFogIntensity(inputData.fogCoord);
            return half4(color, 0.0h);
        }
        ENDHLSL

        Pass
        {
            Name "UniversalForward"
            Tags { "LightMode" = "UniversalForward" }

            Blend One Zero
            ZWrite On
            ZTest LEqual
            Cull Back

            Stencil
            {
                Ref [_StencilRef]
                Comp Always
                Pass Replace
            }

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragDiffuseOnly
            #pragma shader_feature_local _NORMALMAP
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile _ _FORWARD_PLUS
            #pragma multi_compile_fog
            #pragma multi_compile_instancing
            ENDHLSL
        }

        Pass
        {
            Name "SSSSSpecularOnly"
            Tags { "LightMode" = "SSSSSpecularOnly" }

            Blend One One
            ZWrite Off
            ZTest LEqual
            Cull Back

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragSpecularOnly
            #pragma shader_feature_local _NORMALMAP
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile _ _FORWARD_PLUS
            #pragma multi_compile_fog
            #pragma multi_compile_instancing
            ENDHLSL
        }

        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }

            ZWrite On
            ColorMask 0

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex DepthVert
            #pragma fragment DepthFrag
            #pragma multi_compile_instancing
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct DepthAttributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct DepthVaryings
            {
                float4 positionCS : SV_POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            DepthVaryings DepthVert(DepthAttributes input)
            {
                DepthVaryings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                return output;
            }

            half4 DepthFrag(DepthVaryings input) : SV_Target
            {
                return 0;
            }
            ENDHLSL
        }

        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            ZWrite On
            ZTest LEqual
            ColorMask 0

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex DepthVert
            #pragma fragment DepthFrag
            #pragma multi_compile_instancing
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct DepthAttributes
            {
                float4 positionOS : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct DepthVaryings
            {
                float4 positionCS : SV_POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            DepthVaryings DepthVert(DepthAttributes input)
            {
                DepthVaryings output;
                UNITY_SETUP_INSTANCE_ID(input);
                UNITY_TRANSFER_INSTANCE_ID(input, output);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                return output;
            }

            half4 DepthFrag(DepthVaryings input) : SV_Target
            {
                return 0;
            }
            ENDHLSL
        }
    }

    Fallback Off
}
