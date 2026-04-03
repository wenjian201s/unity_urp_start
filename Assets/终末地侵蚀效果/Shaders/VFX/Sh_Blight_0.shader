Shader "Scene/Blight0"
{
    Properties
    {
        [Space()] [Header(__________________Main__________________)]
        [HDR]_Tint ("色调", Color) = (1,1,1,1)
        _DepthFadeRange ("深度淡化", Range(0, 1)) = 0.1
        _Rough ("粗糙度", Range(0, 1)) = 0.1
        
        [Space()] [Header(__________________Normal__________________)]
        _NormalMap ("法线", 2D) = "bump" {}
        _NormalInt ("法线强度", Float) = 1
        
        [Space()] [Header(__________________Warp__________________)]
        _WarpCenterPos ("扭曲中心坐标", Vector) = (0,0,0,0)
        _WarpFreq ("扭曲频率", Float) = 10
        _WarpSpeed ("扭曲扩散速度", Range(-4, 4)) = 1 
        _WarpInt ("扭曲强度", Range(-1, 1)) = 0.5

        [Space()] [Header(__________________MatCap__________________)]
        [NoScaleOffset] _MatCapTex ("MatCap", 2D) = "white" {}
    }
    SubShader
    {
        Tags
        { "Queue" = "Geometry+600" }
        Pass
        {
            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite on
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Assets/CustomShaderHLSL/CustomToyBox.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
            sampler2D _CameraDepthTexture;
            sampler2D _NormalMap;
            sampler2D _MatCapTex;
            CBUFFER_START(UnityPerMaterial)
            // Main
            float3 _Tint;
            float _DepthFadeRange;
            float _Rough;
            // 法线
            float4 _NormalMap_ST;
            float _NormalInt;
            // 扭曲
            float3 _WarpCenterPos;
            float _WarpFreq;
            float _WarpSpeed;
            float _WarpInt;
            CBUFFER_END
            
            struct a2v
            {
                float3 posOS	: POSITION;
                float2 uv       : TEXCOORD0;
                float3 nDirOS   : NORMAL;
                float4 tDirOS   : TANGENT;
            };

            struct v2f
            {
                float4 posCS	: SV_POSITION;
                float2 uv       : TEXCOORD0;
                float3 posWS    : TEXCOORD1;
                nointerpolation float3 warpCenterPosWS : TEXCOORD2;
                float3x3 TBN    : TEXCOORD3;
            };
            
            v2f vert(a2v i)
            {
                v2f o;
                o.posCS = TransformObjectToHClip(i.posOS);
                o.uv = _NormalMap_ST.xy * i.uv + _NormalMap_ST.zw;
                o.posWS = TransformObjectToWorld(i.posOS);
                o.warpCenterPosWS = TransformObjectToWorld(_WarpCenterPos);
                o.TBN = GetTBN(i.nDirOS, i.tDirOS);
                return o;
            }
            half4 frag(v2f i) : SV_Target
            {
                // 球面波梯度
                float3 posWS = i.posWS;
                float3 deltaR = posWS - i.warpCenterPosWS;
                float R = length(deltaR);
                float3 gradWS = deltaR / R * _WarpFreq * cos(_WarpFreq*(R + _WarpSpeed*_Time.x));
                
                // 法线
                float3x3 TBN = NormalizeRMatrix(i.TBN);
                float3 nDirTS = UnpackNormal(tex2D(_NormalMap, i.uv));
                nDirTS.xy *= _NormalInt;
                float3 nDirWS = normalize(normalize(mul(nDirTS, TBN)) + 1E-3f*_WarpInt*gradWS);

                // nv
                float3 vDirWS = normalize(GetCameraPositionWS() - posWS);
                float nv = max(0, dot(nDirWS, vDirWS));
                float nv_Inv = 1 - nv;
                half3 F = lerp(_Tint, 1, Pow4(nv_Inv)*nv_Inv);
                
                // 高光
                Light light = GetMainLight();
                float3 lDitWS = light.direction;
                half3 directSpecCol = F * light.color * GetSpec_FakePBR(nDirWS, normalize(lDitWS + vDirWS), _Rough, 4);
                
                // 环境光
                float4 uv_MatCap = float4(0.5f*TransformWorldToViewNormal(nDirWS).xy + 0.5f, 0, 10*_Rough);
                half3 var_MatCapTex = tex2Dbias(_MatCapTex, uv_MatCap).rgb;
                half3 indirectSpecCol = F * var_MatCapTex.rgb;
                
                // 深度淡化
                float2 uv_Screen = i.posCS.xy * _ScreenSize.zw;
                float sceneZ = LinearEyeDepth(tex2D(_CameraDepthTexture, uv_Screen).r, _ZBufferParams);
                float3 scenePosWS = GetPosWSByLinearEyeDepth(sceneZ, vDirWS).xyz;
                float deltaDis = length(posWS - scenePosWS);
                float deltaDisMask = smoothstep(0, 1, min(1, deltaDis / _DepthFadeRange));
                
                // 混合
                half3 finalCol = indirectSpecCol + directSpecCol;
                return half4(finalCol, deltaDisMask);
            }
            ENDHLSL
        }
        UsePass "Universal Render Pipeline/Lit/ShadowCaster"
    }
}