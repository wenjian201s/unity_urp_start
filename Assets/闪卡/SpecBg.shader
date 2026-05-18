Shader "Ashader/StarRailCard/SpecBg"
{
    Properties
    {
    [Header(Background)]   
        _MainTex ("Background", 2D) = "white" {}
        _BgColor("BgColor", Color) = (1,1,1,1)
    [Space(5)]    
    [Header(Parallax)]  
        _HeightMap("HeightMap", 2D) = "white" {}
        _ParallaxStrength("ParallaxStrength", Range(-0.5, 0.5)) = 0.01
    [Space(5)]    
    [Header(Stencial)]     
        _ID("Mask ID", Int) = 1
        [Enum(UnityEngine.Rendering.CompareFunction)] _Scomp ("StencilComp",Float) = 8
        [Enum(UnityEngine.Rendering.StencilOp)] _Sop ("Stencil Op",Float) = 2
    [Space(5)]    
    [Header(Laser)]        
        [HDR]_LaserColor ("LaserCol", Color) = (1,1,1,1)
        _RepeatAmount("RepeatAmount", Range(0,5)) = 1
    [Space(5)]    
    [Header(Blink)]      
        _GridSize ("GridSize", Float) = 50
        _GridGlitterArea ("GridGlitterArea", Range(0, 0.5)) = 0.1
        _GridGlitterCount ("GridGlitterCount", Float) = 3
        _GridGlitterSpeed ("GridGlitterSpeed", Float) = 1
        _GlitterArea ("BlinkArea", Range(0, 4)) = 0.1
        _GlitterCount ("BlinkCount", Float) = 3
        _GlitterSpeed ("BlinkSpeed", Float) = 1
        _GlitterStart("BlinkStart", Range(0,2)) = 0
    }
    SubShader
    {
        Tags { "RenderType"="Transparent" "Queue" = "Transparent+2" }
        
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
            
            sampler2D _MainTex; float4 _MainTex_ST;
            half4 _BgColor;
            
            sampler2D _HeightMap;
            half _ParallaxStrength;
            
            half4 _LaserColor;
            half _RepeatAmount;
            
            half _GridSize;
            half _GridGlitterArea;
            half _GridGlitterCount;
            half _GridGlitterSpeed;
            half _GlitterStart;
            
            half _GlitterArea;
            half _GlitterCount;
            half _GlitterSpeed;

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
                float3 posWS : TEXCOORD2;
                half3 tDir : TEXCOORD3;
                half3 bDir : TEXCOORD4;
                half2 uv2 : TEXCOORD5;//防止亮片受背景UV拉伸影响
            };

            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                o.uv2 = v.uv;
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
                half4 Background = ParallaxTex(_HeightMap, _MainTex, i.uv, vDirTS, _ParallaxStrength) * _BgColor;
            //条纹遮罩
                half StripeMask = StripeGlitter(vDirTS.x - vDirTS.y, _GlitterCount, _GlitterSpeed, _GlitterArea, _GlitterStart);
            //镭射
                half3 LaserCol = HueOffset(_LaserColor, _RepeatAmount * (vDirTS.y - vDirTS.x));
            //闪烁    
                //使用vDirTS.x - vDirTS.y，对角线方向渐隐
                half GridMask = GridGlitter(i.uv2, (vDirTS.x - vDirTS.y), _GridSize, _GridGlitterCount, _GridGlitterSpeed, _GridGlitterArea);
                //使得原有的格子遮罩也受条纹遮罩的影响，有闪烁感
                half BlinkMask = min(StripeMask, GridMask);
                half4 BlinkCol = half4(LaserCol, BlinkMask);
                //使得不透明处颜色为0，叠加后不影响原颜色
                BlinkCol.rgb = lerp(0,BlinkCol.rgb, BlinkMask);
                //防止大于1
                return half4(saturate(Background + BlinkCol));
            }
            ENDCG
        }
    }
}