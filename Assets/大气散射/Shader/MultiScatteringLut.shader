// 定义 Shader 名称
// 在 Unity 的 Shader 菜单中会显示为 CasualAtmosphere/MultiScatteringLut
Shader "CasualAtmosphere/MultiScatteringLut"
{
    // Properties 用于暴露材质参数到 Unity Inspector 面板
    // 这里为空，说明该 Shader 的主要参数不是通过材质面板配置，
    // 而是由 C# 脚本通过 SetFloat、SetVector、SetTexture 等方式传入
    Properties
    {

    }

    // SubShader 是 Shader 的实际渲染实现部分
    SubShader
    {
        // Cull Off：关闭背面剔除
        // 生成 LUT 通常使用全屏三角形或全屏四边形，不需要剔除正反面
        Cull Off

        // ZWrite Off：关闭深度写入
        // LUT 生成不需要写入深度缓冲，避免污染场景深度
        ZWrite Off

        // ZTest Always：深度测试永远通过
        // LUT 生成通常是写入整张 RenderTexture，不应该受已有深度影响
        ZTest Always

        // 定义一个渲染 Pass
        // 该 Pass 会把每个像素计算出的多重散射结果写入 MultiScattering LUT
        Pass
        {
            // 开始 HLSL 代码块
            HLSLPROGRAM

            // 指定顶点着色器入口函数为 vert
            #pragma vertex vert

            // 指定片元着色器入口函数为 frag
            #pragma fragment frag

            // 引入 URP 核心库
            // 提供 TransformObjectToHClip、矩阵变换、平台兼容宏等基础功能
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // 引入 URP 光照库
            // 当前文件没有直接调用 GetMainLight，但大气散射系统中通常会统一包含该库
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // 引入自定义辅助函数
            // 通常包含 PI、球面方向转换、射线与球求交、Transmittance LUT 坐标映射等工具函数
            #include "Helper.hlsl"

            // 引入自定义散射函数
            // 通常定义 AtmosphereParameter 结构体，以及 Rayleigh、Mie、Ozone 等散射和吸收函数
            #include "Scattering.hlsl"

            // 引入自定义大气参数封装文件
            // 提供 GetAtmosphereParameter()，用于把 Unity 传入的全局参数打包成 AtmosphereParameter
            #include "AtmosphereParameter.hlsl"

            // 引入自定义 Raymarching 文件
            // 当前文件主要使用其中的 IntegralMultiScattering() 函数计算多重散射近似
            #include "Raymarching.hlsl"

            // 定义顶点输入结构体
            struct appdata
            {
                // 模型空间顶点位置
                // POSITION 语义表示该变量来自网格顶点坐标
                float4 vertex : POSITION;

                // 第一套 UV 坐标
                // 对于全屏 Pass 来说，uv 通常就是当前 RenderTexture 的归一化坐标
                float2 uv : TEXCOORD0;
            };

            // 定义顶点着色器输出，同时也是片元着色器输入
            struct v2f
            {
                // 传递给片元着色器的 UV 坐标
                // 用于决定当前像素对应 LUT 中的哪个物理参数
                float2 uv : TEXCOORD0;

                // 裁剪空间顶点位置
                // SV_POSITION 是 GPU 光栅化阶段必须使用的位置语义
                float4 vertex : SV_POSITION;
            };

            // 顶点着色器
            // 作用是把全屏网格顶点转换到裁剪空间，并把 UV 传递给片元着色器
            v2f vert (appdata v)
            {
                // 声明输出结构体
                v2f o;

                // 将模型空间顶点变换到齐次裁剪空间
                // TransformObjectToHClip 是 URP 提供的封装函数，本质是执行 MVP 矩阵变换
                o.vertex = TransformObjectToHClip(v.vertex);

                // 把输入 UV 原样传递给片元阶段
                // LUT 生成时，每个 UV 对应一组大气物理参数
                o.uv = v.uv;

                // 返回顶点着色器输出
                return o;
            }

            // 声明一个线性过滤 + Clamp 寻址的采样器
            // 线性过滤可以让 LUT 查询结果更加平滑
            // Clamp 寻址可以避免 UV 越界时发生 Repeat 环绕采样
            SAMPLER(sampler_multiscatteringLutLinearClamp);

            // 声明 Transmittance LUT 纹理
            // 多重散射计算需要知道太阳光从大气外部传播到某个点时的衰减
            // 因此需要查询透射率 LUT
            Texture2D _transmittanceLut;

            // 片元着色器
            // 每个像素负责计算 MultiScattering LUT 中一个 texel 的结果
            float4 frag (v2f i) : SV_Target
            {
                // 获取当前大气参数
                // param 中通常包含星球半径、大气高度、Rayleigh 参数、Mie 参数、臭氧吸收参数等
                AtmosphereParameter param = GetAtmosphereParameter();

                // 初始化输出颜色
                // RGB 后续会存储多重散射结果
                // A 初始化为 1，表示不透明或占位
                float4 color = float4(0, 0, 0, 1);

                // 取得当前片元的 LUT 坐标
                // uv.x 通常表示太阳天顶角相关参数
                // uv.y 通常表示高度相关参数
                float2 uv = i.uv;

                // 将 uv.x 从 [0, 1] 映射到 [-1, 1]
                // mu_s 表示太阳方向和当前位置局部竖直向上方向之间夹角的余弦
                //
                // mu_s =  1：太阳在正上方
                // mu_s =  0：太阳在地平线方向
                // mu_s = -1：太阳在地平线以下或从下方照射
                float mu_s = uv.x * 2.0 - 1.0;

                // 根据 uv.y 计算当前采样点到星球中心的距离 r
                //
                // uv.y = 0 时：
                // r = param.PlanetRadius，表示地表或海平面附近
                //
                // uv.y = 1 时：
                // r = param.PlanetRadius + param.AtmosphereHeight，表示大气层顶部
                //
                // 所以 uv.y 被用来表示大气层内的高度维度
                float r = uv.y * param.AtmosphereHeight + param.PlanetRadius;

                // 将 mu_s 作为 cos(theta)
                // theta 是太阳方向与局部竖直方向之间的夹角
                float cos_theta = mu_s;

                // 根据 sin^2(theta) + cos^2(theta) = 1 计算 sin(theta)
                // 这里用于构造一个位于 x-y 平面内的太阳方向向量
                float sin_theta = sqrt(saturate(1.0 - cos_theta * cos_theta));

                // 构造太阳光方向 lightDir
                //
                // 当前采样点被放在 y 轴上，所以局部竖直方向可以认为是 +Y。
                // lightDir.y = cos_theta = mu_s，表示太阳方向在竖直方向上的分量。
                // lightDir.x = sin_theta，表示太阳方向在水平方向上的分量。
                // lightDir.z = 0，说明这里利用球形大气的旋转对称性，只在 x-y 平面中计算即可。
                //
                // 技术原理：
                // 对球形大气而言，只要知道高度 r 和太阳天顶角 mu_s，
                // 不需要知道太阳绕 y 轴旋转的方位角。
                float3 lightDir = float3(sin_theta, cos_theta, 0);

                // 构造当前采样点在大气模型中的位置
                //
                // p = float3(0, r, 0) 表示把当前点放在星球中心正上方的 y 轴上。
                // 由于大气是球对称的，任意同高度位置都可以旋转到这个位置。
                float3 p = float3(0, r, 0);

                // 计算当前高度 p、太阳方向 lightDir 下的多重散射贡献
                //
                // IntegralMultiScattering 通常会做以下事情：
                // 1. 在当前点周围对多个方向进行采样
                // 2. 对这些方向上的单次散射贡献进行积分
                // 3. 查询 _transmittanceLut 计算光线在大气中的衰减
                // 4. 近似估计二次及更高阶散射的能量
                //
                // 结果写入 color.rgb，作为 MultiScattering LUT 的 RGB 内容
                //
                // 注意：
                // 这里传入的是 sampler_LinearClamp，而不是上面声明的 sampler_multiscatteringLutLinearClamp。
                // 如果 sampler_LinearClamp 在其他 include 文件里已经声明，则可以正常编译。
                // 如果没有声明，这里会报错。
                color.rgb = IntegralMultiScattering(param, p, lightDir, _transmittanceLut, sampler_LinearClamp);

                // 调试代码：
                // 如果取消注释，会把当前 LUT 的 uv 坐标直接显示到 RG 通道
                // 可用于检查 LUT 写入和坐标分布是否正确
                // color.rg = uv;

                // 返回当前 LUT 像素的结果
                // RGB = 多重散射结果
                // A   = 1
                return color;
            }

            // 结束 HLSL 代码块
            ENDHLSL
        }
    }
}
