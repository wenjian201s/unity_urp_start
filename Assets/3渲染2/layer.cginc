#ifndef FUR_INCLUDE
#define FUR_INCLUDE

#include "UnityCG.cginc"
#include "Lighting.cginc"

struct appdata
{
    float3 normal : NORMAL;
    float4 vertex : POSITION;
    float2 uv : TEXCOORD0;
};

struct v2f
{
    float2 uv : TEXCOORD0;
    float2 uv_layer : TEXCOORD1;
    float4 vertex : SV_POSITION;
};

float _Length;
sampler2D _MainTex;
sampler2D _LayerMap;
float4 _MainTex_ST;
float4 _LayerMap_ST;
float _AO;

v2f vert_fur(appdata v, float layer_offset)
{
    v2f o;
    v.vertex.xyz += v.normal * _Length * layer_offset;
    o.vertex = UnityObjectToClipPos(v.vertex);
    o.uv = TRANSFORM_TEX(v.uv, _MainTex);
    o.uv_layer = TRANSFORM_TEX(v.uv, _LayerMap);

    return o;
}

fixed4 frag_fur(v2f i, float layer_offset) 
{
    float alpha = tex2D(_LayerMap, i.uv_layer).r;//读取layer纹理
    
    alpha = step(layer_offset, alpha); //雕刻毛发
    alpha *= 1-layer_offset; //透明度衰减计算
    fixed4 col = fixed4(tex2D(_MainTex, i.uv).rgb, alpha);//应用上述得到的透明度
    
    col.xyz *= pow(layer_offset, _AO ); //AO计算

    return col;
}

#endif
