Shader "Universal Render Pipeline/skin"
{
    Properties
    {
        //基础
        [Header(Base)]
        [Toggle(_COMPUTED_ADDITIONALLIGHT)] _ShowTry_Key("COMPUTED_ADDITIONALLIGHT",Float) = 0
        [NoScaleOffset]_albedoTex("albedoTex(thickness)", 2D) = "white" {}
        [NoScaleOffset]_normalTex("normalTex(curvature)", 2D) = "white" {}
        [NoScaleOffset]_sssTex("sssTex", 2D) = "white" {} 
        [NoScaleOffset]_sheen_RougnessTex("sheen_RougnessTex", 2D) = "white" {}  
        _rougnessLow("rougnessLow",Range(0,1))=0.5
        _rougnessHigh("rougnessHigh",Range(0,1))=0.5
        _phongIntensity("phongIntensity",Range(10,200))=100

         //透射
        [Space()]
        [Space()]
        
        [Header(BTDF)]
        [Space()]
        _translucencyCol("_translucencyCol",Color)=(1,1,1,1)
        _distortion("_distortion",Range(0,1))=0.1
        _btdfIntensity("_btdfIntensity",Range(0,100))=1
        _power("_power",Range(1,2))=1   
        
        //sheen
        [Space()]
        [Space()]
        [Header(Sheen)]
        [Space()]
        _sheenColor("sheenColor",Color)=(1,1,1,1)
        _sheenIntensity("sheenIntensity",Range(0,1))=1
        _sheenRougness("sheenRougness",Range(0,1))=0.5
        
    }
    SubShader
    {
        Tags { "RenderType"="Opaque"  "RenderPipeline" = "UniversalPipeline" "IgnoreProjector" = "True" "ShaderModel"="4.5" }
        LOD 100

        Pass
        {
        Tags{"LightMode" = "UniversalForward"}
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
 	        
            #pragma multi_compile_fragment _ _COMPUTED_ADDITIONALLIGHT
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
	    #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
	    #pragma multi_compile _ _SHADOWS_SOFT
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS 
     
         CBUFFER_START(UnityPerMaterial)
           half _rougnessLow;
           half _rougnessHigh;
           half _phongIntensity;
           half3 _translucencyCol;
           half _distortion;
           half _btdfIntensity;
           half  _power;   
           half3 _sheenColor;
           half _sheenIntensity;
           half _sheenRougness;
        CBUFFER_END
        TEXTURE2D(_albedoTex);     SAMPLER(sampler_albedoTex);
        TEXTURE2D(_normalTex);     SAMPLER(sampler_normalTex);
        TEXTURE2D(_sssTex);        SAMPLER(sampler_sssTex);
        TEXTURE2D(_sheen_RougnessTex); SAMPLER(sampler_sheen_RougnessTex);
        

    struct VertexInput
     {
        float4 positionOS  : POSITION;
        float2 uv : TEXCOORD0;
        float4 normalOS  : NORMAL;
	float4 tangentOS  : TANGENT;
     };
    struct VertexOutput
    {
        float2 uv : TEXCOORD0;
        float4 position : SV_POSITION;
        float3 positionWS :  TEXCOORD1;
	float3 normalWS : TEXCOORD2;
	float3 tangentWS : TEXCOORD3;
	float3 bitangentWS : TEXCOORD4;
    };            
    VertexOutput vert (VertexInput v)
    {
        VertexOutput o;
	VertexPositionInputs positionInputs = GetVertexPositionInputs(v.positionOS.xyz);
        VertexNormalInputs normalInputs = GetVertexNormalInputs(v.normalOS.xyz,v.tangentOS);
                
        o.uv =v.uv;
        o.normalWS=normalInputs.normalWS ;
	o.tangentWS = normalInputs.tangentWS;
	o.bitangentWS= normalInputs.bitangentWS;
        o.positionWS=positionInputs.positionWS;
        o.position = positionInputs.positionCS;
        return o;
   }

    struct SkinData
   {
          //基础参数
          float3 normalTS;
          half3 albedo;
          half rougnessLow;
          half rougnessHigh;
          half phongIntensity;
          //透射参数
          half thickness;
          half3 translucencyCol;
          half distortion;
          half btdfIntensity;
          half power;
          //预积分sss参数
          half curvature;

          //sheen
          half sheenRougness;
          half3 sheenColor;
          half sheenIntensity;
    };

    void InitializeSkinData(float2 uv ,out SkinData outSkinData)
    {      
      outSkinData=(SkinData)0;
      half4 _albedo = SAMPLE_TEXTURE2D(_albedoTex,sampler_albedoTex, uv);
      half4 _normal = SAMPLE_TEXTURE2D(_normalTex,sampler_normalTex, uv);
      half4 _sss = SAMPLE_TEXTURE2D(_sssTex,sampler_sssTex, uv);
      half4 _sheen_Rougness = SAMPLE_TEXTURE2D(_sheen_RougnessTex,sampler_sheen_RougnessTex, uv);
      outSkinData.albedo=_albedo.xyz;
      outSkinData.curvature=_normal.w;
      outSkinData.normalTS=UnpackNormal(_normal); 
      outSkinData.phongIntensity=_phongIntensity;
      outSkinData.rougnessLow=PerceptualRoughnessToRoughness(_rougnessLow);
      outSkinData.rougnessHigh=PerceptualRoughnessToRoughness(_rougnessHigh*_sheen_Rougness.y);
      
      outSkinData.thickness=_albedo.w;
      outSkinData.translucencyCol=_translucencyCol;
      outSkinData.distortion=_distortion;
      outSkinData.btdfIntensity=_btdfIntensity;
      outSkinData.power=_power;
      
      outSkinData.sheenColor=_sheenColor;
      outSkinData.sheenIntensity=_sheenIntensity*_sheen_Rougness.x;
      outSkinData.sheenRougness=PerceptualRoughnessToRoughness(_sheenRougness);
      
    }
    //皮肤三种特性的着色计算
    half3 LightingSheen(Light li,SkinData sk,float3 viewDir,float3 normalWS)
    {
       float cosVal=dot(viewDir,normalWS);
       float sinVal= sqrt(1-cosVal);
       float D_sheen=(2+1/sk.sheenRougness)*pow(sinVal,1/sk.sheenRougness)*sk.sheenIntensity;      
       return D_sheen*sk.sheenColor;
    }
    half3 LightingSss(float3 lightDir,half curvature ,float3 normalWS)
    {
      float nDotl=saturate(dot(normalWS,lightDir));
      half3 sss = SAMPLE_TEXTURE2D(_sssTex,sampler_sssTex, float2(nDotl,-curvature)).xyz;
      return sss;
    }
    half3 LightingBtdf(Light li,SkinData sk,float3 viewDir,float3 normalWS)
    {
        half3 lightDir=normalize(li.direction+normalWS*sk.distortion);
        half vDotl= pow(saturate(dot(viewDir,-lightDir)),sk.power)*sk.btdfIntensity;
        half btdf= li.distanceAttenuation*(vDotl+0.4)*sk.thickness;
        half3 col=li.color*btdf*sk.translucencyCol;
        return col;            
    }
    //双层高光计算,用blinnphong模拟光滑的油脂层
    half3 LightingBlinnPhong(SkinData skinData,half3 color,half3 normalWS, half3 lightDirectionWS, half3 viewDirectionWS)
    {
      //计算blinnphongSpecular
       half3 halfDir = normalize(lightDirectionWS + viewDirectionWS);
       half nDoth = dot(normalWS,halfDir);
       half3 phongSpecular =pow(max(0,nDoth),skinData.phongIntensity)*skinData.rougnessHigh*color;      
       return phongSpecular;
    }
    //单个光源的皮肤最终着色计算
    half3 LightingSkin(BRDFData brdfData,SkinData skinData,Light li,float3 normalWS,float3 normalWSnomap, half3 viewDirectionWS)             
   {
     float3 lightDir=normalize(li.direction);    
     half NdotL = saturate(dot(normalWS, lightDir));
     half3 sss= LightingSss(lightDir,skinData.curvature, normalWSnomap);
     half3 radiance = li.color * (li.distanceAttenuation * NdotL)*sss;
     half3 brdf=brdfData.diffuse;
     brdf+=brdfData.specular*DirectBRDFSpecular(brdfData,normalWS,lightDir,viewDirectionWS);
     half3 blinn=LightingBlinnPhong(skinData,li.color,normalWS,lightDir,viewDirectionWS);
     half3 btdf=LightingBtdf(li,skinData,viewDirectionWS,normalWS);
     
     //计算阴影,不影响btdf部分
     return (brdf*radiance+blinn)*li.shadowAttenuation+btdf;

    }

    half4 frag(VertexOutput i) : SV_Target
    {
        //准备数据
        half alpha=1;
	SkinData skinData;
        BRDFData brdfData;
        InitializeSkinData(i.uv,skinData);
        half Smoothness=1-skinData.rougnessLow;
        InitializeBRDFData(skinData.albedo,(half)0,kDielectricSpec.x,Smoothness,alpha, brdfData);        
        float3 normalWS = TransformTangentToWorld(skinData.normalTS,real3x3(i.tangentWS, i.bitangentWS, i.normalWS));
       
        float4 shadowCoord = TransformWorldToShadowCoord(i.positionWS.xyz);
        float3 viewDir=GetWorldSpaceNormalizeViewDir(i.positionWS);
        Light mainLight = GetMainLight(shadowCoord);
        //计算主光源
        half3 finalCol=LightingSkin(brdfData,skinData,mainLight,normalWS,i.normalWS,viewDir);
       
       //当urp逐片元额外光和自定义的计算额外光变体开启时执行额外光计算
       #if defined (_COMPUTED_ADDITIONALLIGHT)&&_ADDITIONAL_LIGHTS
       uint pixelLightCount = GetAdditionalLightsCount();
       LIGHT_LOOP_BEGIN(pixelLightCount)
       Light light = GetAdditionalLight(lightIndex,i.positionWS);
       finalCol+=LightingSkin(brdfData,skinData,light,normalWS,i.normalWS,viewDir);    
       LIGHT_LOOP_END
       #endif
       half3 sheen=LightingSheen(mainLight,skinData,viewDir, normalWS);
       
       half3 bakedGI = SampleSH(normalWS);
       half3 gi= GlobalIllumination(brdfData,bakedGI,(half)1,normalWS,viewDir);

       finalCol+=gi+sheen;
       return half4(finalCol,1);  
       }
    ENDHLSL
    }
    UsePass "Universal Render Pipeline/Lit/ShadowCaster"
  }
  FallBack "Hidden/Universal Render Pipeline/FallbackError"

}