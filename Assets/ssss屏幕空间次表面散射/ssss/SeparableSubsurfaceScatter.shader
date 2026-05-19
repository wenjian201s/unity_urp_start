Shader "PostProcess/SeparableSubsurfaceScatter"
{
    Properties
    {
        _MainTex ("Source", 2D) = "white" {}
        _SSSScale ("SSS Scale", Float) = 0.1
        _SSSDepthEdgeFalloff ("Depth Edge Falloff", Float) = 300
        _SSSProjectionDistance ("Projection Distance", Float) = 5.671
        _SampleCount ("Sample Count", Int) = 25
        _StencilRef ("Stencil Reference", Int) = 5
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "RenderType" = "Opaque"
        }

        Cull Off
        ZWrite Off
        ZTest Always

        Pass
        {
            Name "XBlur"

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragX
            #include "SeparableSubsurfaceScatterCommon.cginc"
            ENDHLSL
        }

        Pass
        {
            Name "YBlur"

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragY
            #include "SeparableSubsurfaceScatterCommon.cginc"
            ENDHLSL
        }

        Pass
        {
            Name "Composite"

            Stencil
            {
                Ref [_StencilRef]
                Comp Equal
                Pass Keep
            }

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragComposite
            #include "SeparableSubsurfaceScatterCommon.cginc"
            ENDHLSL
        }

        Pass
        {
            Name "CompositeNoStencil"

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragComposite
            #include "SeparableSubsurfaceScatterCommon.cginc"
            ENDHLSL
        }

        Pass
        {
            Name "DebugStencilMask"

            Stencil
            {
                Ref [_StencilRef]
                Comp Equal
                Pass Keep
            }

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragDebugStencil
            #include "SeparableSubsurfaceScatterCommon.cginc"
            ENDHLSL
        }

        Pass
        {
            Name "DebugFullscreenTint"

            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex Vert
            #pragma fragment FragDebugTint
            #include "SeparableSubsurfaceScatterCommon.cginc"
            ENDHLSL
        }
    }

    Fallback Off
}
