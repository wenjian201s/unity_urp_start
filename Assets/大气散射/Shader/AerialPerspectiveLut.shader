// 定义 Shader 名称
// 在 Unity 材质或 Shader 选择菜单中会显示为 CasualAtmosphere/AerialPerspectiveLut
Shader "CasualAtmosphere/AerialPerspectiveLut"
{
    // Properties 用于暴露材质参数到 Unity Inspector 面板
    // 这里为空，说明该 Shader 的主要参数不是通过材质面板设置，
    // 而是由 C# 脚本通过 SetFloat、SetVector、SetTexture 等方式传入
    Properties
    {

    }

    // SubShader 是 Shader 的实际渲染实现
    SubShader
    {
        // Cull Off：关闭背面剔除
        // 由于这是全屏 Pass 或 LUT 写入 Pass，不需要根据三角形正反面剔除
        Cull Off

        // ZWrite Off：关闭深度写入
        // 生成 LUT 不需要写入深度缓冲，避免影响场景深度
        ZWrite Off

        // ZTest Always：深度测试永远通过
        // LUT 生成通常是对整张 RenderTexture 写入，不应该受深度缓冲影响
        ZTest Always

        // 定义一个渲染 Pass
        // 这个 Pass 会把 Aerial Perspective 的计算结果写入目标 RenderTexture
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
            // 这里主要使用 GetMainLight() 和 Light 结构体来获取主光源方向
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // 引入 Unity 输入变量库
            // 提供 unity_CameraToWorld、_WorldSpaceCameraPos、_ScreenParams 等 Unity 内置变量
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/UnityInput.hlsl"

            // 引入自定义辅助函数库
            // 通常包含通用数学函数、坐标转换函数、常量定义等
            #include "Helper.hlsl"

            // 引入自定义大气散射函数库
            // 通常包含 Rayleigh 散射、Mie 散射、相函数、散射系数等相关函数
            #include "Scattering.hlsl"

            // 引入自定义大气参数库
            // 通常包含 GetAtmosphereParameter()、星球半径、大气半径、海平面高度等参数
            #include "AtmosphereParameter.hlsl"

            // 引入自定义 Raymarching 库
            // 通常包含沿视线方向积分大气散射的函数，例如 GetSkyView()
            #include "Raymarching.hlsl"

            // 顶点输入结构体
            struct appdata
            {
                // 模型空间顶点坐标
                // POSITION 语义表示该变量来自网格顶点位置
                float4 vertex : POSITION;

                // 第一套 UV 坐标
                // 对于全屏 Pass 来说，它通常对应屏幕或 RenderTexture 的归一化坐标
                float2 uv : TEXCOORD0;
            };

            // 顶点输出结构体，同时也是片元输入结构体
            struct v2f
            {
                // 传递给片元着色器的 UV 坐标
                float2 uv : TEXCOORD0;

                // 裁剪空间坐标
                // SV_POSITION 是 GPU 光栅化阶段需要的屏幕位置
                float4 vertex : SV_POSITION;
            };

            // 顶点着色器
            // 负责把输入顶点转换到裁剪空间，并把 UV 传给片元着色器
            v2f vert (appdata v)
            {
                // 创建输出结构体
                v2f o;

                // 将模型空间顶点坐标转换到齐次裁剪空间
                // TransformObjectToHClip 是 URP 封装函数，本质是执行 MVP 矩阵变换
                o.vertex = TransformObjectToHClip(v.vertex);

                // 将输入 UV 原样传递到片元着色器
                o.uv = v.uv;

                // 返回顶点着色器输出
                return o;
            }

            // Aerial Perspective 最大计算距离
            // uv.z 会映射到 [0, _AerialPerspectiveDistance]
            // 表示当前 LUT 层对应从相机出发的最大积分距离
            float _AerialPerspectiveDistance;

            // Aerial Perspective 体素尺寸参数
            // 根据这段代码的使用方式，它用于把一个 3D LUT 打包进 2D RenderTexture
            // 常见含义可能是：
            // x = LUT 横向分辨率或某个打包维度
            // y = LUT 纵向分辨率
            // z = 距离方向 slice 数量
            float4 _AerialPerspectiveVoxelSize;

            // 声明线性过滤 + Clamp 寻址的采样器
            // 线性采样适合 LUT 查询，可以减少采样结果的块状感
            // Clamp 可以防止 UV 越界后产生重复或环绕采样
            SAMPLER(sampler_aerialLutLinearClamp);

            // 透射率 LUT
            // 通常存储从某个高度、某个方向到大气边界之间的光学透射率
            // 在大气散射中用于快速查询光线穿过大气后的衰减
            Texture2D _transmittanceLut;

            // 多重散射 LUT
            // 通常存储高阶散射的近似结果
            // 用来补偿单次散射缺失的环境光、多次反弹散射等效果
            Texture2D _multiScatteringLut;

            // 片元着色器
            // 每个像素对应 Aerial Perspective LUT 中的一个采样点
            float4 frag (v2f i) : SV_Target
            {
                // 获取大气参数
                // param 中通常包含：
                // 星球半径、海平面高度、大气半径、Rayleigh 散射参数、Mie 散射参数、吸收参数等
                AtmosphereParameter param = GetAtmosphereParameter();

                // 初始化输出颜色
                // RGB 后面会存储 in-scattering
                // A 后面会存储 transmittance
                float4 color = float4(0, 0, 0, 1);

                // 将当前 2D UV 扩展成 3D UV
                // i.uv.xy 来自当前 RenderTexture 的屏幕坐标
                // uv.z 初始为 0，后面会从打包坐标中解析出来
                float3 uv = float3(i.uv, 0);

                float atlasX = uv.x * _AerialPerspectiveVoxelSize.x * _AerialPerspectiveVoxelSize.z;

                // 从打包后的横向坐标中解析出 z 方向 slice 坐标
                // int(uv.x / _AerialPerspectiveVoxelSize.z) 取得当前像素所在的某个分组编号
                // 再除以 _AerialPerspectiveVoxelSize.x 归一化到 [0, 1]
                //
                // 技术原理：
                // 这是一种 3D LUT 压缩到 2D 纹理的 atlas 展开方式。
                // 由于普通后处理更容易写入 2D RenderTexture，
                // 所以这里把 3D 坐标中的一个维度折叠到 2D 纹理的横向。
                uv.z = floor(atlasX / _AerialPerspectiveVoxelSize.x) / _AerialPerspectiveVoxelSize.z;

                // 从打包后的横向坐标中解析出当前 slice 内部的 x 坐标
                // fmod 表示取余数，用来得到当前像素在局部 tile 内的位置
                // 再除以 _AerialPerspectiveVoxelSize.x，把局部坐标归一化
                uv.x = fmod(atlasX, _AerialPerspectiveVoxelSize.x) / _AerialPerspectiveVoxelSize.x;

                // 给 uv.xyz 加上半个体素大小的偏移
                // 目的是采样体素中心，而不是采样体素边界
                //
                // 技术原理：
                // LUT 离散采样时，如果直接采样整数边界，容易出现偏移和边缘误差。
                // 加 0.5 / resolution 可以让采样点位于每个 texel / voxel 的中心。
                uv.xyz += 0.5 / _AerialPerspectiveVoxelSize.xyz;

                // 计算当前屏幕或 LUT 的宽高比
                // _ScreenParams.x 是当前渲染目标宽度
                // _ScreenParams.y 是当前渲染目标高度
                float aspect = _ScreenParams.x / _ScreenParams.y;

                // 根据 uv.xy 生成当前 LUT 像素对应的视线方向
                // uv.x 和 uv.y 从 [0, 1] 映射到 [-1, 1]
                // 然后通过 unity_CameraToWorld 把相机空间方向转换到世界空间
                float3 viewDir = normalize(mul(unity_CameraToWorld, float4(
                    // 横向屏幕坐标从 [0, 1] 转换到 [-1, 1]
                    // 表示相机空间中的水平视线偏移
                    (uv.x * 2.0 - 1.0) * 1.0, 

                    // 纵向屏幕坐标从 [0, 1] 转换到 [-1, 1]
                    // 再除以 aspect，用于校正渲染目标宽高比带来的方向拉伸
                    (uv.y * 2.0 - 1.0) / aspect, 

                    // z = 1.0 表示视线朝向相机前方
                    // 这里构造的是相机空间下的一条射线方向
                    1.0, 

                    // w = 0.0 表示这是方向向量，不是位置点
                    // 用矩阵变换时不会受到平移分量影响
                    0.0
                )).xyz);

                // 调试代码：
                // 如果取消注释，会直接把视线方向当作颜色输出
                // 可用于检查 viewDir 是否正确
                // return float4(viewDir, 1.0);

                // 获取 URP 当前主光源
                // 对于大气散射来说，主光源通常就是太阳
                Light mainLight = GetMainLight();

                // 获取主光源方向
                // 大气散射需要知道太阳光方向，以计算太阳光被大气粒子散射进视线方向的强度
                float3 lightDir = mainLight.direction;
                
                // 计算相机在大气模型中的高度
                // _WorldSpaceCameraPos.y 是 Unity 世界空间中的相机高度
                // param.SeaLevel 是海平面高度
                // param.PlanetRadius 是星球半径
                //
                // 最终 h 表示：
                // 从星球中心到相机位置的半径距离
                float h = _WorldSpaceCameraPos.y - param.SeaLevel + param.PlanetRadius;

                // 构造大气模型中的观察点位置
                // 这里把相机放在星球局部空间的 y 轴上
                //
                // 技术原理：
                // 对球形大气来说，如果只考虑高度和方向，
                // 可以把相机水平位置简化到 (0, h, 0)，因为球形大气在水平方向上具有旋转对称性。
                float3 eyePos = float3(0, h, 0);

                // 根据 uv.z 计算当前 LUT slice 对应的最大积分距离
                // uv.z 越大，表示沿视线积分得越远
                // _AerialPerspectiveDistance 是最大大气透视距离
                float maxDis = uv.z * _AerialPerspectiveDistance;

                // ------------------------------------------------------------
                // inScattering 计算
                // ------------------------------------------------------------

                // 计算从 eyePos 沿 viewDir 方向，到 maxDis 距离为止的天空 / 大气散射颜色
                // 结果写入 color.rgb
                //
                // GetSkyView 通常会做如下事情：
                // 1. 沿 viewDir 做 ray marching
                // 2. 在每个采样点计算大气密度
                // 3. 根据 lightDir 计算太阳光入射方向
                // 4. 查询 _transmittanceLut 获得太阳光到该点的衰减
                // 5. 查询 _multiScatteringLut 补偿多重散射
                // 6. 累积沿视线进入相机的散射光
                color.rgb = GetSkyView(
                    // 大气参数
                    param, 

                    // 观察点，也就是相机在大气模型中的位置
                    eyePos, 

                    // 从相机出发的视线方向
                    viewDir, 

                    // 太阳 / 主光源方向
                    lightDir, 

                    // 当前 slice 对应的最大积分距离
                    maxDis,

                    // 透射率 LUT，用于查询光线穿过大气后的衰减
                    _transmittanceLut, 

                    // 多重散射 LUT，用于补充高阶散射贡献
                    _multiScatteringLut, 

                    // LUT 采样器
                    sampler_aerialLutLinearClamp
                );

                // ------------------------------------------------------------
                // transmittance 计算
                // ------------------------------------------------------------

                // 计算当前视线方向上，距离 maxDis 处的体素位置
                // 也就是从相机出发，沿 viewDir 走 maxDis 后到达的位置
                float segmentDistance = maxDis;
                float disToAtmosphere = RayIntersectSphere(float3(0,0,0), param.PlanetRadius + param.AtmosphereHeight, eyePos, viewDir);
                if(disToAtmosphere > 0) segmentDistance = min(segmentDistance, disToAtmosphere);

                float disToPlanet = RayIntersectSphere(float3(0,0,0), param.PlanetRadius, eyePos, viewDir);
                if(disToPlanet > 0) segmentDistance = min(segmentDistance, disToPlanet);

                segmentDistance = max(segmentDistance, 0.0);
                float3 voxelPos = eyePos + viewDir * segmentDistance;
                float3 t = segmentDistance > 0.001 ? Transmittance(param, eyePos, voxelPos) : 1.0.xxx;

                // 将 RGB 三个通道的透射率取平均，存入 alpha 通道
                // alpha 后续会被 AerialPerspective Shader 当作 transmittance 使用
                //
                // dot(t, float3(1/3, 1/3, 1/3)) 等价于：
                // (t.r + t.g + t.b) / 3
                //
                // 这里把彩色透射率压缩成单通道透射率，
                // 优点是节省存储，缺点是会丢失不同波长的色彩衰减差异
                color.a = dot(t, float3(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0));

                // 返回当前 LUT 像素的结果
                // RGB = inScattering
                // A   = transmittance
                return color;
            }

            // 结束 HLSL 代码块
            ENDHLSL
        }
    }
}
