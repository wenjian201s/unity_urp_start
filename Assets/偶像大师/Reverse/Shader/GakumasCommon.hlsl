#ifndef _GAKUMAS_COMMON_INCLUDED
#define _GAKUMAS_COMMON_INCLUDED

#include "Library/PackageCache/com.unity.render-pipelines.core@14.0.12//ShaderLibrary/Common.hlsl"
#include "Library/PackageCache/com.unity.render-pipelines.core@14.0.12/ShaderLibrary/API/D3D11.hlsl"
#include "Library/PackageCache/com.unity.render-pipelines.universal@14.0.12/ShaderLibrary/BRDF.hlsl"
#include "Library/PackageCache/com.unity.render-pipelines.universal@14.0.12/ShaderLibrary/GlobalIllumination.hlsl"
#include "Library/PackageCache/com.unity.render-pipelines.universal@14.0.12/ShaderLibrary/Input.hlsl"
#include "Library/PackageCache/com.unity.render-pipelines.core@14.0.12/ShaderLibrary/SpaceTransforms.hlsl"
#include "Library/PackageCache/com.unity.render-pipelines.core@14.0.12/ShaderLibrary/Texture.hlsl"

// A、B、C的取值范围都是[0, 1]
//因为顶点颜色 是float4它实际上是由两个4位向量编码而成的8位向量（0到255）。每个4位向量有4个分量，每个分量是4位，所以每个分量可以表示0到15的整数（即16种可能）
void Encode4BitTo8Bit(float4 A, float4 B, out float4 C) //将顶点颜色从4bit编码进8Bit  
{
	////将输入值A和B从[0,1]范围映射到[0,15]的整数范围
	float4 HighBit = floor(A * 15.9375f + 0.03125f); 
	float4 LowBit = floor(B * 15.9375f + 0.03125f);
	//将高位(A)左移4位，然后与低位(B)相加
	C = (HighBit * 16.0f + LowBit) / 255.0f; //结果除以255，使其回到[0,1]范围
}

// A、B、C的取值范围都是[0, 1]

void Decode4BitFrom8Bit(float4 C, out float4 A, out float4 B) //将8bit 解码出真实颜色数据
{
	//将点的颜色从0到1转换到0到255
	const float k = 1.0f / 15.0f;
	float4 HighBit = floor(C * 15.9375f + 0.03125f); //将颜色从从【0，1】转换到【0，255】 在这里获取4高位
	float4 LowBit = C * 255.0f - HighBit * 16.0f; //将颜色从【0，1】转换到【0，255】 从这里减去高位 获取低位

	//将结果除以15，使其回到[0,1]范围
	A = HighBit * k;
	B = LowBit * k;

	
}

struct G_VertexColor //存储顶点颜色 用于组织和存储从顶点颜色解码出的各种参数，
{
	float4 OutLineColor; //描边颜色
	float OutLineWidth; //描边宽度
	float OutLineOffset; //描边偏移值
	float RampAddID; // Ramp贴图渐变ID
	float RimMask; //边缘光遮罩
};

G_VertexColor DecodeVertexColor(float4 VertexColor) //负责将输入的float4顶点颜色解码为G_VertexColor结构体
{  //从输入的顶点颜色解码出 G_VertexColor相关数据 因为模型顶点自带存储多个数据
	G_VertexColor OutColor; //颜色参数结构体
	float4 LowBit, HighBit; //解码接收值
	Decode4BitFrom8Bit(VertexColor, HighBit, LowBit); //将顶点颜色解码
	// 描边颜色：R: HighBit.x (高位向量的x分量)  G: LowBit.x (低位向量的x分量) B: HighBit.y (高位向量的y分量) A: LowBit.w (低位向量的w分量)
	
	OutColor.OutLineColor = float4(HighBit.x, LowBit.x, HighBit.y, LowBit.w); 
	OutColor.OutLineWidth = LowBit.z; //描边宽度(OutLineWidth): LowBit.z (低位向量的z分量)
	OutColor.OutLineOffset = HighBit.z; //描边偏移(OutLineOffset): HighBit.z (高位向量的z分量)
	OutColor.RampAddID = LowBit.y; //渐变ID(RampAddID): LowBit.y (低位向量的y分量)
	OutColor.RimMask = HighBit.w; //边缘光遮罩(RimMask): HighBit.w (高位向量的w分量)
	
	return OutColor; //输出解码后的顶点存储的数据参数
}


//实例化BRDF数据 //根据基础颜色、光滑度、金属度等参数，初始化Unity URP内置的BRDFData结构体，为后续的PBR计算做准备。 （该BRDF用于眼睛材质进行特殊处理）
BRDFData G_InitialBRDFData(float3 BaseColor, float Smoothness, float Metallic, float Specular, bool IsEye)
{
	float OutAlpha = 1.0f;
	BRDFData G_BRDFData;
	InitializeBRDFData(BaseColor, Metallic, Specular, Smoothness, OutAlpha, G_BRDFData); //将输入的参数数据进行BRDF计算传递到 BRDFData数据里

	
	//IsEye //判断是不是眼睛 如果不是保存原样
	//  特殊处理眼睛材质 
	// 如果是眼睛材质，使用特殊的光滑度计算方式 
	// grazingTerm: 掠射角反射项，控制光线在掠射角度的反射强度
	//使用smoothness + kDieletricSpec.x来计算掠射角反射项
	//kDieletricSpec.x是URP中定义的电介质材质的基础反射率（通常为0.04）  这样处理使得眼睛材质在掠射角度有更强的反射效果
	G_BRDFData.grazingTerm = IsEye ? saturate(Smoothness + kDieletricSpec.x) : G_BRDFData.grazingTerm;

	// 特殊处理眼睛材质的漫反射
	// 眼睛材质的漫反射部分使用基础颜色乘以电介质高光系数
	// kDieletricSpec.a是电介质材质的高光反射率（通常为0.04）  kDieletricSpec.a通常是1.0 - kDieletricSpec.x	即0.9
	//这样处理减少了眼睛材质的漫反射强度，使其更接近真实眼睛的光学特性
	G_BRDFData.diffuse = IsEye ? BaseColor * kDieletricSpec.a : G_BRDFData.diffuse;
	
	// 特殊处理眼睛材质的高光反射
	// 眼睛材质的高光反射直接使用基础颜色
	G_BRDFData.specular = IsEye ? BaseColor : G_BRDFData.specular; 
	
	return G_BRDFData;
}

