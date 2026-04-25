// 定义 Shader 名称
// 在 Unity Shader 菜单中会显示为 CasualAtmosphere/TransmittanceLut
Shader "CasualAtmosphere/TransmittanceLut"
{
    // Properties 是 Unity 材质 Inspector 面板中暴露参数的区域
    // 当前为空，说明该 Shader 的参数主要由 C# 脚本或全局 Shader 变量传入
    Properties
    {

    }

    // SubShader 是 Shader 的实际渲染实现部分
    SubShader
    {
        // Cull Off：关闭背面剔除
        // 生成 LUT 通常使用全屏三角形或全屏四边形，不需要区分正面和背面
        Cull Off

        // ZWrite Off：关闭深度写入
        // LUT 生成不需要写入深度缓冲，否则会污染场景深度
        ZWrite Off

        // ZTest Always：深度测试永远通过
        // 该 Pass 是写入整张 RenderTexture，不应该被场景深度影响
        ZTest Always

        // 定义一个渲染 Pass
        // 该 Pass 会把每个像素对应的透射率结果写入 Transmittance LUT
        Pass
        {
            // 开始 HLSL 代码块
            HLSLPROGRAM

            // 指定顶点着色器入口函数为 vert
            #pragma vertex vert

            // 指定片元着色器入口函数为 frag
            #pragma fragment frag

            // 引入 URP 核心库
            // 提供 TransformObjectToHClip、矩阵、平台宏等基础功能
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // 引入 URP 光照库
            // 当前文件没有直接使用主光源，但为了和其他大气 Shader 保持 include 结构一致
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // 引入自定义辅助函数
            // 当前文件会用到 UvToTransmittanceLutParams() 和 RayIntersectSphere()
            #include "Helper.hlsl"

            // 引入自定义散射函数
            // 当前文件通过 Transmittance() 间接使用 RayleighCoefficient、MieCoefficient、OzoneAbsorption 等函数
            #include "Scattering.hlsl"

            // 引入大气参数封装文件
            // 提供 GetAtmosphereParameter()，用于获取星球半径、大气高度、散射参数等
            #include "AtmosphereParameter.hlsl"

            // 引入光线步进积分函数
            // 当前文件会使用 Transmittance() 来积分计算透射率
            #include "Raymarching.hlsl"

            // 顶点输入结构体
            struct appdata
            {
                // 模型空间顶点坐标
                // 对 LUT 生成 Pass 来说，通常来自全屏三角形或全屏四边形
                float4 vertex : POSITION;

                // 第一套 UV 坐标
                // 当前 UV 表示 Transmittance LUT 中的二维坐标
                float2 uv : TEXCOORD0;
            };

            // 顶点输出结构体，同时也是片元输入结构体
            struct v2f
            {
                // 传递给片元着色器的 UV 坐标
                // 每个 uv 对应一组物理参数：高度 r 和方向角 cos_theta
                float2 uv : TEXCOORD0;

                // 裁剪空间顶点坐标
                // SV_POSITION 是 GPU 光栅化阶段必须使用的位置语义
                float4 vertex : SV_POSITION;
            };

            // 顶点着色器
            // 负责把全屏网格顶点转换到裁剪空间，并把 UV 传递给片元着色器
            v2f vert (appdata v)
            {
                // 声明顶点输出结构体
                v2f o;

                // 将模型空间顶点转换到齐次裁剪空间
                // TransformObjectToHClip 是 URP 封装函数，本质是执行 MVP 矩阵变换
                o.vertex = TransformObjectToHClip(v.vertex);

                // 将输入 UV 原样传递到片元阶段
                // 后续片元阶段会根据 uv 计算当前 LUT 像素对应的大气物理参数
                o.uv = v.uv;

                // 返回顶点着色器输出
                return o;
            }

            // 片元着色器
            // 每个像素负责计算 Transmittance LUT 中一个 texel 的透射率
            float4 frag (v2f i) : SV_Target
            {
                // 获取当前大气参数
                // param 中包含星球半径、大气高度、Rayleigh 参数、Mie 参数、Ozone 参数等
                AtmosphereParameter param = GetAtmosphereParameter();

                // 初始化输出颜色
                // RGB 后面会存储透射率
                // A 设置为 1，当前没有特殊物理意义，主要作为占位
                float4 color = float4(0, 0, 0, 1);

                // 取得当前 LUT 像素的二维坐标
                // uv.x 通常对应方向 / 光线路径参数
                // uv.y 通常对应高度参数
                float2 uv = i.uv;

                // 大气底部半径
                // 即星球半径，通常表示地表或海平面所在球面
                float bottomRadius = param.PlanetRadius;

                // 大气顶部半径
                // 等于星球半径 + 大气层高度
                float topRadius = param.PlanetRadius + param.AtmosphereHeight;

                // 计算当前 uv 对应的 cos_theta 和 r
                // cos_theta 表示视线方向和局部竖直向上方向之间夹角的余弦
                // r 表示当前采样点到星球中心的距离
                float cos_theta = 0.0;

                // 初始化当前点到星球中心的半径距离
                // 后续会由 UvToTransmittanceLutParams() 输出真实值
                float r = 0.0;

                // 将 Transmittance LUT 的 uv 坐标转换为物理参数 cos_theta 和 r
                //
                // 技术原理：
                // Transmittance LUT 通常不是简单线性存储高度和角度。
                // 为了在地平线附近、低空区域获得更好的采样精度，
                // 这里使用 Helper.hlsl 中的非线性几何映射。
                //
                // 输入：
                // bottomRadius = 星球半径
                // topRadius    = 大气顶部半径
                // uv           = 当前 LUT 坐标
                //
                // 输出：
                // cos_theta = 当前射线方向与局部上方向夹角余弦
                // r         = 当前采样点到星球中心的距离
                UvToTransmittanceLutParams(bottomRadius, topRadius, uv, cos_theta, r);

                // 根据 cos_theta 计算 sin_theta
                // 因为 sin²θ + cos²θ = 1
                //
                // cos_theta 表示方向在局部竖直方向，也就是 y 轴方向的分量
                // sin_theta 表示方向在水平面上的分量
                float sin_theta = sqrt(saturate(1.0 - cos_theta * cos_theta));

                // 构造当前 LUT 对应的射线方向
                //
                // 这里将方向限制在 x-y 平面内：
                // x = sin_theta
                // y = cos_theta
                // z = 0
                //
                // 技术原理：
                // 球形大气具有旋转对称性。
                // 对于透射率来说，只需要知道高度 r 和方向夹角 cos_theta，
                // 不需要关心具体方位角，所以可以固定在 x-y 平面计算。
                float3 viewDir = float3(sin_theta, cos_theta, 0);

                // 构造当前采样点位置
                //
                // eyePos = float3(0, r, 0)
                // 表示把采样点放在星球中心正上方的 y 轴上。
                //
                // 因为球形大气具有旋转对称性，
                // 任意同高度的点都可以旋转到这个位置。
                float3 eyePos = float3(0, r, 0);

                // 光线和大气层求交
                //
                // 从 eyePos 出发，沿 viewDir 方向，
                // 与大气外边界球体求交。
                //
                // 返回值 dis 是从 eyePos 到大气层外边界的距离。
                float dis = RayIntersectSphere(float3(0,0,0), param.PlanetRadius + param.AtmosphereHeight, eyePos, viewDir);

                // 根据交点距离计算大气层边界命中点
                //
                // hitPoint 表示这条光线从当前点出发，沿 viewDir 走到大气外边界的位置。
                float3 hitPoint = eyePos + viewDir * dis;

                // raymarch 计算 transmittance
                //
                // Transmittance(param, eyePos, hitPoint) 会从 eyePos 到 hitPoint 做积分：
                //
                // opticalDepth = ∫ extinction ds
                // transmittance = exp(-opticalDepth)
                //
                // extinction = RayleighScattering + MieScattering + OzoneAbsorption + MieAbsorption
                //
                // 最终 RGB 表示不同波长通道的透射率。
                color.rgb = Transmittance(param, eyePos, hitPoint);

                // 返回当前 LUT 像素颜色
                // RGB = 透射率
                // A = 1
                return color;
            }

            // 结束 HLSL 代码块
            ENDHLSL
        }
    }
}
