Shader "Custom/MyCustomURPShader"
{
    Properties
    {
         _Color ("颜色", Color) = (1,1,1,1)
        _MainTex ("基础纹理 (RGB)", 2D) = "white" {}
		_BumpMap("法线贴图", 2D) = "bump" {}

		thicknessNoise("薄膜厚度噪声贴图", 2D) = "white" {}

		thickness ("薄膜厚度", Range(0, 3000)) = 250  // 单位：纳米  参数列：0 3000 250 # 薄膜厚度（单位：纳米）
		_ExternalIOR("外部介质折射率", Range(0.2, 3)) = 1  // 空气的折射率 参数列：0.2 3 1 # 外部介质（空气）的折射率
		_ThinfilmIOR("薄膜折射率", Range(0.2, 3)) = 1.5  //薄膜层的折射率 0.2 3 1.5
		_InternalIOR("内部介质折射率", Range(0.2, 3)) = 1.25  // 物体本身的折射率 参数列： 0.2 3 1.25 # 内部介质（物体）的折射率
		_n("Blinn-Phong微平面指数", Range(1, 1000)) = 100  // 控制高光锐利度 1 1000 100 # Blinn-Phong微平面指数（控制高光锐利度）

      
    }

    SubShader
    {
        Tags 
        { 
           "RenderType"="Opaque" 
            "Queue"="Geometry"
            "RenderPipeline"="UniversalPipeline" 
        }
        //LOD 100
        Pass
        {
          
            // BlendOp [_BlendOp]
            // Blend [_SrcBlend][_DstBlend], [_SrcBlendAlpha][_DstBlendAlpha]
            // ZWrite [_ZWrite]
            // ZTest [_ZTest]
            // ZClip [_ZClip]
            // Cull [_Cull]
            // ColorMask [_ColorMask]
            // AlphaToMask [_AlphaToMask]

            // Stencil
            // {
            //     Ref [_Stencil]
            //     Comp [_StencilComp]
            //     ReadMask [_StencilReadMask]
            //     WriteMask [_StencilWriteMask]
            //     Pass [_StencilOp]
            //     Fail [_StencilOpFail]
            //     ZFail [_StencilOpZFail]
            //     ZFailFront [_StencilOpZFailFront]
            //     CompFront [_StencilCompFront]
            //     PassFront [_StencilOpFront]
            //     CompBack [_StencilCompBack]
            //     PassBack [_StencilOpBack]
            //     ZFailBack [_StencilOpZFailBack]
            // }

            //Geometry
            ZWrite on
            ZTest LEqual
          //  Blend SrcAlpha OneMinusSrcAlpha
            Cull Back

            ////Transparent
            //ZWrite Off
            //Blend SrcAlpha OneMinusSrcAlpha // 传统透明度
            //Blend One OneMinusSrcAlpha // 预乘透明度
            //Blend OneMinusDstColor One // 软加法
            //Blend DstColor Zero // 正片叠底（相乘）
            //Blend OneMinusDstColor One // 滤色 //柔和叠加（soft Additive）
            //Blend DstColor SrcColor // 2x相乘 (2X Multiply)
            //Blend One One // 线性减淡
            //BlendOp Min Blend One One //变暗
            //BlendOp Max Blend One One //变亮




            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex vert
            #pragma fragment frag

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _SHADOWS_SOFT

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

            //尽量对齐到float4,否则unity底层会自己填padding来对齐,会有空间浪费
            //Align to float4 as much as possible, otherwise the underlying Unity will fill in padding to align, which will waste space
            CBUFFER_START(UnityPerMaterial)
            
                sampler2D _MainTex;
                float4 _MainTex_ST;

                sampler2D _BumpMap;
                float4 _BumpMap_ST;

                sampler2D thicknessNoise;
                float4 thicknessNoise_ST;

                float4 _Color;
                float thickness;
                float _ExternalIOR;
                float _ThinfilmIOR;
                float _InternalIOR;
                float _N;
            CBUFFER_END



            ////GPU Instancing 和SRP Batcher冲突 根据需要确定是否开启
            ////GPU Installing and SRP Batcher conflict, determine whether to enable as needed
            // #pragma multi_compile_instancing
            // #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/UnityInstancing.hlsl"
            
            // UNITY_INSTANCING_BUFFER_START(PerInstance)
            // //UNITY_DEFINE_INSTANCED_PROP(float4, _MainColor)
            // UNITY_INSTANCING_BUFFER_END(PerInstance)

            ////接收阴影关键字
            ////Receive shadow keywords
            // #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
            // #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            // #pragma multi_compile _ _SHADOWS_SOFT

            
            struct Attributes
            {
                float4 positionOS   : POSITION; // 对象空间位置
                float2 uv           : TEXCOORD0; // 基础纹理UV
                float2 uv1          : TEXCOORD1; // 法线贴图UV
                float3 normalOS     : NORMAL;    // 对象空间法线
                float4 tangentOS    : TANGENT;   // 对象空间切线
            };

            struct Varings
            {
                float4 positionHCS  : SV_POSITION; // 齐次裁剪空间位置
                float2 uvMainTex    : TEXCOORD0;   // 基础纹理UV
                float2 uvBumpMap    : TEXCOORD1;   // 法线贴图UV
                float3 positionWS   : TEXCOORD2;   // 世界空间位置
                float3 normalWS     : TEXCOORD3;   // 世界空间法线
                float3 tangentWS    : TEXCOORD4;   // 世界空间切线
                float3 bitangentWS  : TEXCOORD5;   // 世界空间副切线
            };


            Varings vert (Attributes IN)
            {
                Varings output;

                // 转换位置到裁剪空间
                output.positionHCS = TransformObjectToHClip(IN.positionOS.xyz);
                
                // 传递UV（支持缩放和平移）
                output.uvMainTex = TRANSFORM_TEX(IN.uv, _MainTex);
                output.uvBumpMap = TRANSFORM_TEX(IN.uv1, _BumpMap);
                
                // 转换位置到世界空间
                output.positionWS = TransformObjectToWorld(IN.positionOS.xyz);
                
                // 计算TBN矩阵，转换法线到世界空间
                float3 normalWS = TransformObjectToWorldNormal(IN.normalOS);
                float3 tangentWS = TransformObjectToWorldDir(IN.tangentOS.xyz);
                float3 bitangentWS = cross(normalWS, tangentWS) * IN.tangentOS.w;
                
                output.normalWS = normalWS;
                output.tangentWS = tangentWS;
                output.bitangentWS = bitangentWS;

                return output;
            }

            //薄膜干涉函数
             /* 振幅反射系数（s偏振：垂直于入射面偏振） */
            float rs(float n1, float n2, float cosI, float cosT)
            {
                return (n1 * cosI - n2 * cosT) / (n1 * cosI + n2 * cosT);
            }

            /* 振幅反射系数（p偏振：平行于入射面偏振） */
            float rp(float n1, float n2, float cosI, float cosT)
            {
                return (n2 * cosI - n1 * cosT) / (n1 * cosT + n2 * cosI);
            }

            /* 振幅透射系数（s偏振） */
            float ts(float n1, float n2, float cosI, float cosT)
            {
                return 2 * n1 * cosI / (n1 * cosI + n2 * cosT);
            }

            /* 振幅透射系数（p偏振） */
            float tp(float n1, float n2, float cosI, float cosT)
            {
                return 2 * n1 * cosI / (n1 * cosT + n2 * cosI);
            }
             /* 菲涅尔薄膜涂层反射率计算 */
            float3 FresnelCoating(float cos0, float thickness)
            {
               
                //
                // // 预计算相位突变
                // float delta10 = (_ThinfilmIOR < _ExternalIOR) ? PI : 0.0f;// 薄膜-外部介质界面的相位突变
                // float delta12 = (_ThinfilmIOR < _InternalIOR) ? PI : 0.0f;// 薄膜-内部介质界面的相位突变
                // float delta = delta10 + delta12; // 总相位突变值
                //
                // // 计算薄膜层和透射角的正弦平方
                // float sin1 = pow(_ExternalIOR / _ThinfilmIOR, 2) * (1 - pow(cos0, 2)); // 薄膜内折射角的正弦平方（斯涅尔定律）
                // float sin2 = pow(_ExternalIOR / _InternalIOR, 2) * (1 - pow(cos0, 2)); // 内部介质中透射角的正弦平方
                //
                // // 全内反射时反射率为1
                // if ((sin1 > 1) || (sin2 > 1))  // 发生全内反射时，反射率为1
                //     return float3(1, 1, 1);
                //
                // // 计算余弦值
                // float cos1 = sqrt(1 - sin1);
                // float cos2 = sqrt(1 - sin2);
                //
                // // 计算干涉相位变化（RGB分别对应650/510/475nm波长）
                // float3 phi = 2 * _ThinfilmIOR * thickness * cos1;// 薄膜内光程差的基础项
                // phi *= 2 * PI / float3(650, 510, 475);// 分别对应红(650nm)、绿(510nm)、蓝(475nm)光的相位差
                // phi += delta;// 叠加界面相位突变
                //
                // // 计算菲涅尔振幅系数 获取菲涅尔振幅反射系数（复数形式的幅值乘积）
                // // （s偏振：垂直入射面偏振）
                // float alpha_s = rs(_ThinfilmIOR, _ExternalIOR, cos1, cos0) * rs(_ThinfilmIOR, _InternalIOR, cos1, cos2);
                // //（p偏振：平行入射面偏振）
                // float alpha_p = rp(_ThinfilmIOR, _ExternalIOR, cos1, cos0) * rp(_ThinfilmIOR, _InternalIOR, cos1, cos2);
                // // 获取菲涅尔振幅透射系数（复数形式的幅值乘积）
                // //（s偏振）
                // float beta_s = ts(_ExternalIOR, _ThinfilmIOR, cos0, cos1) * ts(_ThinfilmIOR, _InternalIOR, cos1, cos2);
                // //（p偏振）
                // float beta_p = tp(_ExternalIOR, _ThinfilmIOR, cos0, cos1) * tp(_ThinfilmIOR, _InternalIOR, cos1, cos2);
                //
                // // 计算偏振光强透射系数
                // float3 ts = pow(beta_s, 2) / (pow(alpha_s, 2) - 2 * alpha_s * cos(phi) + 1);
                // float3 tp = pow(beta_p, 2) / (pow(alpha_p, 2) - 2 * alpha_p * cos(phi) + 1);
                //
                // // 介质变化的透射功率比修正 考虑能量守恒的光束比修正（透射光强的几何因子）
                // float beamRatio = (_InternalIOR * cos2) / (_ExternalIOR * cos0);
                //
                // // 计算平均反射率
                // return 1 - beamRatio * (ts + tp) * 0.5f;

              float __PI = 3.14159265f;
		           /* Precompute the reflection phase changes (depends on IOR) */
		           float delta10 = (_ThinfilmIOR < _ExternalIOR) ? __PI : 0.0f;
		           float delta12 = (_ThinfilmIOR < _InternalIOR) ? __PI : 0.0f;
		           float delta = delta10 + delta12;
		           /* Calculate the thin film layer (and transmitted) angle cosines. */
		           float sin1 = pow(_ExternalIOR / _ThinfilmIOR, 2) * (1 - pow(cos0, 2));
		           float sin2 = pow(_ExternalIOR / _InternalIOR, 2) * (1 - pow(cos0, 2));
		           if ((sin1 > 1) || (sin2 > 1))
		           	return float3(1,1,1);
		           /* Account for TIR. */
		           float cos1 = sqrt(1 - sin1), cos2 = sqrt(1 - sin2);
		           /* Calculate the interference phase change. */
		           float3 phi = (2 * _ThinfilmIOR * thickness * cos1);
		           phi *= 2 * __PI / float3(650, 510, 475);
		           phi += delta;
		           /* Obtain the various Fresnel amplitude coefficients. */
		           float alpha_s = rs(_ThinfilmIOR, _ExternalIOR, cos1, cos0) * rs(_ThinfilmIOR, _InternalIOR, cos1, cos2);
		           float alpha_p = rp(_ThinfilmIOR, _ExternalIOR, cos1, cos0) * rp(_ThinfilmIOR, _InternalIOR, cos1, cos2);
		           float beta_s = ts(_ExternalIOR, _ThinfilmIOR, cos0, cos1) * ts(_ThinfilmIOR, _InternalIOR, cos1, cos2);
		           float beta_p = tp(_ExternalIOR, _ThinfilmIOR, cos0, cos1) * tp(_ThinfilmIOR, _InternalIOR, cos1, cos2);
		           /* Calculate the s- and p-polarized intensity transmission coefficient. */
		           float3 ts = pow(beta_s, 2) / (pow(alpha_s, 2) - 2 * alpha_s * cos(phi) + 1);
		           float3 tp = pow(beta_p, 2) / (pow(alpha_p, 2) - 2 * alpha_p * cos(phi) + 1);
		           /* Calculate the transmitted power ratio for medium change. */
		           float beamRatio = (_InternalIOR * cos2) / (_ExternalIOR * cos0);
		           /* Calculate the average reflectance. */
		           return 1 - beamRatio * (ts + tp) * 0.5f ;
            }

                 /* Blinn-Phong BRDF计算（世界空间） */
            float3 BRDF(float3 L, float3 V, float3 N, float thickness)
            {
                // 计算半程向量
                float3 H = normalize(L + V);
             
                // Blinn-Phong高光项（范围映射到0-1）
                float NdotH = saturate(dot(N, H) * 0.5 + 0.5);
               
                float specular = pow(NdotH, _N);
                float temp=FresnelCoating(NdotH, thickness);
                
                
                // 结合薄膜菲涅尔反射率
                return specular * FresnelCoating(NdotH, thickness);
            }
            half4 frag (Varings input) : SV_Target
            {
               // 1. 采样基础纹理和颜色
                float4 mainTexColor = tex2D(_MainTex, input.uvMainTex) * _Color;
                
                // 2. 采样并解包法线贴图（转换到世界空间）
                float3 normalTS = UnpackNormal(tex2D(_BumpMap, input.uvBumpMap));
                float3x3 TBN = float3x3(input.tangentWS, input.bitangentWS, input.normalWS);
                float3 normalWS = normalize(mul(normalTS, TBN));
                
                // 3. 采样噪声贴图，修改薄膜厚度（取R通道避免颜色干扰）
                float noise = tex2D(thicknessNoise, input.uvBumpMap).r+_SinTime.y;
                float finalThickness = thickness * noise;
                
                // 4. 获取主光源信息（URP标准方式）
                Light mainLight = GetMainLight();
                float3 lightDirWS = normalize(-mainLight.direction);
                float3 viewDirWS = normalize(_WorldSpaceCameraPos - input.positionWS);
                float shadowAtten = mainLight.shadowAttenuation;
                
                // 5. 计算BRDF和最终颜色
                float3 brdfResult = BRDF(lightDirWS, viewDirWS, normalWS, finalThickness);
                float3 finalColor = mainTexColor.rgb * mainLight.color * brdfResult * shadowAtten;
                
                // 6. 返回最终颜色（保留透明度）
                return half4(finalColor, mainTexColor.a);

                
            }
            ENDHLSL
        }

        //以下是对应的三个官方pass，自定义Shader不需要这么多变体，最好自己找地方再写一次
        //Here are the corresponding three official passes. Custom Shaders do not require so many variations, it is best to find a place to write them again
        // UsePass "Universal Render Pipeline/Lit/ShadowCaster"
        // UsePass "Universal Render Pipeline/Lit/depthOnly"
        // UsePass "Universal Render Pipeline/Lit/DepthNormals"

        //以下是这三个pass的官方代码，如果你需要自定义这些pass,你可以在这个基础上修改
        //Here are the official codes for these three passes. If you need to customize these passes, you can modify them based on this
        Pass
        {
            Name "ShadowCaster"
            Tags
            {
                "LightMode" = "ShadowCaster"
            }

            // -------------------------------------
            // Render State Commands
            ZWrite On
            ZTest LEqual
            ColorMask 0
            Cull Back

            HLSLPROGRAM
            #pragma target 3.5

            // -------------------------------------
            // Shader Stages
            #pragma vertex ShadowPassVertex
            #pragma fragment ShadowPassFragment

            // This is used during shadow map generation to differentiate between directional and punctual light shadows, as they use different formulas to apply Normal Bias
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW

            // -------------------------------------
            // Includes
            #include "Packages/com.unity.render-pipelines.universal/Shaders/SimpleLitInput.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Shaders/ShadowCasterPass.hlsl"
            ENDHLSL
        }
        Pass
        {
            Name "DepthOnly"
            Tags
            {
                "LightMode" = "DepthOnly"
            }

            // -------------------------------------
            // Render State Commands
            ZWrite On
            ColorMask R
            Cull Back

            HLSLPROGRAM
            #pragma target 3.5

            // -------------------------------------
            // Shader Stages
            #pragma vertex DepthOnlyVertex
            #pragma fragment DepthOnlyFragment
            // -------------------------------------
            // Includes
            #include "Packages/com.unity.render-pipelines.universal/Shaders/SimpleLitInput.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Shaders/DepthOnlyPass.hlsl"
            ENDHLSL
        }
        Pass
        {
            Name "DepthNormals"
            Tags
            {
                "LightMode" = "DepthNormals"
            }

            // -------------------------------------
            // Render State Commands
            ZWrite On
            Cull Back

            HLSLPROGRAM
            #pragma target 3.5
            // -------------------------------------
            // Shader Stages
            #pragma vertex DepthNormalsVertex
            #pragma fragment DepthNormalsFragment
            // -------------------------------------
            // Includes
            #include "Packages/com.unity.render-pipelines.universal/Shaders/SimpleLitInput.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/Shaders/SimpleLitDepthNormalsPass.hlsl"
            ENDHLSL
        }
    }
    //使用官方的Diffuse作为FallBack会增加大量变体，可以考虑自定义
    //FallBack "Diffuse"
}