//一个自定义的镜面反射计算函数，用于替代URP内置的函数，以实现更符合卡通风格的镜面高光效果。
half G_DirectBRDFSpecular(BRDFData BrdfData, half3 NormalWS, half3 NormalMatS, float4 LightDir, float3 ViewDir) //计算BRDF的镜面反射值 采样MATCAP
{
	//    // 判断是否禁用MatCap模式
	// LightDir.w > 0.5f 表示禁用MatCap，使用标准光照计算
	bool DisableMatCap = LightDir.w > 0.5f;
	//  根据MatCap状态选择观察方向
	// 禁用MatCap时使用实际观察方向，启用时使用固定前向方向(0,0,1)
	ViewDir = DisableMatCap ? ViewDir : float3(0.0f, 0.0f, 1.0f); 
    float3 HalfDir = SafeNormalize(LightDir.xyz + ViewDir); // 计算半角向量（光线方向和视线方向的中间向量）

	// 根据MatCap状态选择使用的法线
	// 禁用MatCap时使用世界空间法线，启用时使用材质空间法线
	float3 Normal = DisableMatCap ? NormalWS : NormalMatS;
	// 计算法线与半角向量的点积，并限制在[0,1]范围
	// NoH值越大，高光反射越强
    float NoH = saturate(dot(float3(Normal), HalfDir)); //类似Blin phong 光照
	// 计算光线方向与半角向量的点积，并限制在[0,1]范围
	// 转换为half类型以节省计算资源
    half LoH = half(saturate(dot(LightDir.xyz, HalfDir)));

	// 计算GGX正态分布函数的分母部分
	// roughness2MinusOne = α² - 1，其中α = roughness²
	// 1.00001f是为了避免除零错误
    float D = NoH * NoH * BrdfData.roughness2MinusOne + 1.00001f;

	//// 计算LoH的平方值
    half LoH2 = LoH * LoH;
	 
	// 计算完整的高光反射项
	// 使用GGX/Trowbridge-Reitz正态分布函数
	// 分母包含(D * D)项、max(0.1h, LoH2)防止除零、以及归一化项
    half SpecularTerm = BrdfData.roughness2 / ((D * D) * max(0.1h, LoH2) * BrdfData.normalizationTerm);

    return SpecularTerm;
}

//材质参数声明 常量缓冲区
//声明所有材质参数：颜色、贴图、控制开关、Ramp、Rim、MatCap、反射等
cbuffer ShaderParameters : register(b0)
{
	float4 _BaseColor;
	float4 _DefValue;
	float _EnableLayerMap;
	float _RenderMode;
	float _BumpScale;
	float _AnisotropicScale;
	float4 _RampAddColor;
	float4 _RimColor;
	float _VertexColor;
	float4 _OutlineColor;
	float _EnableEmission;
	float _RefractThickness;
	float _DefDebugMask;
	float4 _SpecularThreshold;
	float4 _FadeParam;
	float _ShaderType;
	float _ClipValue;
	float _Cull;
	float _SrcBlend;
	float _DstBlend;
	float _SrcAlphaBlend;
	float _DstAlphaBlend;
	float _ColorMask;
	float _ColorMask1;
	float _ZWrite;
	float _StencilRef;
	float _StencilReadMask;
	float _StencilWriteMask;
	float _StencilComp;
	float _StencilPass;
	float _ActorIndex;
	float _LayerWeight;
	float _SkinSaturation;
	float4 _HeadDirection;
	float4 _HeadUpDirection;
	float4 _MultiplyColor;
	float4 _MultiplyOutlineColor;
	float _UseLastFramePositions;
	float4x4 _HeadXAxisReflectionMatrix;
	float4 _BaseMap_ST;
	float4 _MatCapParam;
	float4 _MatCapMainLight;
	float4 _MatCapLightColor;
	float4 _ShadeMultiplyColor;
	float4 _ShadeAdditiveColor;
	float4 _EyeHighlightColor;
	float4 _VLSpecColor;
	float4 _VLEyeSpecColor;
	float4 _MatCapRimColor;
	float4 _MatCapRimLight;
	float4 _GlobalLightParameter;
	float4 _ReflectionSphereMap_HDR;
	float4 _OutlineParam;
};


//采样贴图
Texture2D _BaseMap;
SAMPLER(sampler_BaseMap);
Texture2D _ShadeMap;
SAMPLER(sampler_ShadeMap);
Texture2D _RampMap;
SAMPLER(sampler_RampMap);
Texture2D _HighlightMap;
SAMPLER(sampler_HighlightMap);
Texture2D _DefMap;
SAMPLER(sampler_DefMap);
Texture2D _LayerMap;
SAMPLER(sampler_LayerMap);
Texture2D _BumpMap;
SAMPLER(sampler_BumpMap);
Texture2D _AnisotropicMap;
SAMPLER(sampler_AnisotropicMap);
Texture2D _RampAddMap;
SAMPLER(sampler_RampAddMap);
Texture2D _EmissionMap;
SAMPLER(sampler_EmissionMap);
Texture2D _ReflectionSphereMap;
SAMPLER(sampler_ReflectionSphereMap);
TextureCube _VLSpecCube;
SAMPLER(sampler_VLSpecCube);

struct appdata //顶点着色器输入数据
{
    float4 Position             : POSITION;  //顶点位置
    float3 Normal               : NORMAL;     //法线
    float4 Tangent              : TANGENT;   //切线
    float2 UV0                  : TEXCOORD0;     //第一组纹理坐标
    float2 UV1                  : TEXCOORD1;     //第二组纹理坐标
    float4 Color                : COLOR;       //顶点颜色
    float3 PrePosition          : TEXCOORD4;   //顶点在上一帧的位置 用于运动模糊（Motion Blur）效果的计算  
};

struct v2f
{
    float4 UV                   : TEXCOORD0;     
    float3 PositionWS           : TEXCOORD1;     
    float4 Color1               : COLOR;      
    float4 Color2               : TEXCOORD2;     
    float3 NormalWS             : TEXCOORD3;     
    float3 NormalHeadReflect    : TEXCOORD4;     
    float4 ShadowCoord          : TEXCOORD6;
    float4 PositionCSNoJitter   : TEXCOORD7;    
    float4 PrePosionCS          : TEXCOORD8;     
    float4 PositionCS           : SV_POSITION;
};


