Shader "Ashader/StarRailCard/CardFrame"
{
    Properties
    {
        _MainTex ("CardFrame", 2D) = "white" {}
        [HDR]_LaserCol ("LaserCol", Color) = (1,1,1,1)
        _AnisoPow("AnisotropyPower", Range(0,100)) = 30
        _CutOff("CutOff", Range(0,1)) = 0
        _RepeatAmount("RepeatAmount", Range(0,5)) = 1
        
        _GridSize ("GridSize", Float) = 50
        _GridGlitterArea ("GridGlitterArea", Range(0, 0.5)) = 0.1
        _GridGlitterCount ("GridGlitterCount", Float) = 3
        _GridGlitterSpeed ("GridGlitterSpeed", Float) = 1
        [HDR]_GridCol("GridColor", Color) = (1,1,1,1)
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" "Queue" = "Geometry+1" }
        LOD 100

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"
            #include "SRCShaderFunction.cginc"

            sampler2D _MainTex;float4 _MainTex_ST;
            half4 _LaserCol;
            half _AnisoPow;
            half _CutOff;
            half _RepeatAmount;
            
            half _GridSize;
            half _GridGlitterArea;
            half _GridGlitterCount;
            half _GridGlitterSpeed;
            half4 _GridCol;
            
            
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
            };      
            
            
            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);
                o.nDir = UnityObjectToWorldNormal(v.normal);
                o.posWS = mul(unity_ObjectToWorld, v.vertex);
                o.tDir = UnityObjectToWorldDir(v.tangent);
                o.bDir = cross(o.nDir, o.tDir) * v.tangent.w;
                return o;
            }

            half4 frag (v2f i) : SV_Target
            {
                half3 vDir = UnityWorldSpaceViewDir(i.posWS);//世界空间观察方向反映相对于物体世界位置的观察方向，摄像机不变时基本不变
                float3x3 TBN = float3x3(i.tDir, i.bDir, i.nDir);
                half3 vDirTS = normalize(mul(TBN, vDir));//使用切线空间观察方向，反映相对物体表面的观察角度，物体自转也会发生变化
                
                half3 lDir = normalize(UnityWorldSpaceLightDir(i.posWS));
                half3 hDir = normalize(lDir + vDir);
                half3 tDir = normalize(i.tDir);
                half3 bDir = normalize(i.bDir);
                half3 diagonalDir = normalize(tDir - bDir);//对角线方向
            //各向异性高光
                half AnisoSpec = Anisotropy(diagonalDir, hDir, _AnisoPow);
            //镭射
                //色带方向是对角线方向
                //本身应该呈现_LaserCol的颜色，对色相进行偏移后，中间部分还是原来的颜色，顺着偏移向量的方向为正偏移量,会使原颜色在色环上的角度增大，反之减小，从而呈现出冷暖色带
                half3 LaserCol = HueOffset(_LaserCol, _RepeatAmount * (vDirTS.y - vDirTS.x));
            //格子遮罩
                //使用vDirTS.x分量实现x方向渐隐
                half GridMask = GridGlitter(i.uv, vDirTS.x, _GridSize, _GridGlitterCount, _GridGlitterSpeed, _GridGlitterArea);
                half3 GridCol = lerp(0,_GridCol,GridMask);//使用自定义的颜色
                half4 Cardframe = tex2D(_MainTex, i.uv);
                Cardframe.rgb = lerp(Cardframe.rgb, GridCol + LaserCol , AnisoSpec);//主色为GridCol,LaserCol较淡，叠加用于提亮
                
                clip(Cardframe.a - _CutOff);
                return half4(Cardframe.rgb,1.0);
            }
            ENDCG
        }
    }
}