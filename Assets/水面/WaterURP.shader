Shader "Custom/WaterURP" {
		
		Properties {
			[Enum(Off, 0, On, 1)] _ZWrite ("Z Write", Float) = 1
		}

	SubShader {
		Tags {
			"RenderPipeline" = "UniversalPipeline"
			"RenderType" = "Opaque"
			"Queue" = "Geometry"
		}

		Pass {
			Name "ForwardLit"
			Tags { "LightMode" = "UniversalForward" }

			ZWrite [_ZWrite]

			HLSLPROGRAM

			#pragma vertex vp
			#pragma fragment fp
			#pragma target 4.5

			#pragma shader_feature_local USE_VERTEX_DISPLACEMENT
			#pragma shader_feature_local SINE_WAVE
			#pragma shader_feature_local STEEP_SINE_WAVE
			#pragma shader_feature_local GERSTNER_WAVE
			#pragma shader_feature_local NORMALS_IN_PIXEL_SHADER
			#pragma shader_feature_local CIRCULAR_WAVES
			#pragma shader_feature_local USE_FBM

			// URP管线：使用URP的核心函数和光照函数，替代Built-in管线的UnityPBSLighting.cginc和AutoLight.cginc
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl" // URP深度纹理声明，用于兼容_CameraDepthTexture

			struct VertexData {
				float4 vertex : POSITION; // 顶点位置，使用POSITION语义绑定
				float3 normal : NORMAL;	  // 顶点法线，使用NORMAL语义绑定
			};

			struct v2f {
				float4 pos : SV_POSITION;		// 裁剪空间位置，使用SV_POSITION语义
				float3 normal : TEXCOORD1;		// 世界空间法线，使用TEXCOORD1语义
				float3 worldPos : TEXCOORD2;	// 世界空间位置，使用TEXCOORD2语义
			};
			
			// 波浪参数结构体 - 定义单个波浪的所有属性
			struct Wave { 
				float2 direction;	// 波浪传播方向（归一化的2D向量）
				float2 origin;		// 波浪起源点坐标
				float frequency;	// 波浪频率（控制波浪的密集程度）
				float amplitude;	// 波浪振幅（控制波浪的高度）
				float phase;		// 波浪相位（控制波浪的初始偏移）
				float steepness;	// 波浪陡峭度（控制波浪的尖锐程度）	
				int waveType;		// 波浪类型标识（用于选择不同的波浪算法）
			};
			
			StructuredBuffer<Wave> _Waves; //波浪的结构体类型的常量缓冲 // 声明一个结构化的波浪数据缓冲区

			//#define sin fastSine

			#define PI 3.14159265358979323846

			float DotClamped(float3 a, float3 b) {
				return saturate(dot(a, b)); // URP中自定义DotClamped，替代Built-in管线UnityPBSLighting.cginc里的同名函数
			}

			float fastSine(float x) {
				return 1.0f;
			}

			float2 GetDirection(float3 v, Wave w) { //获取波浪的运动方向向量
				#ifdef CIRCULAR_WAVES //检查是否定义了圆形波浪模式
                float2 p = float2(v.x, v.z);//提取顶点在水面的xz二维平面的坐标

                return normalize(p - w.origin); // 计算从波浪起源点到顶点位置的向量，并归一化
				#else  // 如果不是圆形波浪模式，直接返回波浪的预设方向
				return w.direction; 
				#endif
			}

			float GetWaveCoord(float3 v, float2 d, Wave w) { //计算波浪坐标（顶点在波浪传播方向上的投影） 
				#ifdef CIRCULAR_WAVES  //// 检查是否定义了圆形波浪模式
					float2 p = float2(v.x, v.z); //获取顶点在二维平面的位置
					return length(p - w.origin); //  // 计算顶点到波浪起源点的距离
				#endif

				return v.x * d.x + v.z * d.y; // 如果不是圆形波浪，计算顶点在波浪方向上的投影
			}

			float GetTime(Wave w) {  // 获取时间参数的函数
				#ifdef CIRCULAR_WAVES  // 检查是否定义了圆形波浪模式
					return -_Time.y * w.phase;  // 对于圆形波浪，使用负的时间乘以相位
				#else
				return _Time.y * w.phase;   // 对于平行波浪，使用正的时间乘以相位
				#endif
			}

			float Sine(float3 v, Wave w) { //Sinusoid正弦波 传入世界空间顶点位置 和波浪类型
				float2 d = GetDirection(v, w); //根据顶点位置和波浪类型获取运动方向向量
				float xz = GetWaveCoord(v, d, w); // 计算波浪坐标（顶点在波浪传播方向上的投影） 传入世界空间顶点位置 波浪的朝向方向 波浪类型
				float t = GetTime(w); // 获取时间参数的函数 传入波浪类型

				return w.amplitude * sin(xz * w.frequency + t); //使用Sinusoid正弦波 计算波浪  公式：波浪振幅*sin（波浪传播方向长度*变化波浪频率+时间变化）
			}

			float3 SineNormal(float3 v, Wave w) { //正弦波法线重新计算 传入位置和波浪类型
				float2 d = GetDirection(v, w);  //获取波浪的运动方向向量
				float xz = GetWaveCoord(v, d, w);//传入位置 和运动方向 以及波浪类型 计算波浪根据运动方向朝向的坐标（顶点在波浪传播方向上的投影）
				float t = GetTime(w); //根据当前波浪类型计算获取用于计算的时间

				//法线梯度计算 因为正弦波的导数是余弦且用于就正弦当前的法线
				float2 n = w.frequency * w.amplitude * d * cos(xz * w.frequency + t); //波浪频率乘波浪上下振幅高度乘运动反向乘正弦的导数计算结果为法线朝向

				return float3(n.x, n.y, 0.0f); // 返回法线向量（Z分量为0，需要在外部进一步处理）
			}

			//陡峭正弦波 计算
			float SteepSine(float3 v, Wave w) { //传入位置 波浪类型 
				float2 d = GetDirection(v, w); //获取波浪的运动方向向量
				float xz = GetWaveCoord(v, d, w);//传入位置 和运动方向 以及波浪类型 计算波浪根据运动方向朝向的坐标（顶点在波浪传播方向上的投影）
				float t = GetTime(w);//根据当前波浪类型计算获取用于计算的时间
				//陡峭波浪计算 跟计算陡峭波浪因子 GPUgamea 8a 公式
				return 2.0f * w.amplitude * pow((sin(xz * w.frequency + t) + 1.0f) / 2.0f, w.steepness); //根据正弦波函数结果将正弦函数偏移为非负函数并且提高到 指数 k次方乘波浪高度乘2
			}

			float3 SteepSineNormal(float3 v, Wave w) { // 陡峭正弦波法线计算函数传入位置 和波浪类型
				float2 d = GetDirection(v, w); //获取波浪的运动方向向量
				float xz = GetWaveCoord(v, d, w);//传入位置 和运动方向 以及波浪类型 计算波浪根据运动方向朝向的坐标（顶点在波浪传播方向上的投影）
				float t = GetTime(w);//根据当前波浪类型计算获取用于计算的时间
				
				// 计算陡峭化高度因子 用于波具有更尖锐的波峰和更宽的波谷  公式跟陡峭高度波浪计算相似
				float h = pow((sin(xz * w.frequency + t) + 1) / 2.0f, max(1.0f, w.steepness - 1));  //用于计算波浪的高度差异的法线因子 根据正弦波函数结果将正弦函数偏移为非负函数 并且提高到 指数 k为（1到自己设定区间）  公式在gpugames 8b 波浪陡峭公式
				// 计算法线的XY分量（基于陡峭正弦波的导数）
				float2 n = d * w.steepness * w.frequency * w.amplitude * h * cos(xz * w.frequency + t); //将上面计算的陡峭化高度因子 与正弦波的导数（用于计算方向）相乘偏移陡峭高度波浪的法线 乘波浪陡峭度（控制波浪的尖锐程度）	*频率*高度

				return float3(n.x, n.y, 0.0f);  // 返回法线梯度向量
			}

			// Gerstner波函数 - 用于模拟水波效果
			// 输入：v - 顶点位置坐标，w - 波参数结构体
			// 输出：三维偏移向量，包含水平和垂直位移
			float3 Gerstner(float3 v, Wave w) {
				float2 d = GetDirection(v, w); // 获取波的传播方向向量（二维，xz平面）
				float xz = GetWaveCoord(v, d, w); //传入位置 和运动方向 以及波浪类型 计算波浪根据运动方向朝向的坐标（顶点在波浪传播方向上的投影）
				float t = GetTime(w);//根据当前波浪类型计算获取用于计算的时间

				
				//Gerstner波函数 公式GPUGAME0 公式9 
				float3 g = float3(0.0f, 0.0f, 0.0f);  // 初始化输出偏移向量
				g.x = w.steepness * w.amplitude * d.x * cos(w.frequency * xz + t); // 计算X轴方向的水平位移   steepness控制波形尖锐度，amplitude控制振幅  d.x确保位移沿波传播方向，cos产生周期性波动
				g.z = w.steepness * w.amplitude * d.y * cos(w.frequency * xz + t);// 计算Z轴方向的水平位移  // 原理与X方向相同，使用方向向量的y（里面存储二维平面xz值）分量*cos产生的周期波动
				g.y = w.amplitude * sin(w.frequency * xz + t); // 计算Y轴方向的垂直位移（波高） 使用sin函数产生基础的波形轮廓 乘波的振幅控制

				//将上面做为输出向量xyz输出
				
				return g;  // 返回完整的三维偏移向量
			}

			// Gerstner波法线计算函数 - 用于计算水波表面的法线向量
			// 输入：v - 顶点位置坐标，w - 波参数结构体  
			// 输出：三维法线向量，用于光照计算
			float3 GerstnerNormal(float3 v, Wave w) {
				float2 d = GetDirection(v, w);// 获取波的传播方向向量（二维，xz平面）
				float xz = GetWaveCoord(v, d, w);// 计算顶点在波传播方向上的投影坐标
				float t = GetTime(w); // 获取时间参数（这里直接使用了_Time.y和w.phase）

				float3 n = float3(0.0f, 0.0f, 0.0f);   // 初始化法线向量  Gerstner波法线计算函数法线计算公式 GPUgame0 公式12
				
				float wa = w.frequency * w.amplitude;  // 计算频率与振幅的乘积，这是法线计算中的常用组合
				float s = sin(w.frequency * xz + _Time.y * w.phase);   // 计算正弦分量（用于y轴垂直方向影响）  正弦波计算3为平面的y高度变化
				float c = cos(w.frequency * xz + _Time.y * w.phase);  // 计算余弦分量（用于xz平面水平方向影响）   正弦波的导数余弦波计算3为平面的xz以圆形范围变化

				 // 计算法线向量的X分量
				// 与波传播方向X分量相关，受余弦影响
				n.x = d.x * wa * c;
				// 计算法线向量的Z分量  
				// 与波传播方向Y分量相关，受余弦影响
				n.z = d.y * wa * c;

				// 计算法线向量的Y分量（主要分量）
				// 受陡度和正弦影响，决定法线的垂直倾斜程度
				n.y = w.steepness * wa * s;

				return n; // 返回未归一化的法线向量
			}

			// 计算顶点偏移量的统一接口函数
			float3 CalculateOffset(float3 v, Wave w) { //// 计算模拟海浪上下起伏的顶点偏移量的函数 传入世界空间顶点位置 和波浪类型
				#ifdef SINE_WAVE //判断是否使用正弦波（sin）做为计算偏移值值在y轴方向上下偏移
					return float3(0.0f, Sine(v, w), 0.0f);  // 正弦波只在Y轴方向产生垂直偏移
				#endif

				#ifdef STEEP_SINE_WAVE // 检查是否使用陡峭正弦波
					return float3(0.0f, SteepSine(v, w), 0.0f); // 陡峭正弦波同样只在Y轴方向产生垂直偏移
				#endif

				// 检查是否使用Gerstner波
				#ifdef GERSTNER_WAVE 
					return Gerstner(v, w); // Gerstner波在XYZ三个方向都可能产生偏移
				#endif

				return 0.0f;
			}

			float3 CalculateNormal(float3 v, Wave w) { // 计算波浪法线的统一接口函数
				#ifdef SINE_WAVE  // 检查是否使用正弦波
					return SineNormal(v, w);  // 调用正弦波的法线计算函数 传入当前位置和波浪类型
				#endif

				#ifdef STEEP_SINE_WAVE // 检查是否使用陡峭正弦波
					return SteepSineNormal(v, w); // 调用陡峭正弦波的法线计算函数  传入当前位置和波浪类型
				#endif

				#ifdef GERSTNER_WAVE // 检查是否使用Gerstner波
					return GerstnerNormal(v, w);// 调用Gerstner波的法线计算函数 传入位置 和波浪类型
				#endif

				return 0.0f;
			}

			// 哈希函数 - 用于生成伪随机数
			float hash(uint n) {
				// integer hash copied from Hugo Elias
				n = (n << 13U) ^ n; // 第一步：通过位运算混淆输入值
				n = n * (n * n * 15731U + 0x789221U) + 0x1376312589U; // 第二步：使用多项式哈希算法进一步混淆
				return float(n & uint(0x7fffffffU)) / float(0x7fffffff);  // 第三步：将结果限制在正数范围并归一化到[0,1]
			}

			float3 _SunDirection, _SunColor;
			// FBM（分形布朗运动）参数 - 顶点着色器版本
			float _VertexSeed;              // 顶点FBM的随机种子，用于生成初始随机方向
			float _VertexSeedIter;          // 顶点FBM每次迭代的种子增量，改变每层波的方向
			float _VertexFrequency;         // 顶点FBM的基础频率，控制波的密集程度
			float _VertexFrequencyMult;     // 顶点FBM频率倍增因子，每层波的频率变化率
			float _VertexAmplitude;         // 顶点FBM的基础振幅，控制波的高度强度
			float _VertexAmplitudeMult;     // 顶点FBM振幅倍增因子，每层波的振幅衰减率
			float _VertexInitialSpeed;      // 顶点FBM的初始速度，控制波的动画速度
			float _VertexSpeedRamp;         // 顶点FBM速度变化因子，每层波的速度变化率
			float _VertexDrag;              // 顶点FBM拖拽系数，控制波对顶点位置的偏移强度
			float _VertexHeight;            // 顶点FBM整体高度缩放，最终高度输出的全局缩放
			float _VertexMaxPeak;           // 顶点FBM最大峰值控制，调整波峰的尖锐程度
			float _VertexPeakOffset;        // 顶点FBM峰值偏移，调整波形的基础水平位置
			//float _VertexSeed, _VertexSeedIter, _VertexFrequency, _VertexFrequencyMult, _VertexAmplitude, _VertexAmplitudeMult, _VertexInitialSpeed, _VertexSpeedRamp, _VertexDrag, _VertexHeight, _VertexMaxPeak, _VertexPeakOffset;

			// FBM（分形布朗运动）参数 - 片段着色器版本
			float _FragmentSeed;            // 片段FBM的随机种子
			float _FragmentSeedIter;        // 片段FBM每次迭代的种子增量
			float _FragmentFrequency;       // 片段FBM的基础频率
			float _FragmentFrequencyMult;   // 片段FBM频率倍增因子
			float _FragmentAmplitude;       // 片段FBM的基础振幅
			float _FragmentAmplitudeMult;   // 片段FBM振幅倍增因子
			float _FragmentInitialSpeed;    // 片段FBM的初始速度
			float _FragmentSpeedRamp;       // 片段FBM速度变化因子
			float _FragmentDrag;            // 片段FBM拖拽系数
			float _FragmentHeight;          // 片段FBM整体高度缩放
			float _FragmentMaxPeak;         // 片段FBM最大峰值控制
			float _FragmentPeakOffset;      // 片段FBM峰值偏移
			
			//float _FragmentSeed, _FragmentSeedIter, _FragmentFrequency, _FragmentFrequencyMult, _FragmentAmplitude, _FragmentAmplitudeMult, _FragmentInitialSpeed, _FragmentSpeedRamp, _FragmentDrag, _FragmentHeight, _FragmentMaxPeak, _FragmentPeakOffset;

			// 法线强度控制参数
			float _NormalStrength;          // 基础法线强度，控制整体法线贴图的影响程度
			float _FresnelNormalStrength;   // 菲涅尔法线强度，专门用于菲涅尔计算的法线缩放
			float _SpecularNormalStrength;  // 高光法线强度，专门用于高光计算的法线缩放

			//float _NormalStrength, _FresnelNormalStrength, _SpecularNormalStrength;

			// 波浪数量控制参数
			int _WaveCount;                 // 总波浪数量，用于传统波浪计算方法的波浪层数
			int _VertexWaveCount;           // 顶点FBM波浪层数，控制顶点着色器中FBM的迭代次数
			int _FragmentWaveCount;         // 片段FBM波浪层数，控制片段着色器中FBM的迭代次数
			
			// int _WaveCount;
			// int _VertexWaveCount;
			// int _FragmentWaveCount;

			// 环境反射相关
			
			TEXTURECUBE(_EnvironmentMap); SAMPLER(sampler_EnvironmentMap); // 环境立方体贴图，用于基于图像的照明和反射
			int _UseEnvironmentMap;			// 使用环境贴图标志，开关环境反射效果

			float3 vertexFBM(float3 v) { //FBM流体仿真（分形布朗运动） 通过叠加频率的方式 欧拉波计算顶点海面偏移 
				float f = _VertexFrequency; //顶点偏移频率
				float a = _VertexAmplitude; //顶点上下振幅 波的高度
				float speed = _VertexInitialSpeed; //顶点初始变化速度
				float seed = _VertexSeed; // 随机函数初子
				float3 p = v; //获取顶点位置
				float amplitudeSum = 0.0f;  //计算顶点偏移 振幅总和，用于归一化

				float h = 0.0f; // // 高度值
				float2 n = 0.0f;// 法线/梯度值（当前未使用）
				for (int wi = 0; wi < _VertexWaveCount; ++wi) { //叠加多个不同频率得振幅 /每次循环将振幅进行累加 且每次根据变化的值计算频率 最终顶点所在的朝向和位置变化
					float2 d = normalize(float2(cos(seed), sin(seed)));//利用sin和cos 来根据种子计算在二维平面波得朝向方向

					float x = dot(d, p.xz) * f + _Time.y * speed; //将顶点得xz与上面在xz轴平面变化得方向进行投影并乘以缩放频率 +时间上得变化 计算出相对位置得值
					float wave = a * exp(_VertexMaxPeak * sin(x) - _VertexPeakOffset);//将上面计算出来得相对位置值做为sin-1到1区域的变化乘波的最大峰值减去 顶点峰值偏移 做为e的次方 结果乘顶点上下振幅 做出上下偏移振幅的变化  计算当前波层的强度
					float dx = _VertexMaxPeak * wave * cos(x); //将顶点最大峰值与波浪变化的振幅值相乘 乘cos内变化的相对位置值 计算波的导数（斜率）
					
					h += wave; //海浪波的高度强度值进行累加
					
					p.xz += d * -dx * a * _VertexDrag;//根据波的导数乘波朝向的二维平面方向乘上下振幅值和顶点拖拽 //计算顶点在波浪起伏时的方向

					amplitudeSum += a; //累加振幅用于归一化
					f *= _VertexFrequencyMult; // _VertexFrequencyMult进行调整频率倍增（通常>1，使波更密集）
					a *= _VertexAmplitudeMult; //_VertexAmplitudeMult 进行调整振幅倍减（通常<1，使高层波影响更小）
					speed *= _VertexSpeedRamp; // 速度变化
					seed += _VertexSeedIter;  // 更新种子，改变下一层波的方向
				}

				float3 output = float3(h, n.x, n.y)/amplitudeSum; //将高度值 除以每次累加的振幅amplitudeSum; //将归一化结果并应用最终缩放
				output.x *= _VertexHeight;//应用整体高度缩放

				return output;
			}

			float3 fragmentFBM(float3 v) { //// 片段着色器中的分形布朗运动(FBM)函数
				float f = _FragmentFrequency;  //波浪频率
				float a = _FragmentAmplitude; //片段着色器里上下振幅 波的高度
				float speed = _FragmentInitialSpeed;//片段着色器里初始变化速度
				float seed = _FragmentSeed;// 随机函数初子
				float3 p = v;  //当前片段的像素位置

				float h = 0.0f;// 高度值
				float2 n = 0.0f;// 法线/梯度值
				
				float amplitudeSum = 0.0f; //累计振幅总和（用于归一化）

				// FBM主循环 - 叠加多个不同频率和振幅的波 根据波的数量进行累计
				for (int wi = 0; wi < _FragmentWaveCount; ++wi) {
					float2 d = normalize(float2(cos(seed), sin(seed))); //根据种子利用sin和cos获取当前二维平面指向的方向向量

					float x = dot(d, p.xz) * f + _Time.y * speed; //使用Sine波计算公式  //将顶点得xz与上面在xz轴平面变化得方向进行投影并乘以缩放频率 +时间上得变化 计算出相对位置得值
					float wave = a * exp(_FragmentMaxPeak * sin(x) - _FragmentPeakOffset); //将上面计算出来得相对位置值做为sin函数-1到1区域的变化乘波的最大峰值减去 片段当前峰值偏移 做为e的次方 结果乘顶点上下振幅（限制上下区间） 做出上下偏移振幅的变化  计算当前波层的强度
					float2 dw = f * d * (_FragmentMaxPeak * wave * cos(x));//将顶点最大峰值与波浪变化的振幅值相乘 乘cos内变化的相对位置值 计算波的导数（斜率）   // 计算当前波层的导数（也用于法线计算）
					
					h += wave;//海浪波的高度强度值进行累加
					p.xz += -dw * a * _FragmentDrag;//根据波的导数取反乘波的高度的二维平面方向乘上下振幅值和片段拖拽    // 根据导数偏移位置（模拟拖拽效果）
					
					n += dw;  // 累加法线梯度

					
					amplitudeSum += a;  // 累加振幅用于后续归一化
					 // 更新FBM参数为下一层波
					f *= _FragmentFrequencyMult; // 增加频率（使波更密集）
					a *= _FragmentAmplitudeMult; // 减小振幅（使高层波影响更小）
					speed *= _FragmentSpeedRamp; // 调整速度
					seed += _FragmentSeedIter; // 更新种子（改变下一层波的方向）
				}

				// 归一化输出并应用整体高度缩放
				float3 output = float3(h, n.x, n.y) / amplitudeSum;
				output.x *= _FragmentHeight;

				return output; // 返回结果：x=高度, yz=法线梯度
			}

			float3 centralDifferenceNormal(float3 v, float epsilon) {
				float2 ex = float2(epsilon, 0);
				float h = fragmentFBM(v).x;
				float3 a = float3(v.x, h, v.z);

				float3 b = a - float3(v.x - epsilon, fragmentFBM(v - ex.xyy).x, v.z);
				float3 c = a - float3(v.x, fragmentFBM(v + ex.yyx).x, v.z + epsilon);

				return normalize(cross(b, c));
			}
					//环境光颜色，漫反射反射率，       高光反射率，           菲涅尔效应颜色，   顶部颜色
			float3 _Ambient, _DiffuseReflectance, _SpecularReflectance, _FresnelColor, _TipColor;
					//高光光泽度 菲涅尔偏置   菲涅尔强度          菲涅尔光泽度       顶部颜色衰减
			float _Shininess, _FresnelBias, _FresnelStrength, _FresnelShininess, _TipAttenuation;

			float4x4 _CameraInvViewProjection; //// 相机逆视图投影矩阵，用于从屏幕坐标重建世界坐标
			// _CameraDepthTexture由URP的DeclareDepthTexture.hlsl声明    // 相机深度纹理，存储场景的深度信息

			v2f vp(VertexData v) {//顶点着色器
				v2f i; //构建输出结构

				#ifdef USE_VERTEX_DISPLACEMENT //使用顶点位移
					i.worldPos = TransformObjectToWorld(v.vertex.xyz); //将顶点转换到世界坐标空间

					float3 h = 0.0f;  //// 高度偏移量
					float3 n = 0.0f;// 法线偏移量

					#ifdef USE_FBM //使用流体仿真FBM（分形布朗运动）方法
					float3 fbm = vertexFBM(i.worldPos); //输入顶点数据计算流体仿真顶点

					h.y = fbm.x; //将计算出的分形布朗运动结果的顶点高度值取出
					n.xy = fbm.yz; // 将FBM计算出的法线信息赋给xy分量
					#else //如果没有开启FBM（分形布朗运动）方法
					for (int wi = 0; wi < _WaveCount; ++wi) { //遍历波浪频率次数
						h += CalculateOffset(i.worldPos, _Waves[wi]); //// 计算当前Sinusoid正弦波对顶点的高度偏移 输入顶点位置 和常量缓冲区内第Wi个的波浪类型 做为当前xz平面顶点的高度值y

						//判断是否是Gerstner波浪 如果不是就重新计算Gerstner波浪中的顶点法线
						#ifndef GERSTNER_WAVE
							#ifndef NORMALS_IN_PIXEL_SHADER
								n += CalculateNormal(i.worldPos, _Waves[wi]); //因为是Gerstner波浪 波浪计算法线
							#endif
						#endif
					}
					#endif

					float4 newPos = v.vertex + float4(h, 0.0f);//// 应用高度偏移到将顶点偏移到新的位置
					i.worldPos = TransformObjectToWorld(newPos.xyz);//更新顶点的世界空间位置坐标
					i.pos = TransformObjectToHClip(newPos.xyz);//计算裁剪空间的顶点位置
					
					#ifndef NORMALS_IN_PIXEL_SHADER //// 检查是否在顶点着色器中计算法线
					#ifdef GERSTNER_WAVE // 检查是否使用Gerstner波浪 如果是遍历波浪重新计算法线
						for (int wi = 0; wi < _WaveCount; ++wi) {
							n += CalculateNormal(i.worldPos, _Waves[wi]);  // 对于Gerstner波浪，需要单独计算法线
						}
						// 计算Gerstner波浪的法线（特殊处理）
                        i.normal = normalize(TransformObjectToWorldNormal(normalize(float3(-n.x, 1.0f - n.y, -n.z))));   //将重新计算的法线偏移量xyz分别进行特殊处理计算
					#else //如果不是使用Gerstner波浪 执行下面
						i.normal = normalize(TransformObjectToWorldNormal(normalize(float3(-n.x, 1.0f, -n.y)))); // 计算普通波浪的法线 将n的法线偏移量做为偏移的法线 如果不是FBM波浪或Gerstner波浪 而是sin波浪则保留原来法线
					#endif
					#else // 如果在片段着色器中计算法线，这里设为0
						i.normal = 0.0;
					#endif
				#else
				//// 如果不使用顶点位移效果，直接进行标准变换
					i.worldPos = TransformObjectToWorld(v.vertex.xyz); //将顶点转换到世界空间
					i.normal = normalize(TransformObjectToWorldNormal(v.normal)); //将法线转换到世界空间
					i.pos = TransformObjectToHClip(v.vertex.xyz); //将顶点进行裁剪
				#endif

				return i;
			}

			float3 ComputeWorldSpacePosition(float2 positionNDC, float deviceDepth) {  //根据屏幕空间位置 和深度 计算世界空间顶点位置
				float4 positionCS = float4(positionNDC * 2.0 - 1.0, deviceDepth, 1.0); //将屏幕空间转-1到1区间 深度值做为z值
				float4 hpositionWS = mul(_CameraInvViewProjection, positionCS); //将上面顶点使用逆矩阵从投影视图空间转世界空间
				return hpositionWS.xyz / hpositionWS.w; //应用透视变化
			}

			float4 fp(v2f i) : SV_TARGET { // 片段着色器函数
					Light mainLight = GetMainLight(); // URP主光源数据，替代Built-in管线中的_LightColor0等内置变量
					float3 lightColor = mainLight.color; // 获取URP主方向光颜色
					float3 lightDir = length(_SunDirection) > 0.0001f ? -normalize(_SunDirection) : normalize(mainLight.direction); //获取模型像素到光源的方向向量，如果没有大气脚本则使用URP主光源方向
                float3 viewDir = normalize(_WorldSpaceCameraPos - i.worldPos); // 计算观察方向（从表面指向相机）
                float3 halfwayDir = normalize(lightDir + viewDir); // 计算半角向量（用于高光计算）

				// 初始化法线和高度变量
				float3 normal = 0.0f; 
				float height = 0.0f;

				#ifdef NORMALS_IN_PIXEL_SHADER  // 检查是否在片段着色器中计算法线

					#ifdef USE_FBM  // 检查是否使用FBM（分形布朗运动）方法	
						float3 fbm = fragmentFBM(i.worldPos);  // 在片段着色器中计算FBM效果
						height = fbm.x; //fbm结果的x值为高度
						normal.xy = fbm.yz; //fbm结果的yz为法线方向
					#else
					for (int wi = 0; wi < _WaveCount; ++wi) {  // // 使用传统波浪方法计算法线  变量所有的波浪
						normal += CalculateNormal(i.worldPos, _Waves[wi]); //传入顶点世界空间位置 和波浪类型计算法线
					}
					#endif
					#ifdef GERSTNER_WAVE //检查是否使用Gerstner波浪 是的话// Gerstner波浪的特殊法线计算
						normal = normalize(TransformObjectToWorldNormal(normalize(float3(-normal.x, 1.0f - normal.y, -normal.z))));
					#else
						normal = normalize(TransformObjectToWorldNormal(normalize(float3(-normal.x, 1.0f, -normal.y)))); // 普通波浪的法线计算
					#endif

				#else
					normal = normalize(i.normal);  // 如果在顶点着色器中计算法线，直接使用插值后的法线
				#endif

				// normal = centralDifferenceNormal(i.worldPos, 0.01f); //可选：使用中心差分法计算法线（当前被注释掉）
				normal.xz *= _NormalStrength; //应用法线强度
				normal = normalize(normal); //重新归一化法线

				float ndotl = DotClamped(lightDir, normal); //计算法线与光照方向的点积（限制在0-1范围）

				float3 diffuseReflectance = _DiffuseReflectance / PI;  // 计算漫反射反射率（Lambertian反射）
                float3 diffuse = lightColor * ndotl * diffuseReflectance;//将关照与法线的点乘结果与灯光颜色相乘乘反射系数  // 计算漫反射光照

				// Schlick Fresnel   // Schlick菲涅尔效应计算
				float3 fresnelNormal = normal; //涅斐尔及算法法线
				fresnelNormal.xz *= _FresnelNormalStrength;  // 调整菲涅尔法线强度
				fresnelNormal = normalize(fresnelNormal); //归一化菲涅尔法线
				float base = 1 - dot(viewDir, fresnelNormal); //菲涅尔效果计算
				float exponential = pow(base, _FresnelShininess); // 应用菲涅尔光泽度指数
				float R = exponential + _FresnelBias * (1.0f - exponential); // 计算菲涅尔反射率R
				R *= _FresnelStrength; // 应用菲涅尔强度
				
				float3 fresnel = _FresnelColor * R; // 计算菲涅尔颜色

				if (_UseEnvironmentMap) {  //// 检查是否使用环境贴图
					float3 reflectedDir = reflect(-viewDir, normal); //计算视角与法线的反射向量
					float3 skyCol = SAMPLE_TEXTURECUBE(_EnvironmentMap, sampler_EnvironmentMap, reflectedDir).rgb; //利用视角与法线的反射向量采样环境贴图
					float3 sun = _SunColor * pow(max(0.0f, DotClamped(reflectedDir, lightDir)), 500.0f);// 将视角与法线的反射向量与太阳光的方向向量点乘结果乘系数值 计算太阳高光 // 计算太阳高光（非常锐利的高光）

					fresnel = skyCol.rgb * R; // 使用环境颜色替代基础菲涅尔颜色
					fresnel += sun * R; // 添加太阳高光到菲涅尔效果中
				}


				float3 specularReflectance = _SpecularReflectance; // 高光反射计算 反射向量
				float3 specNormal = normal; //反射法线
				specNormal.xz *= _SpecularNormalStrength;//应用反射计算法线的强度
				specNormal = normalize(specNormal); //反射法线归一化
				// 计算高光强度（Blinn-Phong模型）
				float spec = pow(DotClamped(specNormal, halfwayDir), _Shininess) * ndotl; //将反射法线与半程向量点乘应用反射系数值 乘漫反射
                float3 specular = lightColor * specularReflectance * spec; // 计算灯光高光颜色

				// Schlick Fresnel but again for specular  // 为高光应用菲涅尔效应
				base = 1 - DotClamped(viewDir, halfwayDir); //视角方向与半程向量的点乘取反
				exponential = pow(base, 5.0f); // 应用菲涅尔光泽度指数
				R = exponential + _FresnelBias * (1.0f - exponential);//1-菲涅尔值取反 乘菲涅尔系数值 +菲涅尔效应

				specular *= R; // 应用菲涅尔到高光
				


				float3 tipColor = _TipColor * pow(height, _TipAttenuation);  // 计算顶部颜色（基于高度的颜色衰减） 高度值的顶部颜色衰减值次方乘顶点颜色做为波浪高度端点的颜色

				float3 output = _Ambient + diffuse + specular + fresnel + tipColor;  // 组合所有光照分量


				return float4(output, 1.0f); //输出
			}

			ENDHLSL
		}
	}
}