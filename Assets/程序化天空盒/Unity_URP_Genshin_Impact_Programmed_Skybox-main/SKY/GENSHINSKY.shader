Shader "Unlit URP Shader"                                   // 定义 Shader 名称，显示在 Unity 材质面板和 Shader 选择器里
{
    Properties                                              // Properties 块：这里定义所有可在材质面板中调节的参数
    {
        _upPartSunColor("高空近太阳颜色", Color) = (0.00326,0.18243,0.63132,1)           // 天空高处、靠近太阳方向时使用的颜色
        _upPartSkyColor("高空远太阳颜色", Color) = (0.02948,0.1609,0.27936,1)            // 天空高处、远离太阳方向时使用的颜色
        _downPartSunColor("水平线近太阳颜色", Color) = (0.30759,0.346,0.24592,1)         // 地平线附近、靠近太阳方向时使用的颜色
        _downPartSkyColor("水平线远太阳颜色", Color) = (0.04305,0.26222,0.46968,1)       // 地平线附近、远离太阳方向时使用的颜色
        _IrradianceMapR_maxAngleRange("天空主色垂直变化范围", Range(0, 1)) = 0.44837      // 用于控制主天空颜色在垂直方向上的采样范围，范围越小变化越集中
        _mainColorSunGatherFactor("近太阳颜色聚集程度", Range(0, 5)) = 0.31277            // 控制太阳附近颜色向太阳方向聚集的强弱

        _SunAdditionColor("太阳追加点颜色", Color) = (0.90409,0.7345,0.13709, 1)          // 太阳附加高光/色斑的颜色
        _SunAdditionIntensity("太阳追加点颜色强度", Range(0, 3)) = 1.48499                // 太阳附加高光的强度
        _IrradianceMapG_maxAngleRange("太阳追加点垂直变化范围", Range(0, 1)) = 0.69804    // 用于太阳附加色在垂直方向上的变化范围

        _SunRadius("太阳圆盘大小", Range(0, 50)) = 1                                      // 太阳圆盘半径控制参数，值越大太阳看起来越大
        _SunInnerBoundary("太阳内边界", Range(0, 10)) = 1                                 // smoothstep 的内边界，控制太阳核心区域
        _SunOuterBoundary("太阳外边界", Range(0, 10)) = 1                                 // smoothstep 的外边界，控制太阳边缘柔和程度
        _sun_disk_power_999("太阳圆盘power", Range(0, 1000)) = 1000                       // 用 pow 制造高亮圆盘时的指数，越高越锐利
        _SunScattering("散射扩散", Range(0, 2)) = 1                                        // 太阳散射扩散范围，越大散射区域越宽
        _sun_color_intensity("太阳圆盘颜色强度", Range(0, 10)) = 1.18529                   // 太阳圆盘本身的亮度倍增
        _sun_color("太阳圆盘颜色", Color) = (0.90625, 0.43019, 0.11743, 1)                // 太阳圆盘颜色
        _sun_color_Scat("日出日落散射颜色", Color) = (0.90625, 0.43019, 0.11743, 1)       // 日出日落时的散射颜色

        _MoonTex("月亮贴图", 2D) = "white"{}                                               // 月亮贴图，用于月亮表面纹理
        _MoonRadius ("月亮大小", Range(0, 10)) = 3                                         // 月亮贴图缩放，相当于控制月亮显示大小
        _MoonMaskRadius("月亮遮罩大小", range(1, 10)) = 5                                  // 月亮遮罩半径，用于控制月亮可见范围
        _mainColorMoonGatherFactor("近月亮颜色聚集程度", Range(0, 5)) = 0.31277            // 月亮附近颜色聚集强度
        _MoonScatteringColor("月亮散射颜色聚集程度", Color) = (1,1,1,1)                    // 月亮周边散射颜色
        _Moon_color("月亮圆盘颜色", Color) = (0.90625, 0.43019, 0.11743, 1)               // 月亮整体着色颜色
        _Moon_color_intensity("月亮颜色强度", Range(0, 10)) = 1.18529                      // 月亮亮度强度

        _IrradianceMap("Irradiance Map",2D)= "while"{}                                     // 辐照度查找贴图，R/G 通道分别用于不同天空颜色插值；这里 "while" 很可能是 "white" 的笔误

        _starColorIntensity("星星颜色强度", Range(0, 50)) = 22.7                           // 星星整体颜色强度
        _starIntensityLinearDamping("星星遮蔽", Range(0, 1)) = 0.80829                     // 星星强度线性衰减阈值，越高可见星越少

        _NoiseMap("NoiseMap", 2D) = "white" {}                                             // 噪声图，用于控制星星出现与闪烁
        _StarDotMap("StarDotMap", 2D) = "white" {}                                         // 星点分布图，用于决定哪些位置有星星
        StarColorLut("StarColorLut", 2D) = "white" {}                                      // 星星颜色查找表，用噪声值映射不同星体颜色；这里名字没有下划线，和后文 _StarColorLut 不一致
        [HideInInspector] _StarColorLut_ST("_NoiseMap_ST", Vector) = (0.5,1,0,0)          // 星星颜色 LUT 的 Tiling/Offset 参数，隐藏不显示

        [HideInInspector]_StarDotMap_ST("StarDotMap_ST", Vector) = (10,10,0,0)            // 星点贴图的缩放与偏移参数，控制星点密度
        _NoiseSpeed("c_NoiseSpeed", Range( 0 , 1)) = 0.293                                 // 噪声滚动速度，用于制造星星变化感

        _SunDirection("_SunDirection", Vector) = (-0.26102,0.12177,-0.95762, 0)           // 太阳方向向量，通常由脚本从主光方向传入
        _MoonDirection("_MoonDirection", Vector) = (-0.33274, -0.11934, 0.93544, 0)       // 月亮方向向量，通常由脚本控制

        _galaxyTex("银河贴图", 2D) = "white"{}                                              // 银河纹理
        _galaxy_INT("银河默认强度", range(0,1)) = 0.2                                      // 银河基础强度
        _galaxy_intensity("银河强度", range(0,2)) = 1                                      // 银河总强度倍增
    }
 
    SubShader                                                                      // SubShader：真正执行渲染的子着色器
    {
        Tags { "Queue"="Geometry"                                                  // 渲染队列放在 Geometry，说明它不是 Unity 内建 Skybox Shader，而更像绘制在一个天空球/天空盒网格上
               "RenderType" = "Opaque"                                             // 声明它是一个不透明材质类型
               "IgnoreProjector" = "True"                                          // 不受 Projector 影响
               "RenderPipeline" = "UniversalPipeline"                              // 指定仅在 URP 中生效
             }
        LOD 100                                                                    // Shader 复杂度等级，数值越高通常越复杂；这里是基础级别
 
        Pass                                                                       // 一个 Pass 代表一次渲染流程
        {
            Name "Unlit"                                                           // Pass 名称为 Unlit，表示它不走标准光照模型
            HLSLPROGRAM                                                            // 开始 HLSL 程序段
            #pragma prefer_hlslcc gles                                             // 在 GLES 平台优先使用 HLSLcc 编译器，提高兼容性
            #pragma exclude_renderers d3d11_9x                                     // 排除 d3d11_9x 这种低级别特性渲染器
            #pragma vertex vert                                                    // 指定顶点着色器入口函数为 vert
            #pragma fragment frag                                                  // 指定片元着色器入口函数为 frag
            #pragma multi_compile_fog                                              // 编译雾效变体；虽然这里基本没用到，但保留了雾支持
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"      // 引入颜色相关工具函数
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"   // 引入 URP 核心库，包含矩阵、坐标转换等
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"// 引入 URP 光照库，这里主要可能用于主光获取
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/UnityInstancing.hlsl"// 引入实例化支持
       
            #define UNITY_HALF_PI       1.57079632679f                             // 半个 π，用于角度到 [-1,1] 范围的归一化
            #define UNITY_INV_HALF_PI   0.636619772367f                            // 1 / (π/2)，用于把弧度映射到 0~1 或 -1~1
            #define UNITY_PI            3.14159265359f                             // π 常量
            float4x4 LToW;                                                         // 自定义矩阵，通常用于把局部月亮方向转换到世界/天空空间；需要脚本传入
          
            struct appdata                                                         // 顶点输入结构体：从模型顶点流读取数据
            {
                float4 vertex       : POSITION;                                    // 顶点位置，语义 POSITION
                float4 uv           : TEXCOORD0;                                   // UV/自定义方向数据，语义 TEXCOORD0；这里作者把它当 float4 用
            };
 
            struct v2f                                                             // 顶点到片元的插值数据结构
            {
                float4 Varying_StarColorUVAndNoise_UV : TEXCOORD0;                 // xy 用于星点采样 UV，zw 用于星色噪声采样 UV
                float4 Varying_NoiseUV_large          : TEXCOORD1;                 // 两组滚动噪声 UV，用于控制星星存在与闪烁
                float4 Varying_WorldPosAndAngle       : TEXCOORD2;                 // xyz 存归一化世界方向，w 存垂直角度参数
                float4 Varying_IrradianceColor        : TEXCOORD3;                 // 存顶点阶段算好的太阳附加辐照颜色
                float3 Test                           : TEXCOORD4;                 // 调试变量，通常用于观察中间值
                float4 UV                             : TEXCOORD5;                 // 把原始 uv 继续传给片元；这里实际上被当作方向数据来使用
                float4 positionWS                     : TEXCOORD6;                 // 世界空间位置
                float4 positionCS                     : SV_POSITION;               // 裁剪空间位置，供光栅化使用
            };
 
            CBUFFER_START(UnityPerMaterial)                                        // 材质常量缓冲区开始，URP/现代 GPU 推荐把材质参数打包到 CBuffer 中
            float3  _upPartSunColor;                                               // 高空近太阳颜色
            float3  _upPartSkyColor;                                               // 高空远太阳颜色
            float3  _downPartSunColor;                                             // 地平线近太阳颜色
            float3  _downPartSkyColor;                                             // 地平线远太阳颜色
            float _IrradianceMapG_maxAngleRange;                                   // G 通道辐照采样的最大角度范围
            float3 _SunAdditionColor;                                              // 太阳附加色
            float _SunAdditionIntensity;                                           // 太阳附加色强度
            float  _sun_disk_power_999;                                            // 太阳圆盘高次幂指数
            float  _sun_color_intensity;                                           // 太阳颜色强度
            float3 _sun_color;                                                     // 太阳圆盘颜色
            float _SunInnerBoundary;                                               // 太阳圆盘 smoothstep 内边界
            float _SunOuterBoundary;                                               // 太阳圆盘 smoothstep 外边界
            float _SunScattering;                                                  // 太阳散射范围

            float _IrradianceMapR_maxAngleRange;                                   // R 通道辐照采样的最大角度范围
            float _mainColorSunGatherFactor;                                       // 太阳附近主色聚集强度
      
            float _SunRadius;                                                      // 太阳半径参数

            sampler2D _IrradianceMap;                                              // 辐照贴图采样器
            float4 _IrradianceMap_ST;                                              // 辐照贴图 ST 参数（tiling + offset）
            sampler2D _MoonTex;                                                    // 月亮贴图采样器
            float4 _MoonTex_ST;                                                    // 月亮贴图 ST 参数

            float _MoonRadius;                                                     // 月亮显示尺寸
            float _MoonMaskRadius;                                                 // 月亮遮罩尺寸

            float3 _SunDirection;                                                  // 太阳方向
            float3 _MoonDirection;                                                 // 月亮方向
            float  _mainColorMoonGatherFactor;                                     // 月亮附近颜色聚集因子
            float3 _MoonScatteringColor;                                           // 月亮散射颜色
            float3  _Moon_color;                                                   // 月亮着色颜色
            float _Moon_color_intensity;                                           // 月亮亮度强度
            float3 _sun_color_Scat;                                                // 太阳散射颜色

            float _starColorIntensity;                                             // 星星颜色强度
            float _starIntensityLinearDamping;                                     // 星星遮蔽/阈值控制

            sampler2D _StarDotMap;                                                 // 星点贴图采样器
            float4 _StarDotMap_ST;                                                 // 星点贴图 ST 参数

            float _NoiseSpeed;                                                     // 噪声滚动速度

            sampler2D _NoiseMap;                                                   // 噪声图采样器
            float4 _NoiseMap_ST;                                                   // 噪声图 ST 参数

            sampler2D _StarColorLut;                                               // 星星颜色 LUT 采样器；注意这里和 Properties 名称不一致，可能导致材质面板贴图不绑定
            float4 _StarColorLut_ST;                                               // 星星颜色 LUT 的 ST 参数

            sampler2D _galaxyTex;                                                  // 银河贴图采样器
            float4 _galaxyTex_ST;                                                  // 银河贴图 ST 参数
            float _galaxy_INT;                                                     // 银河基础强度
            float  _galaxy_intensity;                                              // 银河总强度倍增
            CBUFFER_END                                                            // 材质常量缓冲区结束

            float FastAcosForAbsCos(float in_abs_cos)                              // 对 |cos| 做快速 acos 近似，减少反三角函数开销
            {
                float _local_tmp = ((in_abs_cos * -0.0187292993068695068359375 + 0.074261002242565155029296875) * in_abs_cos - 0.212114393711090087890625) * in_abs_cos + 1.570728778839111328125; // 这是一个多项式近似，用来逼近 acos 曲线
                return _local_tmp * sqrt(1.0 - in_abs_cos);                        // 再乘 sqrt(1-x) 修正曲线形状，得到近似 acos 值
            }

            float FastAcos(float in_cos)                                           // 对完整 [-1,1] 的 cos 值做快速 acos
            {
                float local_abs_cos = abs(in_cos);                                 // 先取绝对值，复用上面的绝对值版本近似
                float local_abs_acos = FastAcosForAbsCos(local_abs_cos);           // 计算 |cos| 对应的 acos 近似值
                return in_cos < 0.0 ?  UNITY_PI - local_abs_acos : local_abs_acos; // 根据 acos(-x)=π-acos(x) 还原负半轴结果
            }

            v2f vert(appdata v)                                                    // 顶点着色器：把顶点数据转换为片元阶段需要的插值数据
            {
                v2f o = (v2f)0;                                                    // 把输出结构体全部初始化为 0，避免脏数据
                VertexPositionInputs vertexInput = GetVertexPositionInputs(v.vertex);// 通过 URP 工具函数获取世界空间、裁剪空间等位置数据
                o.positionWS.xyz = vertexInput.positionWS;                         // 保存世界空间坐标到插值结构
                float3 _worldPos = mul(UNITY_MATRIX_M, float4(v.vertex.xyz, 1.0)).xyz; // 用模型矩阵把本地顶点坐标转成世界坐标
                float3 NormalizeWorldPos = normalize(_worldPos);                   // 归一化世界坐标，得到从原点指向天空球表面的方向向量
         
                float4 _clippos  = mul(UNITY_MATRIX_VP, float4(_worldPos, 1.0));  // 再乘 VP 矩阵得到裁剪空间坐标，用于最终屏幕投影

                o.positionCS= _clippos;                                            // 输出裁剪空间位置
                o.UV = v.uv;                                                       // 原样把输入 uv 传给片元；此 Shader 后续把它当作方向/坐标使用

                o.Varying_StarColorUVAndNoise_UV.xy = TRANSFORM_TEX(v.uv.xz , _StarDotMap); // 用 uv 的 xz 分量生成星点贴图采样坐标，并应用 ST
                o.Varying_StarColorUVAndNoise_UV.zw = v.uv * 20.0;                 // 生成星色噪声采样坐标；这里把 float4 赋给 zw，写法较松散，实际意图是放大 UV 频率

                float4 _timeScaleValue = _Time.y * _NoiseSpeed * float4(0.4, 0.2, 0.1, 0.5); // 用时间和速度生成四个不同滚动速度，给两组噪声制造差异化动画
                
                o.Varying_NoiseUV_large.xy = (v.uv.xz * _NoiseMap_ST.xy) + _timeScaleValue.xy;      // 第一组噪声 UV：基础缩放 + 时间偏移
                o.Varying_NoiseUV_large.zw = (v.uv.xz * _NoiseMap_ST.xy * 2.0) + _timeScaleValue.zw; // 第二组噪声 UV：频率翻倍 + 不同时间偏移，形成更丰富的星空变化

                //  Light mainLight = GetMainLight();                               // 原本可能想取主光，但这里被注释掉了，说明太阳方向最终使用的是手动传入的 _SunDirection
                //float3 _viewDir = normalize(_worldPos.xyz );/*_WorldSpaceCameraPos*/ // 这里也注释掉了，说明作者没有使用视线方向，而是直接用天空球方向
                float3 SunDirection = dot(normalize(vertexInput.positionWS),_SunDirection.xyz); // 计算当前天空方向与太阳方向的点积，值越大说明越接近太阳
                // float _WPDotSun = dot(SunDirection, _worldPos.xyz);               // 注释掉的旧代码，可能原本想再计算别的太阳相关项
                float SunDirectionRemapClamp =clamp((SunDirection * 0.5) + 0.5,0,1.0); // 把点积结果从 [-1,1] 映射到 [0,1]，方便后续 smoothstep/lerp 使用
                float _miu = clamp( dot(float3(0,1,0), NormalizeWorldPos), -1, 1 );    // 计算当前天空方向与世界上方向(0,1,0)的点积，即“有多朝上”
                float _angle_up_to_down_1_n1 = (UNITY_HALF_PI - FastAcos(_miu)) * UNITY_INV_HALF_PI; // 把顶点方向对应的仰角转换到 [-1,1]，上方为正，下方为负
             
                o.Varying_WorldPosAndAngle.xyz = NormalizeWorldPos;                // 存入归一化世界方向，片元阶段继续使用
                o.Varying_WorldPosAndAngle.w   = _angle_up_to_down_1_n1;           // 存入“从天顶到地平线再到底部”的角度参数

                float2 _irradianceMap_G_uv;                                        // 声明用于采样辐照贴图 G 通道的 UV
                _irradianceMap_G_uv.x = abs(_angle_up_to_down_1_n1) / max(_IrradianceMapG_maxAngleRange, 0.001f); // 按垂直角度决定采样位置，越靠近特定范围变化越明显
                _irradianceMap_G_uv.y = 0.5;                                       // y 固定为 0.5，表示在一条水平线上采样 1D 梯度图
                float _irradianceMapG = tex2Dlod(_IrradianceMap, float4( _irradianceMap_G_uv, 0.0, 0.0 )).y; // 在顶点阶段用 lod 采样辐照贴图的 G 通道

                float3 _sunAdditionPartColor = _irradianceMapG * _SunAdditionColor * _SunAdditionIntensity; // 用辐照值调制太阳附加色，形成太阳周边额外颜色层

                float _upFactor = smoothstep(0, 1, clamp((abs(_SunDirection.y) - 0.2) * 10/3, 0, 1)); // 根据太阳高度估算“太阳是否较高挂天上”，越高 upFactor 越接近 1
                float _VDotSunFactor = smoothstep(0, 1, (SunDirectionRemapClamp -1)/0.7 + 1);         // 根据当前方向靠近太阳的程度得到一个平滑权重
                float _sunAdditionPartFactor = lerp(_VDotSunFactor, 1.0, _upFactor);                  // 当太阳高挂时更偏向整体增强，否则更偏向太阳方向局部聚集
                float3 _additionPart = _sunAdditionPartColor * _sunAdditionPartFactor;                // 计算太阳附加颜色层最终结果
                float3 _sumIrradianceRGColor =  _additionPart;                                         // 当前只把附加色放进去，变量名保留了“RG”可能是为了以后扩展

                o.Varying_IrradianceColor.xyz = _sumIrradianceRGColor;                // 把顶点阶段算好的辐照附加色传给片元
                o.Test.xyz = float3(_irradianceMap_G_uv.x,_irradianceMap_G_uv.x,_irradianceMap_G_uv.x); // 调试输出，记录当前 G 采样 x 值

                return o;                                                            // 返回顶点着色器输出
            }
 
            half4 frag(v2f i) : SV_Target                                           // 片元着色器：对每个像素计算最终天空颜色
            {
                float sunDist = distance(i.UV.xyz, _SunDirection.xyz);              // 计算当前方向与太阳方向的距离，距离越小说明越靠近太阳圆盘中心
                float MoonDist = distance(i.UV.xyz,_MoonDirection);                 // 计算当前方向与月亮方向的距离，距离越小说明越靠近月亮
                float sunArea = 1 - (sunDist * _SunRadius);                         // 太阳区域遮罩，距离越小值越大，相当于圆形衰减
                float moonArea = 1 - clamp((MoonDist * _MoonMaskRadius),0,1);       // 月亮区域遮罩，超出月亮半径后逐渐衰减到 0
                // float moonGalaxyMask = 1 - clamp((MoonDist * 10),0,1);           // 这是旧版月亮-银河遮罩，已注释

                float moonGalaxyMask = step(0.084,MoonDist);                        // 当像素离月亮足够远时返回 1，靠近月亮时返回 0，用于遮住月亮附近星星/银河

                float sunArea2 = 1- (sunDist*_SunScattering);                       // 太阳散射范围遮罩，范围一般比太阳圆盘更大
                float moonArea2 = 1 - (MoonDist*0.5);                               // 月亮散射范围的基础遮罩
                moonArea2 = smoothstep(0.5,1,moonArea2);                            // 把月亮散射遮罩柔化，避免硬边
                float sunArea3 = 1- (sunDist*0.4);                                  // 更大范围的太阳区域，用于做太阳盘高光和过渡
                sunArea3 = smoothstep(0.05,1.21,sunArea3);                          // 对太阳区域再次柔化，让圆盘边缘更平滑
               
                sunArea = smoothstep(_SunInnerBoundary,_SunOuterBoundary,sunArea);  // 用 smoothstep 控制太阳圆盘内外边界，使太阳边缘可调

                float3 MoonUV = mul(i.UV.xyz,LToW);                                 // 把当前方向乘上自定义矩阵，得到月亮贴图映射方向；这里写法依赖外部矩阵和数据组织
                float2 moonUV = MoonUV.xy * _MoonTex_ST.xy*_MoonRadius + _MoonTex_ST.zw; // 将月亮方向映射到 2D UV，并应用 ST 与半径缩放
               
                float  _WorldPosDotUp = dot(i.Varying_WorldPosAndAngle.xyz, float3(0,1,0)); // 当前天空方向与世界上方向的点积，越接近 1 越靠近天顶
                float  _WorldPosDotUpstep = smoothstep(0,0.1,_WorldPosDotUp);       // 在地平线上方向上做一个平滑开启，让太阳/月亮主要出现在上半球

                float _WorldPosDotUpstep1  = 1-abs(_WorldPosDotUp );                // 越接近地平线，这个值越大；用于做地平线散射增强
                _WorldPosDotUpstep1 = smoothstep(0.4,1,_WorldPosDotUpstep1 );       // 把地平线附近区域提取出来并平滑过渡
            
                float _WorldPosDotUpstep2 = clamp(0,1,smoothstep(0,0.01,_WorldPosDotUp)+ smoothstep(0.5,1,_WorldPosDotUpstep1)) ; // 这里意图是把两个地平线/天空权重相加后钳制到 [0,1]；但 clamp 参数顺序按 HLSL 应该是 clamp(x,0,1)，原代码疑似写反
       
                float  _WorldPosDotUp_Multi999 = _sun_disk_power_999;                // 把太阳盘指数存到局部变量，便于后续控制太阳中心锐度
       
                float4 moonTex = tex2D(_MoonTex, moonUV)*moonArea*_WorldPosDotUpstep; // 采样月亮贴图，并乘月亮遮罩和上半球遮罩，避免月亮出现在地面以下

                // float3 galaxyUV = mul(i.UV.xyz,galaxyLToW);                        // 被注释的银河方向变换，说明原本可能也想给银河做旋转矩阵
                float4 galaxyTex = tex2D(_galaxyTex,i.UV.xz * _galaxyTex_ST.xy + _galaxyTex_ST.zw); // 用当前方向的 xz 分量采样银河贴图，相当于平面投影

                sunArea = sunArea *  _WorldPosDotUpstep;                             // 太阳圆盘只在上半球显示

                float3 _sun_disk = dot(min(1, pow(sunArea3 , _WorldPosDotUp_Multi999 * float3(1, 0.1, 0.01))),float3(1, 0.16, 0.03))* _sun_color_intensity * _sun_color; // 用不同指数构造多层高光分布，再点乘混合成一个强烈的太阳盘核心
                float3 _sun_disk_sunArea = sunArea * _sun_color_intensity * _sun_color ; // 计算太阳基本圆盘颜色
                _sun_disk = _sun_disk + _sun_disk_sunArea * 3;                       // 把核心高亮和基础圆盘叠加，增强太阳视觉存在感
         
                float _LDotDirClampn11_smooth = smoothstep(0, 1, sunArea3);          // 对太阳大范围区域再做平滑权重，用于控制太阳整体混合

                float2 _irradianceMap_R_uv;                                           // 声明辐照贴图 R 通道采样坐标
                _irradianceMap_R_uv.x = abs(i.Varying_WorldPosAndAngle.w) / max(_IrradianceMapR_maxAngleRange,0.001f); // 通过垂直角度决定主天空渐变采样位置
                _irradianceMap_R_uv.y = 0.5;                                          // 固定在贴图中线采样，相当于把贴图当 1D 曲线用

                float _irradianceMapR = tex2Dlod(_IrradianceMap, float4(_irradianceMap_R_uv, 0.0, 0.0)).x; // 采样辐照贴图 R 通道，作为“天顶到地平线”主渐变权重

                float _VDotSunDampingA = max(0, lerp( 1, sunArea2 , _mainColorSunGatherFactor )); // 控制天空主色向太阳附近聚集的强度
                float _VDotSunDampingA_pow3 = _VDotSunDampingA * _VDotSunDampingA * _VDotSunDampingA; // 三次方增强对比，让靠近太阳的颜色变化更集中
              
                float3 _upPartColor   = lerp(_upPartSkyColor, _upPartSunColor, _VDotSunDampingA_pow3);   // 高空区域：从远太阳色过渡到近太阳色
                float3 _downPartColor = lerp(_downPartSkyColor, _downPartSunColor, _VDotSunDampingA_pow3); // 地平线区域：从远太阳色过渡到近太阳色
                float3 _mainColor = lerp(_upPartColor, _downPartColor, _irradianceMapR);                  // 再根据垂直角度把高空颜色和地平线颜色混合成整片天空主色

                float _VDotMoonDampingA = max(0, lerp( 1, moonArea2 , _mainColorMoonGatherFactor ));     // 控制月亮附近的颜色聚集程度
                float _VDotMoonDampingA_pow3 = _VDotMoonDampingA *_VDotMoonDampingA;                      // 做平方增强，突出月亮周边颜色变化

                float SSS = clamp( _VDotSunDampingA_pow3*_VDotSunDampingA *_VDotSunDampingA  * _WorldPosDotUpstep1 ,0,1); // 计算地平线附近的太阳散射强度，太阳越强且越靠近地平线，散射越明显
            
                SSS = smoothstep(0.02,0.5, SSS );                                  // 把散射结果平滑化，避免过于生硬
                SSS = SSS *  _WorldPosDotUpstep2;                                   // 再乘地平线区域遮罩，只保留合理散射区域
      
                float3 SSSS =  SSS *_sun_color_Scat;                                // 得到最终散射颜色（SSSS 只是作者的变量名）
                  
                float3 FmoonColor =  (moonTex.xyz*_Moon_color*_Moon_color_intensity) + _VDotMoonDampingA_pow3*_MoonScatteringColor; // 月亮结果 = 月亮贴图颜色 + 月亮周边散射颜色

                float3 _day_part_color = (_sun_disk * _LDotDirClampn11_smooth ) + i.Varying_IrradianceColor.xyz + _mainColor+ FmoonColor; // 白天主体部分：太阳盘 + 太阳附加色 + 天空主色 + 月亮颜色

                float _starExistNoise1 = tex2D(_NoiseMap, i.Varying_NoiseUV_large.xy).r; // 第一层噪声，决定星星是否存在/闪烁
                float _starExistNoise2 = tex2D(_NoiseMap, i.Varying_NoiseUV_large.zw).r; // 第二层噪声，与第一层相乘增强随机性
                float _starSample = tex2D(_StarDotMap, i.UV.xz*_StarDotMap_ST.xy+_StarDotMap_ST.zw  ).r; // 采样星点分布图，决定哪些位置可以生成星星
                float _star = _starSample * _starExistNoise2 * _starExistNoise1;    // 星星基础强度 = 星点分布 × 两层噪声
                float _miuResult = i.Varying_WorldPosAndAngle.w * 1.5;              // 根据垂直角度增强上半球星星显示，通常越高越容易显示星空
                _miuResult = clamp(_miuResult, 0.0, 1.0);                            // 把星空可见度钳制到 0~1
                float _star_intensity = _star * _miuResult;                          // 星星强度乘上垂直可见度
                _star_intensity *= 3.0;                                              // 整体把星星亮度再抬高一些
                
                float _starColorNoise = tex2D(_NoiseMap, i.Varying_StarColorUVAndNoise_UV.zw).r; // 再采样一份噪声，用于控制星星亮度和颜色选取
                float _starIntensityDamping = (_starColorNoise - _starIntensityLinearDamping) / (1.0 -_starIntensityLinearDamping); // 根据阈值把较弱噪声压掉，只保留足够“亮”的星点
                _starIntensityDamping = clamp(_starIntensityDamping, 0.0, 1.0);     // 把衰减结果限制在 0~1
                _star_intensity = _starIntensityDamping * _star_intensity;           // 应用阈值衰减，让星空更稀疏自然
                
                float2 _starColorLutUV;                                              // 声明星星颜色 LUT 的采样坐标
                _starColorLutUV.x = (_starColorNoise * _StarColorLut_ST.x) + _StarColorLut_ST.z; // 用噪声值映射到 LUT 横坐标，不同噪声值对应不同星体颜色
                _starColorLutUV.y = 0.5;                                             // y 固定 0.5，等价于在中线读取 1D 颜色表
                float3 _starColorLut = tex2D(_StarColorLut, _starColorLutUV).xyz;   // 读取星星颜色 LUT
                float3 _starColor = _starColorLut * _starColorIntensity;             // 乘颜色强度，得到最终星星颜色

                float3 _finalStarColor = _star_intensity * _starColor*moonGalaxyMask; // 星星最终颜色；月亮附近通过 moonGalaxyMask 被压掉，避免和月亮重叠

                galaxyTex.w = pow(galaxyTex.w,10);                                   // 强化银河 alpha/亮度分布，让亮区域更突出、暗区域更快衰减
                float3 galaxyColor =clamp((galaxyTex.xyz*galaxyTex.w*_WorldPosDotUp *_galaxy_INT*moonGalaxyMask*_galaxy_intensity),0,1); // 银河颜色 = 纹理颜色 × alpha × 上半球遮罩 × 强度 × 月亮遮罩

                return float4(SSSS+_day_part_color+_finalStarColor+galaxyColor,1);   // 输出最终天空颜色：太阳散射 + 白天天空 + 星星 + 银河
                //return float4(moonGalaxyMask ,moonGalaxyMask ,moonGalaxyMask ,1);   // 调试输出：单独查看月亮附近遮罩
            }
            ENDHLSL                                                                   // HLSL 代码结束
        }
    }
}