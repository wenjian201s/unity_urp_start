// 定义 Shader 名称
// 在 Unity Shader 菜单中会显示为 CasualAtmosphere/SkyViewLut
Shader "CasualAtmosphere/SkyViewLut"
{
    // Properties 用于在 Unity 材质 Inspector 面板中暴露参数
    // 这里为空，说明该 Shader 的参数主要由 C# 脚本通过 SetTexture、SetFloat、SetVector 等方式传入
    Properties
    {

    }

    // SubShader 是 Shader 的实际渲染实现部分
    SubShader
    {
        // Cull Off：关闭背面剔除
        // 生成 LUT 一般使用全屏三角形或全屏四边形，不需要区分正反面
        Cull Off

        // ZWrite Off：关闭深度写入
        // LUT 生成不需要写入深度缓冲，避免影响场景深度
        ZWrite Off

        // ZTest Always：深度测试永远通过
        // 该 Pass 是写入整张 SkyView RenderTexture，不应该被场景深度裁剪
        ZTest Always

        // 定义一个渲染 Pass
        // 该 Pass 会把每个像素对应方向的大气散射结果写入 _skyViewLut
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
            // 当前代码会使用 GetMainLight() 获取主光源，也就是太阳方向
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // 引入自定义辅助函数
            // 这里会使用 UVToViewDir() 把 LUT 的二维 uv 转换成三维天空方向
            #include "Helper.hlsl"

            // 引入自定义散射函数
            // 提供 AtmosphereParameter 结构体，以及 Rayleigh / Mie / Ozone 等散射吸收函数
            #include "Scattering.hlsl"

            // 引入大气参数封装文件
            // 提供 GetAtmosphereParameter()，用于把 Unity 全局参数打包成 AtmosphereParameter
            #include "AtmosphereParameter.hlsl"

            // 引入光线步进积分函数
            // 这里主要使用 GetSkyView() 计算某个方向上的天空颜色
            #include "Raymarching.hlsl"

            // 顶点输入结构体
            struct appdata
            {
                // 模型空间顶点位置
                // 对 LUT 生成 Pass 来说，一般来自全屏三角形或全屏四边形
                float4 vertex : POSITION;

                // 第一套 UV 坐标
                // 用来表示当前片元在 SkyView LUT 中的二维坐标
                float2 uv : TEXCOORD0;
            };

            // 顶点输出结构体，同时也是片元输入结构体
            struct v2f
            {
                // 传递给片元着色器的 UV 坐标
                // 每个 uv 对应天空球上的一个方向
                float2 uv : TEXCOORD0;

                // 裁剪空间顶点坐标
                // SV_POSITION 是 GPU 光栅化阶段必须使用的位置语义
                float4 vertex : SV_POSITION;
            };

            // 顶点着色器
            // 负责把全屏网格顶点转换到裁剪空间，并把 UV 传递给片元着色器
            v2f vert (appdata v)
            {
                // 声明输出结构体
                v2f o;

                // 将模型空间顶点转换到齐次裁剪空间
                // TransformObjectToHClip 是 URP 封装函数，本质是执行 MVP 矩阵变换
                o.vertex = TransformObjectToHClip(v.vertex);

                // 将输入 UV 原样传给片元阶段
                // 片元阶段会根据这个 uv 还原天空方向 viewDir
                o.uv = v.uv;

                // 返回顶点输出
                return o;
            }

            // 声明一个线性过滤 + Clamp 寻址的采样器
            // 线性过滤可以让 LUT 采样结果更加平滑
            // Clamp 可以防止 UV 越界时发生 Repeat 环绕
            //
            // 注意：
            // 当前文件声明的是 sampler_skyViewLinearClamp，
            // 但 frag 中实际传给 GetSkyView() 的是 sampler_LinearClamp。
            // 如果 sampler_LinearClamp 没有在其他 include 文件里声明，会导致编译错误。
            SAMPLER(sampler_skyViewLinearClamp);

            // 透射率 LUT
            // 用于查询太阳光从某个大气采样点沿太阳方向到大气边缘的衰减
            Texture2D _transmittanceLut;

            // 多重散射 LUT
            // 用于补偿单次散射之外的二次及更高阶散射贡献
            Texture2D _multiScatteringLut;

            // 片元着色器
            // 每个像素负责计算 SkyView LUT 中一个方向对应的天空颜色
            float4 frag (v2f i) : SV_Target
            {
                // 获取当前大气参数
                // param 包含星球半径、大气高度、太阳颜色、Rayleigh 参数、Mie 参数、臭氧参数等
                AtmosphereParameter param = GetAtmosphereParameter();

                // 初始化输出颜色
                // RGB 后续存储天空散射颜色
                // A 设置为 1，表示该 LUT 像素不透明或作为占位值
                float4 color = float4(0, 0, 0, 1);

                // 获取当前 LUT 像素的二维坐标
                // uv.x 和 uv.y 会被映射为天空球面方向
                float2 uv = i.uv;

                // 将二维 uv 转换为三维单位方向 viewDir
                //
                // UVToViewDir() 在 Helper.hlsl 中定义：
                // uv.x 控制水平方位角 phi
                // uv.y 控制垂直极角 theta
                //
                // 得到的 viewDir 表示：
                // 从观察点出发，看向天空球某个方向的射线方向
                float3 viewDir = UVToViewDir(uv);

                // 获取 URP 当前主光源
                // 在大气散射系统中，主光源通常被当作太阳
                Light mainLight = GetMainLight();

                // 获取主光源方向
                //
                // 注意：
                // 这里使用 mainLight.direction。
                // 你前面的 Skybox.shader 中使用的是 -mainLight.direction。
                // 所以整个项目中 lightDir 的方向约定需要统一。
                //
                // lightDir 可以有两种常见约定：
                // 1. 从采样点指向太阳
                // 2. 太阳光照射方向，也就是从太阳指向采样点
                //
                // Scattering(param, p, lightDir, viewDir) 里会使用 dot(lightDir, viewDir)，
                // 因此 lightDir 的方向必须和太阳盘、SkyView、AerialPerspective 中保持一致。
                float3 lightDir = mainLight.direction;
                
                // 根据 Unity 世界空间相机高度，计算大气模型中的相机半径高度
                //
                // _WorldSpaceCameraPos.y 是 Unity 世界空间中的相机高度
                // param.SeaLevel 是海平面高度
                // param.PlanetRadius 是星球半径
                //
                // h 表示相机到星球中心的距离：
                // h = 星球半径 + 相机相对海平面的高度
                float h = _WorldSpaceCameraPos.y - param.SeaLevel + param.PlanetRadius;

                // 构造大气模型中的观察点 eyePos
                //
                // 这里没有使用完整的 _WorldSpaceCameraPos.xyz，
                // 而是只使用高度，把相机放在球形大气模型的 y 轴上。
                //
                // 技术原理：
                // 球形大气具有旋转对称性。
                // 只要知道相机高度、视线方向和太阳方向，
                // 就可以计算天空散射，不必关心相机在水平面上的具体位置。
                float3 eyePos = float3(0, h, 0);

                // 调用 GetSkyView() 计算当前 viewDir 方向上的天空颜色
                //
                // 参数说明：
                // param：大气参数
                // eyePos：观察点
                // viewDir：当前天空方向
                // lightDir：太阳光方向
                // -1.0f：maxDis，表示不限制最大积分距离
                // _transmittanceLut：用于查询太阳光到采样点的透射率
                // _multiScatteringLut：用于查询多重散射补偿
                // sampler_LinearClamp：用于采样 LUT 的采样器
                //
                // GetSkyView 内部会：
                // 1. 计算 viewDir 与大气层 / 星球的交点
                // 2. 沿 viewDir 做 ray marching
                // 3. 每一步计算 Rayleigh / Mie / Ozone
                // 4. 查询 Transmittance LUT
                // 5. 查询 MultiScattering LUT
                // 6. 累积单次散射和多重散射
                //
                // 最终结果写入 color.rgb，作为该天空方向的 LUT 值
                color.rgb = GetSkyView(
                    param, eyePos, viewDir, lightDir, -1.0f,
                    _transmittanceLut, _multiScatteringLut, sampler_LinearClamp
                );

                // 返回当前 SkyView LUT 像素颜色
                // RGB = 当前方向的天空散射颜色
                // A = 1
                return color;
            }

            // 结束 HLSL 代码块
            ENDHLSL
        }
    }
}