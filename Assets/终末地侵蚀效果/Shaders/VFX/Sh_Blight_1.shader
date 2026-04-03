Shader "Scene/Blight1"
{
    Properties
    {
        [Space()] [Header(__________________Main__________________)]
        _DepthFadeRange ("深度淡化", Range(0, 1)) = 0.1
        _Rough ("粗糙度", Range(0, 1)) = 0.1
        _SpecInt ("高光强度", Range(0, 1)) = 0.1
        
        [Space()] [Header(__________________Warp__________________)]
        [NoScaleOffset] _WarpTex ("扭曲方向(RG) 法线(BA)", 2D) = "gray" {}
        _WarpTile ("平铺", Float) = 1
        _NormalInt ("法线强度", Float) = 1
        _WarpInt ("扭曲强度", Range(0.01, 2)) = 1
        _WarpSpeed ("变化速度", Float) = 1
        _WarpSpeedX ("速度X", Float) = 0
        _WarpSpeedY ("速度Y", Float) = 0
        
        [Space()] [Header(__________________Fbm__________________)]
        [IntRange] _Octave ("阶数", Range(2, 3)) = 2
        _FreqRatio ("频率缩放比", Range(1, 4)) = 1.8
        
        [Space()] [Header(__________________MatCap__________________)]
        [NoScaleOffset] _MatCapTex ("MatCap", 2D) = "white" {}
        _MatCapInt ("MatCap强度", Float) = 4
        
        [Space()] [Header(__________________Scene__________________)]
        _SceneTint_I ("背景色调_内", Color) = (0,0,0,1)
        [HDR]_SceneTint_O ("背景色调_外", Color) = (1,1,1,1)
        _SceneTintLerpPos ("色调分界位置", Range(0, 1)) = 0.5
        _SceneTintLerpWidth ("色调分界宽度", Range(0, 0.5)) = 0.1
        _SceneWarpInt ("背景扭曲强度", Range(0, 1)) = 0.1
        
        [Space()] [Header(__________________Flare__________________)]
        [HDR] _FlareColPos_0 ("闪点颜色(RGB) 范围(A)_0", Color) = (0,0,1,0.1)
        [HDR] _FlareColPos_1 ("闪点颜色(RGB) 范围(A)_1", Color) = (1,0,0,0.5)
        _BreathFreq ("呼吸频率", Float) = 1
    }
    SubShader
    {
        Tags
        { "Queue" = "Geometry+600" }
        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Assets/CustomShaderHLSL/CustomToyBox.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
            sampler2D _CameraOpaqueTexture, _CameraDepthTexture;
            sampler2D _WarpTex;
            sampler2D _MatCapTex;
            CBUFFER_START(UnityPerMaterial)
            // Main
            float _NormalInt;
            float _DepthFadeRange;
            float _Rough;
            half _SpecInt;
            // 扭曲
            uint _Octave;
            float _FreqRatio;
            float _WarpSpeed;
            float _WarpSpeedX, _WarpSpeedY;
            float _WarpTile;
            float _WarpInt;
            // 场景
            float3 _SceneTint_I, _SceneTint_O;
            float _SceneTintLerpPos;
            float _SceneTintLerpWidth;
            float _SceneWarpInt;
            // MatCap
            half _MatCapInt;
            // 闪点
            half4 _FlareColPos_0, _FlareColPos_1;
            half _BreathFreq;
            CBUFFER_END

            // domain warp
            float4 GetDomainWarpNH(float2 uv)
            {
                // 循环变量
                float2 P0 = uv;
                float2 P = P0;
                float2x2 E = {
                    1,0,
                    0,1
                };
                float2x2 gradP = E;
                float a = _WarpInt / _Octave;   // 振幅

                // FBM
                float w = 1;
                float2 v = float2(_WarpSpeed, 0);
                float s, c;
                sincos(TWO_PI / _Octave, s, c);
                float2x2 rotMatrix = {
                    float2(c, -s),
                    float2(s, c)
                };
                [loop]
                for (uint id = 0; id < _Octave; id++)
                {
                    float4 var_WarpTex = tex2D(_WarpTex, w*(P + v*_Time.x));
                    float4 unpack_WarpTex = 2*var_WarpTex - 1;
                    // 高度场梯度
                    float3 N = unpack_WarpTex.baa;
                    N.z = sqrt(max(0.001f, 1-dot(N.xy, N.xy)));
                    float2 gradH = -N.xy / N.z;
                    // P梯度
                    float h = length(unpack_WarpTex.rg);
                    float rad = TWO_PI * h;
                    float2 D = unpack_WarpTex.rg / h;
                    float2 T = mul(float2x2(float2(1,-rad), float2(rad, 1)), D);
                    float2 gradh = mul(gradH, gradP);
                    gradP = E + a*w*float2x2(T.x*gradh, T.y*gradh);
                    // P
                    P = P0 + a*D*h;
                    // 频率 & 相位
                    w *= _FreqRatio;
                    v = mul(rotMatrix, v);
                }

                // 混合
                float2 dirR = P - P0;
                float sqrR = dot(dirR, dirR) / (a*a);   // 除aa单位化
                float2 grad_sqrR = (mul(dirR, gradP) - dirR);   // 因为自定义法线强度, *2可以去掉
                return float4(normalize(float3(-_NormalInt * grad_sqrR, 1)), sqrR);
            }
            
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
                float3x3 TBN    : TEXCOORD2;
            };

            v2f vert(a2v i)
            {
                v2f o;
                o.posCS = TransformObjectToHClip(i.posOS);
                o.uv = _WarpTile*(i.uv + float2(_WarpSpeedX, _WarpSpeedY)*_Time.x);
                o.posWS = TransformObjectToWorld(i.posOS);
                o.TBN = GetTBN(i.nDirOS, i.tDirOS);
                return o;
            }
            half3 frag(v2f i) : SV_Target
            {
                // domain warp
                float4 warpNH = GetDomainWarpNH(i.uv);

                // 法线
                float3 posWS = i.posWS;
                float3x3 TBN = NormalizeRMatrix(i.TBN);
                float3 nDirTS = warpNH.xyz;
                float3 nDirWS = mul(nDirTS, TBN);
                // nDirWS = normalize(lerp(TBN[2], TBN[1], warpNH.a));
                // nDirWS = GetNDir_ByDXDYHeight(warpNH.a, posWS, TBN[2], 10*_NormalInt);
                
                // nv
                float3 vDirWS = normalize(GetCameraPositionWS() - posWS);
                float nv = max(0, dot(nDirWS, vDirWS));
                
                // 高光
                Light light = GetMainLight();
                float3 lDirWS = light.direction;
                float nl = max(0, dot(nDirWS, lDirWS));
                float3 directSpecCol =
                    nl * light.color * _SpecInt *
                    GetSpec_FakePBR(nDirWS, normalize(lDirWS + vDirWS), _Rough, 10);
                
                // 环境光
                float4 uv_MatCap = float4(0.5f*TransformWorldToViewNormal(nDirWS).xy + 0.5f, 0, 10*_Rough);
                half4 var_MatCapTex = tex2Dbias(_MatCapTex, uv_MatCap);
                half3 indirectSpecCol = _MatCapInt * var_MatCapTex.rgb;
                // return half3(1.13,0.16,0.08) * (indirectSpecCol+directSpecCol);

                // 深度淡化
                float2 uv_Screen = i.posCS.xy * _ScreenSize.zw;
                float sceneZ = LinearEyeDepth(tex2D(_CameraDepthTexture, uv_Screen).r, _ZBufferParams);
                float3 scenePosWS = GetPosWSByLinearEyeDepth(sceneZ, vDirWS).xyz;
                float deltaDis = length(posWS - scenePosWS);
                float deltaDisMask = smoothstep(0, 1, min(1, deltaDis / _DepthFadeRange));

                // 背景色
                half3 sceneCol = tex2D(_CameraOpaqueTexture, uv_Screen + _SceneWarpInt * nDirTS.xy).rgb;
                float sceneTintLerpPoss_Inv = 1 - _SceneTintLerpPos;
                float lerp01_SceneTint = smoothstep(
                    sceneTintLerpPoss_Inv - _SceneTintLerpWidth,
                    sceneTintLerpPoss_Inv + _SceneTintLerpWidth,
                    nv
                );
                half3 sceneTint = lerp(_SceneTint_O, _SceneTint_I, lerp01_SceneTint);
                sceneCol = lerp(1, sceneTint, deltaDisMask) * sceneCol;

                // 闪点
                float warpH = warpNH.a;
                half breathMask = 0.5f * sin(_BreathFreq * _Time.y) + 0.5f;
                half3 flareCol = lerp(
                    _FlareColPos_0.rgb * step(warpH, _FlareColPos_0.a),
                    _FlareColPos_1.rgb * step(1-_FlareColPos_1.a, warpH),
                    breathMask
                );

                // 混合
                half3 finalCol = sceneCol + deltaDisMask * (directSpecCol + flareCol);
                finalCol += finalCol * indirectSpecCol * deltaDisMask;
                return finalCol;
            }
            ENDHLSL
        }
        UsePass "Universal Render Pipeline/Lit/ShadowCaster"
    }
}