v2f vert( appdata v )
{
	v2f o;

	o.UV.xy = v.UV0 * _BaseMap_ST.xy + _BaseMap_ST.zw; //将第一组纹理坐标 乘以基础贴图的缩放值乘 偏移值 保存到xy
	o.UV.zw = v.UV1.xy; //将UV1保存到zw分量
	
	o.PositionWS = TransformObjectToWorld(v.Position); //将顶点转换到世界空间
	o.NormalWS = TransformObjectToWorldNormal(v.Normal); //将法线转换到世界空间

	// 使用头部反射矩阵变换法线
	// 这通常用于创建特殊的反射效果，特别是针对头部模型
	o.NormalHeadReflect = mul(_HeadXAxisReflectionMatrix, float4(v.Normal, 0.0f)).xyz;

	G_VertexColor VertexColor = DecodeVertexColor(v.Color); //解析顶点颜色数据 // 从顶点颜色中提取各种参数（描边颜色、宽度、偏移、渐变ID和边缘光遮罩）
	o.Color1 = VertexColor.OutLineColor; //// 将解码后的描边颜色保存到输出颜色1

	// 将其他解码参数打包到输出颜色2
	// x:描边宽度, y:描边偏移, z:渐变ID, w:边缘光遮罩
	o.Color2 = float4( 
		VertexColor.OutLineWidth,
		VertexColor.OutLineOffset,
		VertexColor.RampAddID,
		VertexColor.RimMask);

	// 计算阴影坐标
	// 用于后续的阴影采样和计算
	o.ShadowCoord = TransformWorldToShadowCoord(o.PositionWS);

	//// 准备世界空间位置（添加齐次坐标w=1.0）
	float4 PositionWS = float4(o.PositionWS, 1.0f);

	// 计算非抖动处理的裁剪空间位置
	// 用于某些后处理效果，如抗锯齿或运动模糊
	o.PositionCSNoJitter = mul(_NonJitteredViewProjMatrix, PositionWS);

	// 判断是否使用上一帧位置
	// 结合材质参数和Unity内置的运动向量参数 判断是否使用上帧遍历加上 顶点移动的偏移值 判断是否使用 选择上一帧的位置数据 解决运动模糊
	bool UseLastFramePositions = _UseLastFramePositions + unity_MotionVectorsParams.x > 1.0f;

	 // 将上一帧的对象空间位置转换到世界空间
	float3 LastFramePositionOS = UseLastFramePositions ? v.PrePosition : v.Position;
	// 将上一帧的对象空间位置转换到世界空间
	float4 LastFramePositionWS = mul(unity_MatrixPreviousM, LastFramePositionOS);
	// 计算上一帧的裁剪空间位置
	// 用于运动向量计算，实现运动模糊效果
	o.PrePosionCS = mul(_PrevViewProjMatrix, LastFramePositionWS);

	// 计算当前帧的裁剪空间位置
	// 这是顶点着色器的主要输出，用于光栅化
	o.PositionCS = TransformWorldToHClip(PositionWS);
	return o;
}

