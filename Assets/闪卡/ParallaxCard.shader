Shader "Ashader/StarRailCard/ParallaxCard"
{
    Properties
    {
    [Header(Base)]    
        _MainTex ("MainTex", 2D) = "white" {}
        _MainColor("Color", Color) = (1,1,1,1)
        _MaskTex("Mask", 2D) = "white" {}
    [Space(5)]    
    [Header(Stencial)]    
        _ID("Mask ID", Int) = 1
        [Enum(UnityEngine.Rendering.CompareFunction)] _Scomp ("StencilComp",Float) = 8
        [Enum(UnityEngine.Rendering.StencilOp)] _Sop ("Stencil Op",Float) = 2
    [Space(5)]    
    [Header(Parallax)]    
        _HeightMap("HeightMap", 2D) = "white" {}
        _ParallaxStrength("ParallaxStrength", Range(-0.5, 0.5)) = 0.01
    [Space(5)]    
    [Header(Blink)]     
        _BlinkTex("BlinkTex", 2D) = "white" {}
        [HDR]_BlinkCol("BlinkColor", Color) = (1,1,1,1)
        _GlitterArea ("BlinkArea", Range(0.01, 0.5)) = 0.1
        _GlitterCount ("BlinkCount", Float) = 3
        _GlitterSpeed ("BlinkSpeed", Float) = 1
        _GlitterStart("BlinkStart", Range(0,2)) = 0
    }
    SubShader
    {
        Tags { "RenderType"="Transparent" "Queue" = "Transparent+3" }
        Blend SrcAlpha OneMinusSrcAlpha
        
        Stencil
        {
            Ref [_ID]
            Comp [_Scomp]
            Pass[_Sop]
        }
        
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"
            #include "SRCShaderFunction.cginc"
            
            sampler2D _MainTex;
            half4 _MainColor;
            sampler2D _MaskTex;
            
            sampler2D _HeightMap;
            half _ParallaxStrength;
            
            sampler2D _BlinkTex;float4 _BlinkTex_ST;
            float4 _BlinkCol;
            half _GlitterArea;
            half _GlitterCount;
            half _GlitterSpeed;
            half _GlitterStart;

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
                float3 normal : NORMAL;
                float4 tangent : TANGENT;
            };

            struct v2f
            {
                half2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
                half3 nDir : TEXCOORD1;
                half3 posWS : TEXCOORD2;
                half3 tDir : TEXCOORD3;
                half3 bDir : TEXCOORD4;
                half2 uv2 : TEXCOORD5;
            };
            
            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv2 = TRANSFORM_TEX(v.uv, _BlinkTex);
                o.uv = v.uv;
                o.nDir = UnityObjectToWorldNormal(v.normal);
                o.posWS = mul(unity_ObjectToWorld, v.vertex);
                o.tDir = UnityObjectToWorldDir(v.tangent);
                o.bDir = cross(o.nDir, o.tDir) * v.tangent.w;
                return o;
            }

            half4 frag (v2f i) : SV_Target
            {
                half3 vDir = UnityWorldSpaceViewDir(i.posWS);//世界空间观察方向反映相对于物体世界为之的观察方向，摄像机不变时基本不变
                float3x3 TBN = float3x3(i.tDir, i.bDir, i.nDir);
                half3 vDirTS = normalize(mul(TBN, vDir));//使用切线空间观察方向，反映相对物体表面的观察角度，物体自转也会发生变化
            //视差
                half4 Character = ParallaxTex(_HeightMap, _MainTex, i.uv, vDirTS, _ParallaxStrength) * _MainColor;
            //闪烁
                half4 BlinkTex = tex2D(_BlinkTex, i.uv2);
                //使用vDirTS.x - 0.5 * vDirTS.y，条纹约为卡牌对角线方向
                half StripeMask = StripeGlitter((vDirTS.x - 0.5 * vDirTS.y),_GlitterCount, _GlitterSpeed, _GlitterArea, _GlitterStart);//闪烁的核心：条纹遮罩
                //构建条纹状闪烁纹理遮罩
                half BlinkMask = min(StripeMask, BlinkTex.a);
                //使闪烁纹理只影响角色区域
                BlinkMask = lerp(Character.a,BlinkMask,Character.a);
                //透明处为黑色，之后叠加不影响最终颜色；不透明处颜色为_BlinkCol，与角色图有叠加效果
                half3 BlinkMain = lerp(0, BlinkTex.rgb, BlinkMask) * _BlinkCol;
                half4 Blink = half4(BlinkMain,BlinkMask);
            //最终处理
                //卡面遮罩
                half CardMask = tex2D(_MaskTex, i.uv).a;
                //Character.rgb = lerp(Character, BlinkMain, BlinkMask);//闪烁纹理是否有透明感
                Character = lerp(0,Character,CardMask);
                return half4(saturate(Character + Blink));//防止超过1
            }
            ENDCG
        }
    }
}