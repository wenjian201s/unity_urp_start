#ifndef FUR_INCLUDE
#define FUR_INCLUDE

#include "UnityCG.cginc"
#include "Lighting.cginc"


struct appdata
{
    float3 postion : POSITION;
    float3 normal:NORMAL;
    float2 uv  : TEXCOORD0;
};

struct v2f
{
    float4 HPOS    : POSITION;
    float2 T0     : TEXCOORD0; // 毛发纹理UV
    float2 T1     : TEXCOORD1; //毛发生成噪声纹理UV
    float3 normal : TEXCOORD2; // 世界空间法线
};

sampler2D FurTexture;
float4 _MainTex_ST;
float FurLength;
float UVScale;
float Layer;
float4 vGravity;
sampler2D _LayerMap;
float4 FurTexture_ST;
float4 _LayerMap_ST;
float _EdgeFade;
v2f vert_1 (appdata v,float layer_offset,int layer_num)
{
    v2f o;
    float3 p =v.postion.xyz+(v.normal*FurLength*layer_offset); //法线外扩
    
    float noraml=normalize(mul(unity_ObjectToWorld, v.normal)); //世界坐标法线
    
    vGravity =mul(unity_ObjectToWorld,vGravity); //重力计算
    float k=pow(layer_num/30,3);
        // 把重力也变换到世界空间
        // 用 pow 让只有发梢弯曲：
        // Layer 从 0→1，pow 后仍是 0→1，
        // 但增长更快（指数级）
        // 根据层高度叠加弯曲量
   
    p = p + vGravity*k;
                
    v.uv=v.uv*UVScale;
    o.T0=TRANSFORM_TEX(v.uv,FurTexture);
    o.T1=TRANSFORM_TEX(v.uv,_LayerMap);
    o.HPOS=UnityObjectToClipPos(p);
    o.normal=noraml;
    return o;
}

fixed4 frag_1 (v2f i,float layer_offset) : SV_Target
{
  
    // sample the texture
    float3 FurColour = tex2D(FurTexture, i.T0).rgb;// 采样毛发纹理——Alpha 非常关键
    float layer_alpha=tex2D(_LayerMap,i.T1).r; //采样毛发层级alpga值
    layer_alpha=step(layer_offset,layer_alpha);
    
   
   
    float4 FinalColour=float4(FurColour.rgb,layer_alpha);
    float4 ambient = {0.3, 0.3, 0.3, 1.0};
    ambient = ambient * FinalColour;

    float4 diffuse = FinalColour;
    FinalColour = ambient + diffuse * dot(_WorldSpaceLightPos0, i.normal);

    fixed alpha = tex2D(_LayerMap, i.T1).rgb;
        

    return float4(FinalColour.xyz,alpha);
                
   
  
}


#endif