// 片段着色器函数
// 输入：v2f结构体（顶点着色器输出），SV_IsFrontFace指示是否为正面
// 输出：SV_Target（渲染目标颜色）
float4 frag( v2f i , bool IsFront : SV_IsFrontFace) : SV_Target
{

	//头发覆盖处理 这段代码是一个条件编译指令，用于处理一个名为HairCover的特殊渲染Pass。
	//用于渲染头发的半透明部分
	//如果当前正在渲染HairCover Pass，但材质属性中并未启用头发覆盖效果（_ENALBEHAIRCOVER_ON未定义），则调用clip(-1)函数。
	//clip函数会丢弃当前片段，使其不会被绘制到屏幕上。 
	// 头发覆盖通道检查 - 如果定义了IS_HAIRCOVER_PASS但没有启用_ENABLEHAIRCOVER_ON，则丢弃片段
	#if defined(IS_HAIRCOVER_PASS) && !defined(_ENALBEHAIRCOVER_ON) //判断当前是否在头发渲染pass 如果是判断是否开启_ENALBEHAIRCOVER_ON未定义 如果没有直接丢弃当前片段
		clip(-1);
	#endif
	
	G_VertexColor VertexColor;  // 从顶点着色器输出中重建顶点颜色参数结构体
	VertexColor.OutLineColor = i.Color1; //描边颜色
	VertexColor.OutLineWidth = i.Color2.x; //描边宽度
	VertexColor.OutLineOffset = i.Color2.y; //描边偏移值
	VertexColor.RampAddID = i.Color2.z;// rampID
	VertexColor.RimMask = i.Color2.w; //边缘光遮罩
	// 根据着色器类型标识判断当前渲染的材质类型
	bool IsFace = _ShaderType == 9;  //// 脸部材质
	bool IsHair = _ShaderType == 8; // 头发材质
	bool IsEye = _ShaderType == 4; // 眼睛材质
	bool IsEyeHightLight = _ShaderType == 5;// 眼睛高光材质
	bool IsEyeBrow = _ShaderType == 6; // 眉毛材质

	float3 NormalWS = normalize(i.NormalWS); //世界坐标法线归一化
	NormalWS = IsFront ? NormalWS : NormalWS * -1.0f; //判断是否是模型的正面 如果是用正面法线 如果不是使用 正面处理背面法线 将当前模型将法线方向取反

	// 判断是否为正交投影
	bool IsOrtho = unity_OrthoParams.w; // unity_OrthoParams.w == 1时表示正交投影
	
	float3 ViewVector = _WorldSpaceCameraPos - i.PositionWS; //获取片段指向摄像机的方向向量
	float3 ViewDirection = normalize(ViewVector); //视角向量归一化
	//可以将世界空间的向量（如法线）转换到MatCap空间，从而方便地使用一张球形环境贴图来模拟复杂的光照和反射效果。
	ViewDirection = IsOrtho ? unity_MatrixV[2].xyz : ViewDirection;//判断是正交还是透视投影 如果是透视投影使用片段指向摄像机的方向向量 如果是正交使用视图矩阵

	//构建世界空间到MatCap空间的变换矩阵
	float3 CameraUp = unity_MatrixV[1].xyz; //设置辅助的摄像机上向量
	float3 ViewSide = normalize(cross(ViewDirection, CameraUp)); //摄像机的上向量与方向向量叉积得出 切线向量 
	float3 ViewUp = normalize(cross(ViewSide, ViewDirection)); //摄像机的切线向量与摄像机的方向向量叉积计算正确的上向量
	float3x3 WorldToMatcap = float3x3(ViewSide, ViewUp, ViewDirection); //通过摄像机 切线向量 方向向量 上向量 构建摄像机视图矩阵

	//将世界空间法线变换到MatCap空间
	float3 NormalMatS = mul(WorldToMatcap, float4(NormalWS, 0.0f)); 

	float NoL = dot(NormalWS, _MatCapMainLight); //将世界空间法线 与matcap空间的主要光方向计算点乘
	float MatCapNoL = dot(NormalMatS, _MatCapMainLight); //maptcap空间的法线与 matcap空间的光方向计算点乘
	bool DisableMatCap = _MatCapMainLight.w > 0.5f; // 当W分量大于0.5时，禁用MatCap光照，使用标准的世界空间光照
	NoL = DisableMatCap ? NoL : MatCapNoL;  //关闭matcap 使用标准空间法线与光的点乘 否则使用matcap空间下光方向与法线点乘

	//实时阴影采样与衰减
	float Shadow = MainLightRealtimeShadow(i.ShadowCoord); //使用顶点着色器生成的阴影坐标i.ShadowCoord，从主光源的阴影贴图中采样阴影值
    float ShadowFadeOut = dot(-ViewVector, -ViewVector); //ViewVector方向的模平方  来计算一个淡出因子
	//远处的阴影会逐渐变淡，模拟大气透视效果  
    ShadowFadeOut = saturate(ShadowFadeOut * _MainLightShadowParams.z + _MainLightShadowParams.w);// _MainLightShadowParams.z和_MainLightShadowParams.w控制淡出的速率和起始距离
    ShadowFadeOut *= ShadowFadeOut;
	// 应用阴影淡出 使用ShadowFadeOut因子 进行阴影值与光照常量的线性插值
    Shadow = lerp(Shadow, 1, ShadowFadeOut);
	Shadow = lerp(1.0f, Shadow, _MainLightShadowParams.x); //使用_MainLightShadowParams.x来控制整体阴影的强度，允许艺术家调整阴影的深浅。
	Shadow = saturate(Shadow * ((4.0f * Shadow - 6) * Shadow + 3.0f));//阴影曲线调整 通过一个三次多项式((4.0f * Shadow - 6) * Shadow + 3.0f)对阴影值进行非线性调整。 三次多项式曲线图片见知乎
	//可以将中间灰度的阴影向两端（0或1）推，使得明暗交界更加清晰


	// 层贴图相关变量初始化
	float3 LayerMapColor = 0; //层贴图颜色 存储层级贴图颜色
	float LayerWeight = 0; //层贴图权重 用于计算层级贴图的混合权重
	float4 LayerMapDef = 0; //层级自定义贴图 用于覆盖基础定义贴图的属性。
	#ifdef _LAYERMAP_ON //宏定义是否开启层级贴图采样混合 
    if (_LayerWeight != 0)
    {
        float2 LayerMapUV = i.UV.zw * float2(0.5f, 1.0f); //将贴图的第二采样uv通道获取X为0.5的一半的UV 做为层贴图的采样UV  / 计算层贴图UV（使用第二组UV，并缩放x轴）
        float LayerMapTextureBias = _GlobalMipBias.x - 2; //// 设置层贴图纹理采样偏置
    	// 采样层贴图
        float4 LayerMap = SAMPLE_TEXTURE2D_BIAS(_LayerMap, sampler_LayerMap, LayerMapUV, LayerMapTextureBias);
        LayerMapColor = LayerMap.rgb; //获取LayerMap的RGB通道提供了额外的颜色信息
        LayerWeight = LayerMap.a * _LayerWeight; //层级贴图的a通道存储了权重将该权重与全局权重相乘 得到最终的混合权重  // 计算层贴图权重

    	// 计算自定义贴图UV（偏移x轴）
        float2 LayerMapDefUV = LayerMapUV + float2(0.5f, 0.0f);
        LayerMapDef = SAMPLE_TEXTURE2D_BIAS(_LayerMap, sampler_LayerMap, LayerMapDefUV, LayerMapTextureBias); //// 采样自定义层级贴图
    }
	#endif

	//// 设置纹理采样偏置
	float TextureBias = _GlobalMipBias.x - 1;
	//采样基础贴图
	float4 BaseMap = SAMPLE_TEXTURE2D_BIAS(_BaseMap, sampler_BaseMap, i.UV.xy, TextureBias);
	#ifdef _LAYERMAP_ON //判断是否开启层级贴图
        BaseMap.rgb = lerp(BaseMap, LayerMapColor.rgb, LayerWeight); //如果有开启 将基础贴图颜色 与层级贴图颜色 根据LayerWeight 权重进行线性插值混合
	#endif

	//采样阴影贴图
	float4 ShadeMap = SAMPLE_TEXTURE2D_BIAS(_ShadeMap, sampler_ShadeMap, i.UV.xy, TextureBias);

	// // 初始化定义贴图值，如果未禁用定义贴图则采样
	float4 DefMap = _DefValue;
	#ifndef _DEFMAP_OFF //如果没有开启自定义贴图 则采样
		DefMap = SAMPLE_TEXTURE2D_BIAS(_DefMap, sampler_DefMap, i.UV.xy, TextureBias).xyzw;
	//自定义贴图DefMap是一个数据纹理，其四个通道（RGBA）分别存储了不同的物理属性
	//R通道 (DefDiffuse) ：漫反射偏移，用于微调光照计算。
	//G通道 (DefSmoothness) ：光滑度，影响镜面高光的锐利程度。
	//B通道 (DefMetallic) ：金属度，决定材质是金属还是非金属。
	//A通道 (DefSpecular) ：镜面反射强度，控制高光的亮度。
	#endif
	#ifdef _LAYERMAP_ON //判断是否开启层级贴图 如果开启将 自定义贴图 与层级自定义贴图进行层级权重的线性插值 混合 （用于脸部流汗效果）
        DefMap = lerp(DefMap, LayerMapDef, LayerWeight);
	#endif
	// // 从定义贴图提取各项参数
	float DefDiffuse = DefMap.x; /// 漫反射强度
	float DefMetallic = DefMap.z; //金属度
	float DefSmoothness = DefMap.y; //光滑度
	float DefSpecular = DefMap.w; //镜面反射强度

	//// 计算漫反射偏移（从[0,1]映射到[-1,1]）
	float DiffuseOffset = DefDiffuse * 2.0f - 1.0f;
	float Smoothness = min(DefSmoothness, 1); //  // 限制光滑度不超过1
	float Metallic = IsFace ? 0 : DefMetallic; //判断是否是脸部 如果不是使用金属度
	
	float SpecularIntensity = min(DefSpecular, Shadow); // // 计算高光强度，并受阴影影响
	//// 根据MatCap状态 来选择
	float3 NormalWorM = DisableMatCap ? NormalWS : NormalMatS; //如果开启MatCap光照 则使用matcap空间的法线 否在使用模型的世界空间法线
	float3 ViewDirWorM = DisableMatCap ? ViewDirection : float3(0, 0, 1); //如果开启如果开启MatCap光照 视角方向 为正z轴方向 否则使用视角方向向量

	if (IsHair) //当IsHair为真时，会执行一系列专为头发设计的渲染逻辑。
	{
		// 判断是否为头发属性（通过UV坐标计算）
		float IsHairProp = saturate(i.UV.x - 0.75f) * saturate(i.UV.y - 0.75f);
		IsHairProp = IsHairProp != 0;//如果是头发 IsHairProp不为0 
	
		float HairSpecular = Pow4(saturate(dot(NormalWorM, ViewDirWorM)));//通过法线与视角方向的点乘 （将漫反射做为头发的高光）计算头发的高光

		//使用smoothstep函数在_SpecularThreshold定义的阈值范围内进行平滑过渡 smoothstep(a,b,c) 当c小于a时返回0 c大于b时返回1
		HairSpecular = smoothstep(_SpecularThreshold.x - _SpecularThreshold.y, _SpecularThreshold.x + _SpecularThreshold.y, HairSpecular);
		HairSpecular *= SpecularIntensity; // 应用高光强度
		HairSpecular = IsHairProp ? 0 : HairSpecular;  //判断非头发区域 非头发属性区域不使用高光
		//为了进一步增强头发的细节，代码采样了一张专门的高光贴图HighlightMap
		//包含了头发上特定的高光形状和颜色
		float3 HighlightMap = SAMPLE_TEXTURE2D_BIAS(_HighlightMap, sampler_HighlightMap, i.UV.xy, TextureBias).xyz;
		//将HairSpecular高光值做为插值因子 将高光贴图 与基础颜色贴图进行插值来回去 原颜色的高光
		BaseMap.xyz = lerp(BaseMap.xyz, HighlightMap.xyz, HairSpecular);

		// 头发边缘渐变与透明度处理
		// 计算头发淡出效果（基于头部方向）
		float HairFadeX = dot(_HeadDirection, ViewDirection); //视角方向与头模型朝向进行点乘
		//_FadeParam淡入淡出参数 (x:起始值, y:范围, z:上方向阈值, w:上方向范围
		HairFadeX = _FadeParam.x - HairFadeX; //将点乘结果减去_FadeParam的x值
		HairFadeX = saturate(HairFadeX * _FadeParam.y);//将计算的头发淡出值乘_FadeParam。y 范围 并且限制在0到1区间
		// 计算头发淡出效果（基于头部上方向）
		float HairFadeZ = dot(_HeadUpDirection, ViewDirection); //将头部的上方向 点乘 视角方向向量
		HairFadeZ = abs(HairFadeZ) - _FadeParam.z; //将计算头部上的头发淡出值绝对化减去上方向阈值
		HairFadeZ = saturate(HairFadeZ * _FadeParam.w); //将头部上的头发淡出值乘上方向范围 并且限制在0到1区间
		//它通过计算视图方向与头部朝向（_HeadDirection）和头部上方向（_HeadUpDirection）的点积，来确定头发边缘的位置。
		//当视角与头部朝向或上方向接近垂直时（即在头发的边缘），HairFadeX或HairFadeZ的值会增大，从而导致BaseMap.a（基础颜色的透明度）降低，产生一个平滑的淡出效果。
		// 应用头发淡出效果到Alpha通道
		BaseMap.a = lerp(1, max(HairFadeX, HairFadeZ), BaseMap.a); //将基础贴图的alpha值做做为头发边缘光圈的线性插值 头部朝向与向上淡出值取最大与1（最亮光） 与淡出值进行线性插值
	
		SpecularIntensity *= IsHairProp ? 1 : 0; // // 调整高光强度（非头发属性区域不使用高光）
	}

	// // 渐变添加贴图相关变量
	float4 RampAddMap = 0; //ramp贴图
	float3 RampAddColor = 0; //ramp贴图颜色
	#ifdef _RAMPADD_ON //判断是否开启ramp渐变
	//// 计算渐变添加贴图UV（基于漫反射偏移和MatCap空间法线的z分量）
    float2 RampAddMapUV = float2(saturate(DiffuseOffset + NormalMatS.z), VertexColor.RampAddID); //将漫反射偏移和MatCap空间法线的z分量相加转为0到1区间 和 顶点颜色的rampid 做为ramp采样UV
    RampAddMap = SAMPLE_TEXTURE2D_BIAS(_RampAddMap, sampler_RampAddMap, RampAddMapUV, _GlobalMipBias.x); //采样ramp贴图
	RampAddColor = RampAddMap.xyz * _RampAddColor.xyz; //将ramp贴图颜色+渐变添加颜色

	// // 计算漫反射渐变添加颜色（根据贴图Alpha通道混合）
    float3 DiffuseRampAddColor = lerp(RampAddColor, 0, RampAddMap.a);	//渐变颜色与阴影黑色 利用渐变纹理的alpha 进行插值 做为漫反射光照的渐变颜色
	// 应用渐变添加颜色到基础贴图和阴影贴图
    BaseMap.xyz += DiffuseRampAddColor; //基础颜色加上渐变漫反射颜色
    ShadeMap.xyz += DiffuseRampAddColor; //阴影颜色加上渐变漫反射颜色
	#endif
	
	float BaseLighting = NoL * 0.5f + 0.5f; //将法线与光照的点乘的漫反射值转换到0到1区间
	BaseLighting = saturate(BaseLighting + (DiffuseOffset - _MatCapParam.x) * 0.5f); // 应用漫反射偏移调整光照 将漫反射偏移值减去阴影偏移值/2 加漫反射光照值 转为0到1区间

	//面部 (Face) 渲染
	
	float3 NormalHeadMatS = mul(WorldToMatcap, i.NormalHeadReflect.xyz); //将头部的反射法线转换到 matcap空间
	//是否使用matcap空间 如果不使用 则世界空间光照乘以头部反射法线 如果使用matcap空间 就matcap空间反射法线乘matcap空间光照
 	float FaceNoL = DisableMatCap ? dot(i.NormalHeadReflect, _MatCapMainLight) : dot(NormalHeadMatS, _MatCapMainLight);
	float FaceLighting = saturate((FaceNoL + DiffuseOffset) * 0.5f + 0.5f); //将脸部的漫反射值加漫反射偏移转换到0到1区间
	FaceLighting = max(FaceLighting, BaseLighting); //// 确保脸部光照不低于基础光照
	FaceLighting = lerp(BaseLighting, FaceLighting, DefMetallic); // // 根据金属度混合基础光照和脸部光照
	
	BaseLighting = IsFace ? FaceLighting : BaseLighting; //// 如果是脸部材质，使用脸部光照
	BaseLighting = min(BaseLighting, Shadow); // 光照受阴影影响

	// // 采样渐变贴图（基于光照强度）
	float2 RampMapUV = float2(BaseLighting, 0);
	float4 RampMap = SAMPLE_TEXTURE2D_BIAS(_RampMap, sampler_RampMap, RampMapUV, _GlobalMipBias.x);

	
	const float ShadowIntensity = _MatCapParam.z; //获取阴影强度
	float3 RampedLighting = lerp(BaseMap.xyz, ShadeMap.xyz * _ShadeMultiplyColor, RampMap.w * ShadowIntensity); //将基础纹理颜色 与阴影贴图*阴影颜色乘法参数 根据渐变纹理的w乘阴影强度 进行线性插值 获取 渐变光照效果
	// 皮肤特殊处理
	float3 SkinRampedLighting =	lerp(RampMap, RampMap.xyz * _ShadeMultiplyColor, RampMap.w);//将ramp贴图颜色 与ramp贴图颜色*阴影颜色乘法参数 根据RampMap的w分量进行插值 获取皮肤的渐变光照颜色
	SkinRampedLighting = lerp(1, SkinRampedLighting, ShadowIntensity);//高光颜色 与皮肤的渐变光照颜色 根据阴影强度 进行插值
	SkinRampedLighting = BaseMap * SkinRampedLighting; //基础颜色乘以皮肤渐变颜色
	RampedLighting = lerp(RampedLighting, SkinRampedLighting, ShadeMap.w); // 根据阴影贴图的w通道混合渐变光照和皮肤兼渐变光照
	
	// 调整皮肤饱和度
	float SkinSaturation = _SkinSaturation - 1; //_SkinSaturation参数控制整体的饱和度 计算 得到一个新的饱和度调整值。
	//将_SkinSaturation参数从[1,∞]的范围转换为[0,∞]的范围
	//   - _SkinSaturation是控制皮肤饱和度的参数，默认值为1表示不改变饱和度
	//   - 当_SkinSaturation = 1时，SkinSaturation = 0，表示不进行饱和度调整
	//   - 当_SkinSaturation > 1时，SkinSaturation > 0，表示增加饱和度
	//   - 当_SkinSaturation < 1时，SkinSaturation < 0，表示降低饱和度
	SkinSaturation = SkinSaturation * ShadeMap.w + 1.0f; //根据阴影贴图调整饱和度强度  ShadeMap.w是阴影贴图的Alpha通道，通常用于存储皮肤区域的遮罩或权重  当ShadeMap.w = 0时，SkinSaturation = 1，表示不进行饱和度调整
	//当ShadeMap.w = 1时，SkinSaturation = 原始计算的饱和度调整值 + 1
	RampedLighting = lerp(Luminance(RampedLighting), RampedLighting, SkinSaturation); //应用饱和度调整 通过lerp函数在原始颜色和去色后的亮度（Luminance）之间进行插值 可以实现饱和度的增减
	//Luminance(RampedLighting)计算颜色的亮度值（灰度）
	RampedLighting *= _BaseColor; //应用基础颜色 将调整后的光照颜色与基础颜色相乘

	//// 眼睛高光处理  
	RampedLighting = IsEyeHightLight ? RampedLighting * _EyeHighlightColor : RampedLighting; //判断是否时眼睛材质 如果是 就使用 渐变光颜色乘眼睛高光颜色 做为效果 如果不是 就使用渐变光颜色
	BRDFData G_BRDFData = G_InitialBRDFData(RampedLighting, Smoothness, Metallic, SpecularIntensity, IsEye); // 初始化BRDF数据 G_InitialBRDFData函数根据之前计算出的颜色、光滑度、金属度和镜面强度，以及是否为眼睛的特殊标志，来填充这个结构体。

	///// 间接高光计算
	float3 IndirectSpecular = 0; //初始化间接高光变量   这个变量将用于累积所有环境反射的贡献
	float3 ReflectVector = reflect(-ViewDirection, NormalWS); //根据视角方向 与法线计算反射向量
	#ifdef _USE_REFLECTION_TEXTURE //检查是否使用反射纹理 如果使用反射纹理则 执行下面代码
		float ReflectionTextureMip = PerceptualRoughnessToMipmapLevel(G_BRDFData.perceptualRoughness); //计算反射纹理的Mip级别 根据材质G_BRDFData的感知粗糙度计算环境贴图应该使用的Mip级别
        float3 VLSpecCube = SAMPLE_TEXTURECUBE_LOD(_VLSpecCube, sampler_VLSpecCube, ReflectVector, ReflectionTextureMip); 
        VLSpecCube *= _VLSpecColor; //应用反射颜色调整 将采样到的环境反射颜色与反射颜色参数相乘
        IndirectSpecular = VLSpecCube; //赋值给间接高光变量 将处理后的环境反射颜色赋值给间接高光变量 这样间接高光变量就包含了环境立方体贴图的反射贡献
	#endif
	#ifdef _USE_EYE_REFLECTION_TEXTURE //检查是否使用眼睛反射纹理 大致方法与上面一样
		float ReflectionTextureMip = PerceptualRoughnessToMipmapLevel(G_BRDFData.perceptualRoughness);  //计算反射纹理的Mip级别 根据材质G_BRDFData的感知粗糙度计算环境贴图应该使用的Mip级别
        float3 VLSpecCube = SAMPLE_TEXTURECUBE_LOD(_VLSpecCube, sampler_VLSpecCube, ReflectVector, ReflectionTextureMip);//采样环境立方体贴图 利用视角根据模型的法线反射的向量和Mip级别采样周围环境的立方体贴图
        VLSpecCube *= _VLEyeSpecColor;//应用反射颜色调整 将采样到的环境反射颜色与反射颜色参数相乘
        IndirectSpecular = VLSpecCube;//赋值给间接高光变量 将处理后的环境反射颜色赋值给间接高光变量 这样间接高光变量就包含了环境立方体贴图的反射贡献
	#endif

	//一种MatCap技术，使用一张2D球形贴图来模拟反射
	//MatCap反射计算  //注意 这里的_ReflectionSphereMap 是 matcap预渲染的反射球形贴图
	
	float3 MatCapReflection = 0.0f;  //这个变量将用于存储MatCap反射的颜色值
	#ifdef _USE_REFLECTION_SPHERE  //检查是否使用反射球贴图
        float2 ReflectionSphereMapUV = NormalMatS.xy * 0.5 + 0.5; //计算反射球贴图UV坐标 根据材质空间法线的xy分量计算反射球贴图的UV坐标 并且转换到0到1区间 使用matcap方法
	//采样反射球贴图 使用计算出的UV坐标采样反射球贴图  _ReflectionSphereMap: 反射球贴图  _GlobalMipBias.x: 全局Mip偏置值，用于控制纹理采样的细节级别
        float4 ReflectionSphereMap = SAMPLE_TEXTURE2D_BIAS(_ReflectionSphereMap, sampler_ReflectionSphereMap, ReflectionSphereMapUV, _GlobalMipBias.x);
    //计算基础反射强度
	//HDR参数 HDR参数的w分量控制Alpha通道的使用程度 y分量提供指数调整 x分量提供线性缩放
	
        float ReflectionSphereIntensity = lerp(1, ReflectionSphereMap.a, _ReflectionSphereMap_HDR.w); //根据反射球贴图的Alpha通道和HDR参数的w分量计算反射强度 反射强度根据HDR的W分量控制1到反射球贴图的Alpha的变化
        ReflectionSphereIntensity = max(ReflectionSphereIntensity, 0); //确保反射强度不小于0
		ReflectionSphereIntensity = pow(ReflectionSphereIntensity, _ReflectionSphereMap_HDR.y); //应用指数调整反射强度 使用指数函数调整反射强度 类似bulinphong反射光照
        ReflectionSphereIntensity *= _ReflectionSphereMap_HDR.x; //应用强度缩放 将反射强度乘以缩放因子
    
        ReflectionSphereMap.xyz = ReflectionSphereMap.xyz * ReflectionSphereIntensity; //计算最终反射颜色 将反射球贴图的RGB颜色乘以计算出的反射强度
        MatCapReflection = ReflectionSphereMap.xyz; //将计算出的反射颜色赋值给MatCapReflection变量
	#endif


	//菲涅尔效应与边缘光
	float FresnelTerm = Pow4(1 - saturate(NormalMatS.z)); // NormalMatS.z相当于NoV  //计算菲涅尔项  NormalMatS.z存储了法线与视角的点乘  Pow4(): 四次方运算，使菲涅尔效应更加明显
	float3 SpecularColor =  EnvironmentBRDFSpecular(G_BRDFData, FresnelTerm); //计算基于环境的BRDF高光颜色 通过BRDF 和涅斐尔计算出BRDF环境高光颜色
	float3 SpecularTerm = DirectBRDFSpecular(G_BRDFData, NormalWorM, _MatCapMainLight, ViewDirWorM); //计算直接光照BRDF高光项 G_BRDFData: BRDF参数 NormalWorM: 根据MatCap状态选择的世界空间或材质空间法线 _MatCapMainLight: 主光源方向 ViewDirWorM: 根据MatCap状态选择的视角方向
	float3 Specular = SpecularColor * IndirectSpecular;  //组合高光反射 - 环境部分  环境BRDF高光颜色乘 之前计算的环境反射贡献 得到最终的环境高光反射

	//组合高光反射 - 直接光照部分
	Specular += SpecularTerm * SpecularColor; //添加直接光照高光反射部分  光照的高光项与BRDF高光颜色 相乘添加到总总高光反射中
	Specular += MatCapReflection; // 添加MatCap反射部分
	Specular *= SpecularIntensity; //应用高光强度参数

	if (IsEyeBrow) //// 眉毛高光特殊处理
	{
		//通过偏移基础UV坐标计算眉毛高光的UV坐标
		float2 EyeBrowHightLightUV = saturate(i.UV.xy + float2(-0.968750, -0.968750));  //(-0.968750, -0.968750): 特定的偏移值，用于定位眉毛区域
		float EyeBrowHightLightMask = EyeBrowHightLightUV.y * EyeBrowHightLightUV.x; //计算眉毛高光遮罩 通过UV坐标的x和y分量相乘创建遮罩 这种乘法创建了一个从左上角到右下角的渐变遮罩 当x或y接近0时，遮罩值为0；当x和y都接近1时，遮罩值为1
		EyeBrowHightLightMask = EyeBrowHightLightMask != 0.000000; //将遮罩转换为布尔值 如果遮罩值不为0，结果为true(1)；如果为0，结果为false(0) 这创建了一个硬边缘的遮罩，只有特定区域有高光
		Specular += EyeBrowHightLightMask ? RampedLighting * 2.0f : 0.0f; //添加眉毛高光 根据遮罩条件性地添加眉毛高光 渐变高光乘2使高光更加明显
	}

	//// 应用渐变添加颜色到高光
	Specular = lerp(Specular, Specular * RampAddColor, RampAddMap.w); //RampAddMap.w: 渐变添加贴图的Alpha通道，控制插值权重 使 原始高光和调整后的渐变高光之间进行插值

	// 计算环境光
	float3 SH = SampleSH(NormalWS); // 计算环境光（球谐函数） 采样球谐函数获取环境光照 根据法线采样球谐光照
	float3 SkyLight = max(SH, 0) * _GlobalLightParameter.x * G_BRDFData.diffuse; // 计算最终的天空光照贡献 _GlobalLightParameter.x: 全局光照强度参数  G_BRDFData.diffuse: BRDF的漫反射部分，用于调整环境光照颜色

	//// 计算边缘光强度
	float3 NormalVS = mul(unity_MatrixV, float4(NormalWS.xyz, 0.0)).xyz; //将世界空间法线转换到视图空间
	float RimLight = 1 - dot(NormalVS, normalize(_MatCapRimLight.xyz)); //计算基础边缘光强度 计算法线与边缘光方向的点积 1 - dot(): 当法线与边缘光方向垂直时值最大，创建边缘光效果
	
	RimLight = pow(RimLight, _MatCapRimLight.w); //应用指数调整边缘光强度 指数参数，控制边缘光的锐利程度 
	float RimLightMask = min(DefDiffuse * DefDiffuse, 1.0f) * VertexColor.RimMask; //计算边缘光遮罩 使用漫反射强度的平方，强调较高值 VertexColor.RimMask: 从顶点颜色中提取的边缘光遮罩 两者相乘得到最终的边缘光遮罩
	RimLight = min(RimLight, 1.0f) * RimLightMask; //应用边缘光遮罩并限制强度 获取边缘光 边缘光不超过1 并乘以遮罩
	//计算边缘光颜色
	float3 RimLightColor = lerp(1, RampedLighting, _MatCapRimColor.a) * _MatCapRimColor.xyz; //在纯白色和光照颜色之间插值 _MatCapRimColor.xyz;应用边缘光颜色
	RimLightColor *= RimLight; // 应用边缘光强度 将边缘光颜色乘以计算出的边缘光强度
	// 组合最终光照
	float3 OutLighting = G_BRDFData.diffuse; // 初始化最终光照为BRDF的漫反射部分
	OutLighting += Specular; //添加高光反射部分到最终光照
	OutLighting *= _MatCapLightColor.xyz; //应用MatCap光照颜色

	//// 附加光源处理
	float3 AdditionalLighting = 0; // 初始化附加光源贡献变量为0
	#ifdef _ADDITIONAL_LIGHTS //如果定义了_ADDITIONAL_LIGHTS宏，则处理附加光源
	int additionalLightsCount = GetAdditionalLightsCount(); //获取场景中附加光源的数量
	for (int index = 0; index < additionalLightsCount; ++index) { //遍历所有附加光源
		Light AdditionalLight = GetAdditionalLight(index, i.PositionWS); //获取附加光源信息  i.PositionWS:世界空间位置，用于计算光照衰减

		// 计算光源辐射度
		float Radiance = max(dot(NormalWS, AdditionalLight.direction), 0); //计算法线与光源方向的点积，得到基础光照强度
		Radiance = (Radiance * 0.5f + 0.5f) * 2.356194f;//将光照强度映射到0到1区间 乘以常数(约等于3π/4)，调整强度缩放
		Radiance = smoothstep(_MatCapParam.x - 0.000488f, _MatCapParam.x + 0.001464f, Radiance); //应用平滑步进阈值  MatCapParam.x: 阈值中心点 ±0.000488f和±0.001464f: 阈值范围，创建平滑过渡区域
		Radiance = saturate(Radiance + ShadowIntensity); // 应用阴影强度 将阴影强度加到光照强度上
		Radiance *= AdditionalLight.distanceAttenuation; //应用距离衰减 将光照强度乘上 AdditionalLight.distanceAttenuation包含光源的距离衰减因子

		// 计算光照颜色
		float3 Lighting = Radiance * AdditionalLight.color; //将调整后的光照强度乘以光源颜色
		float3 AdditionalSpecular = DirectBRDFSpecular(G_BRDFData, NormalWS, AdditionalLight.direction, ViewDirection); // 计算附加光源的高光反射
		AdditionalSpecular *= SpecularColor * _GlobalLightParameter.z; //应用高光颜色和全局参数 调整附加光源的高光反射 _GlobalLightParameter.z:全局高光强度参数
		AdditionalLighting += Lighting * (OutLighting + AdditionalSpecular); //累加附加光源贡献
	}
	#endif
	
	//组合所有光照贡献
	OutLighting += AdditionalLighting * _GlobalLightParameter.y; //添加附加光源贡献到总光照
	OutLighting += SkyLight; //添加天空光照贡献
	OutLighting += RimLightColor; // 添加边缘光贡献
	OutLighting += RampMap.w * _ShadeAdditiveColor; //添加渐变添加颜色贡献 RampMap.w: 渐变贴图的Alpha通道 _ShadeAdditiveColor.xyz: 阴影添加颜色

	OutLighting *= _MultiplyColor.xyz; //应用最终的颜色乘法
	
	float Alpha = BaseMap.a * _MultiplyColor.a; //计算最终的Alpha值  BaseMap.a: 基础贴图的Alpha通道 _MultiplyColor.a: 颜色乘法参数的Alpha分量 两者相乘得到最终的透明度
	#ifdef _ALPHATEST_ON // Alpha测试
		clip(Alpha - _ClipValue); //如果启用了Alpha测试，则进行裁剪  clip函数会丢弃Alpha值小于_ClipValue的片段  这是实现透明材质裁剪的标准方法
	#endif
	#ifdef _ALPHAPREMULTIPLY_ON //// Alpha预乘
        OutLighting *= Alpha;  // 如果启用了Alpha预乘，则将颜色乘以Alpha  Alpha预乘是处理透明度的常用技术，可以避免混合时的颜色渗漏问题
	#endif
	
	return float4(OutLighting, Alpha); //返回最终颜色
}
#endif