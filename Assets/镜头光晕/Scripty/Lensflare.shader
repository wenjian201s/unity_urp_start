Shader"Moonflow/Lensflare"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        
        Tags
        {
            "RenderType" = "Transparent" 
            "IgnoreProjector" = "True" 
            "PreviewType" = "Plane" 
            "PerformanceChecks" = "False" 
            "RenderPipeline" = "UniversalPipeline"
        }
        LOD 100

        Pass
        {
            Blend One One
            ZWrite Off
            ZTest Off//以保证叠加结果正确且永远在最前渲染
            
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/core.hlsl"

            struct appdata
            {
               float4 vertex : POSITION;
               float2 uv : TEXCOORD0;
               half4 color : COLOR;
            };

            struct v2f
            {
               float4 vertex : SV_POSITION;
               float2 uv : TEXCOORD0;
               half4 color : TEXCOORD1;
            };

            Texture2D _MainTex;
            SamplerState sampler_MainTex;
            float4 _MainTex_ST;

            // Moved to use ComputeShader
            // Texture2D _CameraDepthTexture;
            // SamplerState sampler_CameraDepthTexture;

            half4 _FlareScreenPos; //对应MFLensflare内的STATIC_FLARESCREENPOS，可修改，记录了光源的屏幕坐标

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = TransformObjectToHClip(v.vertex);
                o.uv.xy = v.uv;
                o.color = v.color;
                return o;
            }

            half4 frag (v2f i) : SV_Target
            {
                //需要深度图进行遮挡计算，通过传入光源的屏幕坐标，用屏幕坐标xy值读取深度图与其z值作比较判断是否被遮挡，算法如下 已经废弃
                // half depthMask = SAMPLE_TEXTURE2D(_CameraDepthTexture, sampler_CameraDepthTexture, _FlareScreenPos.xy).r;
                // half depthTex = LinearEyeDepth(depthMask, _ZBufferParams);
                // half needRender = lerp(saturate(depthTex - _FlareScreenPos.z), 1 - ceil(depthMask), _FlareScreenPos.w);
                half4 col = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, i.uv.xy)/* * needRender*/ * i.color;
                return col;
            }
            ENDHLSL
        }
    }
}
