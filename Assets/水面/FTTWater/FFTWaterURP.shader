Shader "Custom/FFTWaterURP" { //着色器名
		
		Properties {
			[Enum(Off, 0, On, 1)] _ZWrite ("Z Write", Float) = 1 //是否开启深度写入 控制像素是否写入到深度里
		}

	HLSLINCLUDE
		// URP核心库：提供_WorldSpaceCameraPos、_ScreenParams、TransformObjectToHClip等SRP下的基础变量和空间变换函数。
		#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl" //cg代码区域在多个pass中共享  该部分皆为曲面细分部分
        #define _TessellationEdgeLength 10 //定义曲面细分的边缘长度阈值（控制细分程度）
		#define NEW_LIGHTING //宏定义 启用新的PBR光照模型

		//曲面细分因子结构体（存储三角形3条边和内部的细分程度）
        struct TessellationFactors {
            float edge[3] : SV_TESSFACTOR; // 三角形三个边缘条边的细分因子数组
            float inside : SV_INSIDETESSFACTOR; // 三角形内部的细分因子
        };

		// 曲面细分启发式函数，根据边缘长度和距离计算细分因子程度  基于距离的自适应细分
		//用公式：细分因子 = (边长度 × 屏幕高度) / (基准长度 × 视角距离^1.2)
        float TessellationHeuristic(float3 cp0, float3 cp1) { //给定三角形一边的两个顶点位置
            float edgeLength = distance(cp0, cp1); //计算两点之间的距离 使用 欧氏距离：√[(x1-x0)²+(y1-y0)²+(z1-z0)²] 公式
            float3 edgeCenter = (cp0 + cp1) * 0.5; //// 计算两点的中点坐标
            float viewDistance = distance(edgeCenter, _WorldSpaceCameraPos); //计算边缘中点到相机的距离
			//// 细分因子公式：边缘长度 * 屏幕高度 / (细分阈值 * 视角距离^1.2)
			///距离越远，细分因子越小，减少远处几何体复杂度 距离相机越近、边缘越长，细分越密集（平衡性能与细节）
            return edgeLength * _ScreenParams.y / (_TessellationEdgeLength * (pow(viewDistance * 0.5f, 1.2f)));
        }

		// 判断三角形的部分像素是否完全在位于裁剪屏幕平面之外（用于裁剪不可见三角形，优化性能）
        bool TriangleIsBelowClipPlane(float3 p0, float3 p1, float3 p2, int planeIndex, float bias) {
            float4 plane = unity_CameraWorldClipPlanes[planeIndex]; // 获取相机裁剪平面（齐次平面方程：ax+by+cz+d=0） 根据planeIndex获取视锥体的拆分部分平面

        	 // 点到平面的距离：dot(plane, float4(p,1))，若所有点距离<bias则在表示在平面外  返回true
            return dot(float4(p0, 1), plane) < bias && dot(float4(p1, 1), plane) < bias && dot(float4(p2, 1), plane) < bias;
        }

		// // 判断三角形是否需要被裁剪（在任意一个裁剪平面后方则裁剪） 检查三角形是否整个在所有裁剪平面之外 如果三角形有部分在视锥体内也渲染
        bool cullTriangle(float3 p0, float3 p1, float3 p2, float bias) { //// 检查三角形是否在任意一个裁剪平面（左、右、下、上）之外
            return TriangleIsBelowClipPlane(p0, p1, p2, 0, bias) || //传入三角形传入到判断是否在外函数进行判断 将顶点与摄像机的视锥体每个平面进行判断 当有一个为true时这三角形有部分在视锥体外需要裁剪
                   TriangleIsBelowClipPlane(p0, p1, p2, 1, bias) ||
                   TriangleIsBelowClipPlane(p0, p1, p2, 2, bias) ||
                   TriangleIsBelowClipPlane(p0, p1, p2, 3, bias);
        }
    ENDHLSL

	SubShader {
		Tags {
			"RenderPipeline" = "UniversalPipeline" // 指定该SubShader只在URP中使用，避免Built-in管线错误匹配。
			"RenderType" = "Opaque" // 水面按不透明物体参与URP前向渲染；当前片元输出alpha固定为1。
			"Queue" = "Geometry" // 渲染队列使用Geometry，保证正常写入/测试深度。
		}
		

		Pass {
			Name "ForwardLit" // URP前向光照Pass名称，便于Frame Debugger识别。
			Tags { "LightMode" = "UniversalForward" } // URP使用UniversalForward作为前向渲染Pass标签，替代Built-in的ForwardBase。
			ZWrite [_ZWrite] // 使用属性控制深度写入。
			
			
			
			HLSLPROGRAM



			#pragma vertex dummyvp //顶点着色器为
			#pragma hull hp		   //外壳着色器 用于曲面细分控制
			#pragma domain dp	   //域着色器曲面细分后的顶点处理 细分插值
			#pragma geometry gp	   //几何着色器处理图元
			#pragma fragment fp    //片段着色器
			#pragma target 5.0     // 曲面细分Hull/Domain和Geometry Shader需要较高Shader Model，DX11/Metal等平台才支持。
			


			// URP核心库：替代Built-in管线的UnityPBSLighting.cginc / AutoLight.cginc。
			// Core.hlsl提供空间变换、矩阵、深度线性化等函数；Lighting.hlsl提供GetMainLight等URP光照接口。
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

			struct TessellationControlPoint {  /// 曲面细分控制点结构体
                float4 vertex : INTERNALTESSPOS;  //顶点位置 （内部曲面细分位置语义
                float2 uv : TEXCOORD0; //采样坐标v
            };

			struct VertexData { // 原始顶点数据结构体（从模型输入）
				float4 vertex : POSITION; 
                float2 uv : TEXCOORD0;
			};
			// 顶点着色器到几何着色器的数据结构体
			struct v2g {
				float4 pos : SV_POSITION;  //顶点位置
                float2 uv : TEXCOORD0; //uv
				float3 worldPos : TEXCOORD1; //世界空间顶点位置
				float depth : TEXCOORD2; //顶点在屏幕空间像素深度  深度衰减因子
			};


			#define PI 3.14159265358979323846

			float DotClamped(float3 a, float3 b) {
				return saturate(dot(a, b)); // URP中不再依赖UnityPBSLighting.cginc，因此手动实现DotClamped：点乘后限制到0-1。
			}

			float hash(uint n) {  // 整数哈希函数（用于随机数生成，基于Hugo Elias的算法）
				// integer hash copied from Hugo Elias
				n = (n << 13U) ^ n;  // 位运算混淆
				n = n * (n * n * 15731U + 0x789221U) + 0x1376312589U;   // 乘法混淆
				return float(n & uint(0x7fffffffU)) / float(0x7fffffff);  // 返回0-1之间的随机浮点数
			}

			// 以下是大量的材质参数声明

			float3 _SunDirection, _SunColor; // 太阳方向和颜色

			float _NormalStrength, _FresnelNormalStrength, _SpecularNormalStrength; // 法线强度、Fresnel法线强度、镜面法线强度
				TEXTURECUBE(_EnvironmentMap); // URP/HLSL风格环境立方体贴图声明，替代Built-in的samplerCUBE。
				SAMPLER(sampler_EnvironmentMap); // 环境贴图采样器，SAMPLE_TEXTURECUBE会使用它执行采样。
				int _UseEnvironmentMap; // 是否使用环境贴图

			float3 _Ambient, _DiffuseReflectance, _SpecularReflectance, _FresnelColor, _TipColor; // 环境光、漫反射率、镜面反射率、Fresnel颜色、尖端颜色
			float _Shininess, _FresnelBias, _FresnelStrength, _FresnelShininess, _TipAttenuation; // 光泽度、Fresnel偏移、Fresnel强度、Fresnel光泽度、尖端衰减
			float _Roughness, _FoamRoughnessModifier; // 粗糙度、泡沫粗糙度修饰符
			float _Tile0, _Tile1, _Tile2, _Tile3; // 四层纹理的平铺系数
			float3 _SunIrradiance, _ScatterColor, _BubbleColor, _FoamColor; // 太阳辐射、散射颜色、气泡颜色、泡沫颜色
			float _HeightModifier, _BubbleDensity; // 高度修饰符、气泡密度
			float _DisplacementDepthAttenuation, _FoamDepthAttenuation, _NormalDepthAttenuation; // 位移深度衰减、泡沫深度衰减、法线深度衰减
			float _WavePeakScatterStrength, _ScatterStrength, _ScatterShadowStrength, _EnvironmentLightStrength; // 波峰散射强度、散射强度、散射阴影强度、环境光强度

			int _DebugTile0, _DebugTile1, _DebugTile2, _DebugTile3; // 调试模式开关（各层纹理）
			int _ContributeDisplacement0, _ContributeDisplacement1, _ContributeDisplacement2, _ContributeDisplacement3; // 各层纹理是否贡献到位移
			int _DebugLayer0, _DebugLayer1, _DebugLayer2, _DebugLayer3; // 各层调试模式开关
			float _FoamSubtract0, _FoamSubtract1, _FoamSubtract2, _FoamSubtract3; // 各层泡沫减法系数

			float4x4 _CameraInvViewProjection; // 相机逆视图投影矩阵
				TEXTURE2D(_CameraDepthTexture); // URP深度纹理声明。当前Shader主要用顶点自身深度衰减，保留该变量便于扩展屏幕空间水深效果。
				SAMPLER(sampler_CameraDepthTexture); // 深度纹理采样器。
            TEXTURE2D_ARRAY(_DisplacementTextures); // URP/HLSL风格位移纹理数组声明（包含高度和泡沫信息）。
            SAMPLER(sampler_DisplacementTextures); // 位移纹理数组采样器。
            TEXTURE2D_ARRAY(_SlopeTextures); // URP/HLSL风格斜率纹理数组声明（包含法线信息）。
            SAMPLER(sampler_SlopeTextures); // 斜率纹理数组采样器。
            SamplerState point_repeat_sampler, linear_repeat_sampler, trilinear_repeat_sampler; // 不同采样状态的采样器，保留原声明以便后续扩展自定义采样。

            float _Tile;// 全局平铺系数

			//执行流程先根据虚拟顶点着色器计算正常顶点传递到-》外壳着色器（细分控制器） 用于曲面细分控制计算曲面细分因子 -》 域着色器（细分计算着色器）执行曲面细分后的顶点处理 细分插值 细分后的三角形所有顶点执行真实顶点着色器计算处顶点的偏移 传递-》
			//-》几何着色器 -》片段着色器

			TessellationControlPoint dummyvp(VertexData v) { // 虚拟顶点着色器函数（实际未使用）  为曲面细分准备阶段提供数据
				TessellationControlPoint p;  //声明曲面细分控制点结构体 对象 用于保持曲面细分前的顶点位置
				p.vertex = v.vertex; //设置曲面细分着色器 当前顶点
				p.uv = v.uv; //当前坐标

				return p;
			}

			v2g vp(VertexData v) { // 实际的顶点处理函数，应用位移和转换
				v2g g; //声明传给几何着色器的结构体对象
				v.uv = 0; // 重置UV（后续使用世界坐标计算）
                g.worldPos = TransformObjectToWorld(v.vertex.xyz);  // 模型空间转世界空间（矩阵乘法）

				 // 使用当前世界坐标顶点的xz轴的值进行采样 采样4层位移纹理（xyz为位移，w为泡沫数据），并根据调试开关和贡献开关控制是否启用
                float3 displacement1 = SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures, g.worldPos.xz * _Tile0, 0, 0).xyz * _DebugLayer0 * _ContributeDisplacement0;
                float3 displacement2 = SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures, g.worldPos.xz * _Tile1, 1, 0).xyz * _DebugLayer1 * _ContributeDisplacement1;
                float3 displacement3 = SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures, g.worldPos.xz * _Tile2, 2, 0).xyz * _DebugLayer2 * _ContributeDisplacement2;
                float3 displacement4 = SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures, g.worldPos.xz * _Tile3, 3, 0).xyz * _DebugLayer3 * _ContributeDisplacement3;
				float3 displacement = displacement1 + displacement2 + displacement3 + displacement4; //叠加总位移结果

				float4 clipPos = TransformObjectToHClip(v.vertex.xyz); //计算顶点在剪空间位置
				float depth = 1 - Linear01Depth(clipPos.z / clipPos.w, _ZBufferParams); // 线性深度归一化 / 计算线性深度值：1表示近平面，0表示远平面 将当前的z轴深度值进行透视操作执行dx图形api的 转换到0到1的范围 并取反


				// 基于看到的深度进行衰减位移（远处位移衰减为0，优化性能和视觉效果）
				// 公式：lerp(0, displacement, depth^衰减系数)，pow确保非线性衰减  顶点距离摄像机越远则偏移编号越小
				displacement = lerp(0.0f, displacement, pow(saturate(depth), _DisplacementDepthAttenuation));

				v.vertex.xyz += TransformWorldToObjectDir(displacement.xyz, false); //将偏移后点的世界空间顶点坐标位置转换到对象空间
				
                g.pos = TransformObjectToHClip(v.vertex.xyz); //  // 计算最终裁剪空间位置
                g.uv = g.worldPos.xz; //使用世界空间XZ坐标作为UV（用于后续纹理采样）
                g.worldPos = TransformObjectToWorld(v.vertex.xyz); //重新计算偏移后的世界空间顶点位置
				g.depth = depth; // 存储深度值
				return g;
			}

			struct g2f { // 几何着色器到片段着色器的传输数据
				v2g data;  //继承v2g 顶点传给几何着色器的结构体的数据
				float2 barycentricCoordinates : TEXCOORD9; // 重心坐标（用于插值）
			};

			// Hull着色器的补丁函数（计算曲面细分因子）
			TessellationFactors PatchFunction(InputPatch<TessellationControlPoint, 3> patch) { //输入虚拟顶点着色器输出的3个顶点的曲面细分控制点结构体 数据
				//将三个顶点转换到世界坐标
                float3 p0 = TransformObjectToWorld(patch[0].vertex.xyz); 
                float3 p1 = TransformObjectToWorld(patch[1].vertex.xyz);
                float3 p2 = TransformObjectToWorld(patch[2].vertex.xyz);

                TessellationFactors f; //定义曲面细分因子结构体（存储三角形3条边和内部的细分程度） 对象
                float bias = -0.5 * 100;   // 裁剪偏置值
                if (cullTriangle(p0, p1, p2, bias)) {  // 执行视锥体剔除 若三角形被裁剪，细分因子设为0（不细分） 不为0执行细分
                    f.edge[0] = f.edge[1] = f.edge[2] = f.inside = 0; //三角形有被裁剪 不执行细分 三角形细分和内部细分为0
                } else {
                    f.edge[0] = TessellationHeuristic(p1, p2); // 边0（p1-p2）的细分因子
                    f.edge[1] = TessellationHeuristic(p2, p0); // 边1（p2-p0）的细分因子
                    f.edge[2] = TessellationHeuristic(p0, p1); // 边2（p0-p1）的细分因子
                	//内部三角形的细分 内部细分因子为三边平均值
                    f.inside = (TessellationHeuristic(p1, p2) +
                                TessellationHeuristic(p2, p0) +
                                TessellationHeuristic(p1, p2)) * (1 / 3.0);
                }
                return f;
            }
			// Hull着色器（定义曲面细分模式并传递控制点） 类似opengl曲面细分控制着色器
            [domain("tri")]  // 域类型：三角形
            [outputcontrolpoints(3)]  // 输出控制点数量：3（三角形） 
            [outputtopology("triangle_cw")] // 输出拓扑：顺时针三角形
            [partitioning("integer")]  // 细分分区模式：整数
            [patchconstantfunc("PatchFunction")] // 补丁函数：PatchFunction 计算边缘的曲面细分因子
            TessellationControlPoint hp(InputPatch<TessellationControlPoint, 3> patch, uint id : SV_OUTPUTCONTROLPOINTID) { //输入虚拟顶点着色器输出的3个顶点的曲面细分控制点结构体 数据
				//传到PatchFunction补丁函数（计算曲面细分因子） 进行计算 细分 将计算好
                return patch[id];  // 直接传递输出曲面细分顶点点控制点
            }

			//// 几何着色器（处理三角形图元，传递重心坐标）
            [maxvertexcount(3)]   // 最大输出顶点数：3（三角形）
            void gp(triangle v2g g[3], inout TriangleStream<g2f> stream) { //输入细分后三个顶点构成的三角形位置
                g2f g0, g1, g2; //生成几何着色器到片段着色器的传输数据 存储每个顶点自带的存储数据（顶点位置 uv 世界坐标位置 深度 ）
                g0.data = g[0]; 
                g1.data = g[1];
                g2.data = g[2];

                g0.barycentricCoordinates = float2(1, 0);  //存储每个顶点的重心坐标
                g1.barycentricCoordinates = float2(0, 1);
                g2.barycentricCoordinates = float2(0, 0);

                stream.Append(g0); //存储到数据流输出的数组
                stream.Append(g1);
                stream.Append(g2);
            }
			
			 // 宏定义：基于重心坐标插值顶点数据（x+y+z=1，z=1-x-y）
            #define DP_INTERPOLATE(fieldName) data.fieldName = \
                data.fieldName = patch[0].fieldName * barycentricCoordinates.x + \
                                 patch[1].fieldName * barycentricCoordinates.y + \
                                 patch[2].fieldName * barycentricCoordinates.z;               

            [domain("tri")]  // Domain着色器（曲面细分后插值顶点数据） (类似opengl1的细分计算着色器)   // 域类型：三角形
            v2g dp(TessellationFactors factors, OutputPatch<TessellationControlPoint, 3> patch, float3 barycentricCoordinates : SV_DOMAINLOCATION) {
				//domain着色器传入 曲面细分因子结构体对象 和曲面细分控制点结构体对象 以及重心坐标  （将两者 数据对象传递给细分图元生成 因为细分图元生成器无法访问  细分图元生成器自动计算细分后的三角形图元 并在细分计算着色器 计算生成细分后每个顶点） 
				//细分图元生成后的三角形每一条边都具有细分后的顶点位置重心坐标 根据细分图元后的一条边的重心坐标生成细分后的顶点
                VertexData data; //声明顶点着色器结构体对象
                DP_INTERPOLATE(vertex)//执行宏定义将基于重心坐标和（根据曲面控制器计算处理的三角形边缘的曲面细分因子）计算插值顶点数据 传递到 顶点着色器结构体对象data
                DP_INTERPOLATE(uv) //执行宏定义将基于重心坐标插值顶点UV数据传递到 顶点着色器结构体对象data

                return vp(data); //将曲面细分后的顶点数据传递到真实顶点着色器计算细分后顶点偏移
            }

			float SchlickFresnel(float3 normal, float3 viewDir) {
				// 0.02f comes from the reflectivity bias of water kinda idk it's from a paper somewhere i'm not gonna link it tho lmaooo
				return 0.02f + (1 - 0.02f) * (pow(1 - DotClamped(normal, viewDir), 5.0f));
			}

			float SmithMaskingBeckmann(float3 H, float3 S, float roughness) { //BRDF的 几何遮蔽  Smith模型 传入半程向量  视角或者光方向 粗糙度  Smith遮蔽函数（Beckmann分布的近似，计算微表面的自遮蔽）
				//公式：G1(v) = (2 / (1 + √(1 + α² tan²θv)))，其中α是粗糙度，θv是视线与法线夹角
				// 此处使用拟合近似：(1 - 1.259a + 0.396a²) / (3.535a + 2.181a²)，a = cosθ / (α sinθ)
				float hdots = max(0.001f, DotClamped(H, S));  //半程向量与方向的点乘 
				float a = hdots / (roughness * sqrt(1 - hdots * hdots)); //半程向量与方向点乘的结果除以（粗糙度乘（半程向量与方向点乘的结果的平方取方的开根））  // 转换为角度相关参数
				float a2 = a * a; //做二次方
				//	// 拟合公式（当a < 1.6时有效，否则返回0）
				return a < 1.6f ? (1.0f - 1.259f * a + 0.396f * a2) / (3.535f * a + 2.181 * a2) : 0.0f;
			}
			//	// Beckmann微表面分布函数（描述法线分布概率）  // 公式：D(m) = exp(-tan²θ/α²) / (π * α² * cos⁴θ)   // 其中θ是微表面法线与宏表面法线的夹角，α是粗糙度
			float Beckmann(float ndoth, float roughness) {  //PBR的法线分布函数  传入法线与半程向量的夹角 和粗糙值
				float exp_arg = (ndoth * ndoth - 1) / (roughness * roughness * ndoth * ndoth);

				return exp(exp_arg) / (PI * roughness * roughness * ndoth * ndoth * ndoth * ndoth);
			}

			float4 fp(g2f f) : SV_TARGET {  //片段着色器
				// URP主光源数据。原Built-in版本依赖外部传入太阳方向；URP版在没有Atmosphere脚本时自动回退到GetMainLight。
				Light mainLight = GetMainLight(); // 从URP Lighting.hlsl获取主方向光，包含direction和color。
                float3 lightDir = dot(_SunDirection, _SunDirection) > 0.0001f ? -normalize(_SunDirection) : normalize(mainLight.direction);  //光方向向量：优先使用大气系统太阳方向，否则使用URP主光。
				float3 lightColor = dot(_SunColor, _SunColor) > 0.0001f ? _SunColor : mainLight.color; // 光源颜色：优先使用大气系统太阳色，否则使用URP主光颜色。
				float3 sunIrradiance = dot(_SunIrradiance, _SunIrradiance) > 0.0001f ? _SunIrradiance : lightColor; // PBR分支使用的太阳辐照度，为黑色时自动退回主光颜色。
                float3 viewDir = normalize(_WorldSpaceCameraPos - f.data.worldPos); //细分顶点位置指向摄像机的方向向量
                float3 halfwayDir = normalize(lightDir + viewDir); //计算半程向量
				float depth = f.data.depth; //获取当前片段的深度
				float LdotH = DotClamped(lightDir, halfwayDir);// // 光线与半程向量的点积（ clamped to [0,1]）
				float VdotH = DotClamped(viewDir, halfwayDir);// 视线与半程向量的点积
				
				// 采样四个频率层的位移和泡沫纹理 // 每层包含RGB位移和A通道泡沫信息
                float4 displacementFoam1 = SAMPLE_TEXTURE2D_ARRAY(_DisplacementTextures, sampler_DisplacementTextures, f.data.uv * _Tile0, 0) * _DebugLayer0;
				displacementFoam1.a += _FoamSubtract0;  //引用个层泡沫减去的系数各层泡沫减法系数 
                float4 displacementFoam2 = SAMPLE_TEXTURE2D_ARRAY(_DisplacementTextures, sampler_DisplacementTextures, f.data.uv * _Tile1, 1) * _DebugLayer1;
				displacementFoam2.a += _FoamSubtract1;
                float4 displacementFoam3 = SAMPLE_TEXTURE2D_ARRAY(_DisplacementTextures, sampler_DisplacementTextures, f.data.uv * _Tile2, 2) * _DebugLayer2;
				displacementFoam3.a += _FoamSubtract2;
                float4 displacementFoam4 = SAMPLE_TEXTURE2D_ARRAY(_DisplacementTextures, sampler_DisplacementTextures, f.data.uv * _Tile3, 3) * _DebugLayer3;
				displacementFoam4.a += _FoamSubtract3;
                float4 displacementFoam = displacementFoam1 + displacementFoam2 + displacementFoam3 + displacementFoam4; // 合并所有层的位移和泡沫信息

						//   // 采样四个频率层的斜率纹理采样4层斜率纹理（斜率用于计算水面法线）
				float2 slopes1 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures, f.data.uv * _Tile0, 0).xy * _DebugLayer0;
				float2 slopes2 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures, f.data.uv * _Tile1, 1).xy * _DebugLayer1;
				float2 slopes3 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures, f.data.uv * _Tile2, 2).xy * _DebugLayer2;
				float2 slopes4 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures, f.data.uv * _Tile3, 3).xy * _DebugLayer3;
				float2 slopes = slopes1 + slopes2 + slopes3 + slopes4; // 合并所有层的斜率信息 总斜率方向信息

				
				slopes *= _NormalStrength; // 应用缩放斜率强度（控制法线起伏）
					// 计算泡沫强度（基于深度衰减，远处泡沫消失）
				float foam = lerp(0.0f, saturate(displacementFoam.a), pow(depth, _FoamDepthAttenuation)); //更具深度与泡沫深度衰减的次方做为系数插值 无泡沫效果到A通道泡沫面积效果的插值

				#ifdef NEW_LIGHTING // 使用新PBR光照模型
				float3 macroNormal = float3(0, 1, 0); // 宏观法线（平静水面的法线）宏观水面的上方向法线 整体片段的宏观方向
				// 从斜率计算微观法线：slopes.xy是dx/dy和dz/dy，法线为(-dx, 1, -dz) 斜率(-slopes.x, -slopes.y)对应法线的XZ分量 利用斜率改变当前像素片段的法线方向
				float3 mesoNormal = normalize(float3(-slopes.x, 1.0f, -slopes.y));
				// 基于深度衰减法线（远处法线趋近于宏观法线）  根据深度与法线深度系数计算的次方做为摄像机到水面的距离系数 越远水面越平坦 越近水面法线越偏移
				mesoNormal = normalize(lerp(float3(0, 1, 0), mesoNormal, pow(saturate(depth), _NormalDepthAttenuation)));
				mesoNormal = normalize(TransformObjectToWorldNormal(normalize(mesoNormal))); //将计算号的偏移法线转换到世界坐标空间 做为法线

				float NdotL = DotClamped(mesoNormal, lightDir); //新法线与光方向点乘并钳制到0到1区间  // 法线与光线的点积（漫反射因子）  // 计算兰伯特项

				
				float a = _Roughness + foam * _FoamRoughnessModifier; // 计算有效粗糙度（考虑泡沫影响） // 泡沫区域通常更粗糙 基础的粗糙度加上泡沫的粗糙度
				float ndoth = max(0.0001f, dot(mesoNormal, halfwayDir)); // 法线与半程向量的点积

				// 计算Smith遮蔽因子（视线和光线方向） 计算几何遮蔽项（Smith模型 类似opengl 里的写法）
				float viewMask = SmithMaskingBeckmann(halfwayDir, viewDir, a); //传入半程向量 视角方向 粗糙度
				float lightMask = SmithMaskingBeckmann(halfwayDir, lightDir, a); //传入半程向量 光方向 粗糙度
				 // 整体遮蔽因子（1/(1 + G1(v) + G1(l))）
				float G = rcp(1 + viewMask + lightMask); //BRDF的几何项

				// 菲涅尔效应（基于IOR计算基础反射率）
				float eta = 1.33f;  // 水的折射率（相对空气）
				float R = ((eta - 1) * (eta - 1)) / ((eta + 1) * (eta + 1));   // 垂直入射时的反射率
				float thetaV = acos(viewDir.y);  // 视线与法线的夹角

				// 修正的菲涅尔公式（考虑粗糙度影响）
				float numerator = pow(1 - dot(mesoNormal, viewDir), 5 * exp(-2.69 * a));//使用修改后带有粗糙度的涅斐尔方程计算 该部分为涅斐尔（1-（h*v））^5的改版带粗糙度
				float F = R + (1 - R) * numerator / (1.0f + 22.7f * pow(a, 1.5f)); //涅斐尔计算
				F = saturate(F); //// 确保在[0,1]范围内

				// 高光计算（基于Beckmann分布的PBR公式） // BRDF = (F * D * G) / (4 * (n·l) * (n·v))
				float3 specular = sunIrradiance * F * G * Beckmann(ndoth, a); //将几何函数 涅斐尔范畴 法线分布函数 乘太阳辐射度
				specular /= 4.0f * max(0.001f, DotClamped(macroNormal, lightDir)); //  // 分母项 标准BRDF的计算
				specular *= DotClamped(mesoNormal, lightDir); //乘法线与光方向的点乘 添加漫反射项

				// 环境反射（从立方体贴图采样）
				float3 envReflection = SAMPLE_TEXTURECUBE(_EnvironmentMap, sampler_EnvironmentMap, reflect(-viewDir, mesoNormal)).rgb;  //采样环境立方体贴图
				envReflection *= _EnvironmentLightStrength;// 缩放环境光强度

				// 水面高度（用于散射计算） 散射效果计算
				float H = max(0.0f, displacementFoam.y) * _HeightModifier;  // 波高 偏移纹理的高度乘 高度修饰符
				float3 scatterColor = _ScatterColor; // 散射基础颜色
				float3 bubbleColor = _BubbleColor; // 气泡颜色
				float bubbleDensity = _BubbleDensity;  // 气泡密度

				// 散射系数计算（基于波峰、视角、光线方向）
				// k1：波峰散射（与波高、光线-视线夹角、光线-法线夹角相关） 波峰散射强度 乘 波高乘（光方向与视角方向的夹角的4次方）乘（光方向与法线的点乘系数半值-0.5系数的3次方）
				float k1 = _WavePeakScatterStrength * H * pow(DotClamped(lightDir, -viewDir), 4.0f) * pow(0.5f - 0.5f * dot(lightDir, mesoNormal), 3.0f);
				// k2：视角相关散射（与视线-法线夹角平方相关）
				float k2 = _ScatterStrength * pow(DotClamped(viewDir, mesoNormal), 2.0f);//散射强度乘 （视角反向与法线的点乘）的2次方
				// k3: 散射阴影 - 与漫反射相关
				float k3 = _ScatterShadowStrength * NdotL;//散射阴影强度乘法线与光方向的点乘
				// k4: 气泡散射 - 恒定密度贡献
				float k4 = bubbleDensity;
				//// 组合散射效果 波峰散射和视角相关散射叠加运用散射基础颜色*（1 + lightMask）的取反
				float3 scatter = (k1 + k2) * scatterColor * sunIrradiance * rcp(1 + lightMask);
				scatter += k3 * scatterColor * sunIrradiance + k4 * bubbleColor * sunIrradiance; //叠加散射阴影 和气泡散射（乘太阳光辐射度） 

				// 最终颜色合成
                // 公式：输出 = (1 - F) * 散射 + 镜面反射 + F * 环境反射 f为涅斐尔效果
				float3 output = (1 - F) * scatter + specular + F * envReflection; 
				output = max(0.0f, output);   // 确保颜色非负
				output = lerp(output, _FoamColor, saturate(foam)); // 泡沫颜色混合

				#else
				slopes *= _NormalStrength;
				float3 normal = normalize(float3(-slopes.x, 1.0f, -slopes.y));
                normal = normalize(TransformObjectToWorldNormal(normalize(normal)));

				float ndotl = DotClamped(lightDir, normal);

				float3 diffuseReflectance = _DiffuseReflectance / PI;
                float3 diffuse = lightColor * ndotl * diffuseReflectance;

				// Schlick Fresnel
				float3 fresnelNormal = normal;
				fresnelNormal.xz *= _FresnelNormalStrength;
				fresnelNormal = normalize(fresnelNormal);
				float base = 1 - dot(viewDir, fresnelNormal);
				float exponential = pow(base, _FresnelShininess);
				float R = exponential + _FresnelBias * (1.0f - exponential);
				R *= _FresnelStrength;
				
				float3 fresnel = _FresnelColor * R;
                
				if (_UseEnvironmentMap) {
					float3 reflectedDir = reflect(-viewDir, normal);
					float3 skyCol = SAMPLE_TEXTURECUBE(_EnvironmentMap, sampler_EnvironmentMap, reflectedDir).rgb;
					float3 sun = lightColor * pow(max(0.0f, DotClamped(reflectedDir, lightDir)), 500.0f); // 使用URP主光/大气太阳颜色生成太阳高光。

					fresnel = skyCol.rgb * R;
					fresnel += sun * R;
				}


				float3 specularReflectance = _SpecularReflectance;
				float3 specNormal = normal;
				specNormal.xz *= _SpecularNormalStrength;
				specNormal = normalize(specNormal);
				float spec = pow(DotClamped(specNormal, halfwayDir), _Shininess) * ndotl;
                float3 specular = lightColor * specularReflectance * spec;

				// Schlick Fresnel but again for specular
				base = 1 - DotClamped(viewDir, halfwayDir);
				exponential = pow(base, 5.0f);
				R = exponential + _FresnelBias * (1.0f - exponential);

				specular *= R;
				

				float3 output = _Ambient + diffuse + specular + fresnel;
				output = lerp(output, _TipColor, saturate(foam));
				#endif

				 // 调试显示模式 - 显示不同频率层的波浪图案
				if (_DebugTile0) {
					// 使用余弦函数生成网格图案显示平铺0
					output = cos(f.data.uv.x * _Tile0 * PI) * cos(f.data.uv.y * _Tile0 * PI);
				}

				if (_DebugTile1) {
					// 高频余弦图案显示平铺1
					output = cos(f.data.uv.x * _Tile1) * 1024 * cos(f.data.uv.y * _Tile1) * 1024;
				}

				if (_DebugTile2) {
					// 高频余弦图案显示平铺2
					output = cos(f.data.uv.x * _Tile2) * 1024 * cos(f.data.uv.y * _Tile2) * 1024;
				}

				if (_DebugTile3) {
					// 高频余弦图案显示平铺3
					output = cos(f.data.uv.x * _Tile3) * 1024 * cos(f.data.uv.y * _Tile3) * 1024;
				}
				// 返回最终颜色（不透明）
				return float4(output, 1.0f);
			}

			ENDHLSL
		}
	}
}