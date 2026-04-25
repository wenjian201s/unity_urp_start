// 定义 Shader 名称
// 在 Unity 的 Shader 选择菜单中会显示为 CasualAtmosphere/Skybox
Shader "CasualAtmosphere/Skybox"
{
    // Properties 是 Unity 材质面板中可以暴露出来的参数
    Properties
    {
        // 声明一张源 HDR 纹理
        // 从变量名看，它可能原本用于混合 HDR 天空贴图或调试天空背景
        // 但当前代码中没有实际使用 _SourceHdrTexture
        _SourceHdrTexture ("Source HDR Texture", 2D) = "white" {}
    }

    // SubShader 是 Shader 的实际渲染实现
    SubShader
    {
        // Cull Off：关闭背面剔除
        // 天空盒通常需要从内部观察，如果开启剔除可能导致天空盒不可见
        Cull Off

        // ZWrite Off：关闭深度写入
        // 天空盒只是背景，不应该写入深度，否则会遮挡后续物体或影响深度测试
        ZWrite Off

        // ZTest LEqual：深度测试使用小于等于
        // 天空盒通常作为背景绘制，允许在远处深度通过
        // 和之前后处理 Pass 的 ZTest Always 不同，这里仍然考虑深度关系
        ZTest LEqual

        // 定义一个渲染 Pass
        Pass
        {
            // 开始 HLSL 程序
            HLSLPROGRAM

            // 指定顶点着色器入口函数为 vert
            #pragma vertex vert

            // 指定片元着色器入口函数为 frag
            #pragma fragment frag

            // 引入 URP 核心库
            // 提供 TransformObjectToHClip、TransformObjectToWorld、矩阵、平台宏等基础功能
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // 引入 URP 光照库
            // 当前代码会使用 GetMainLight() 获取主光源方向
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // 引入自定义辅助函数
            // 这里会用到 ViewDirToUV()、RayIntersectSphere() 等函数
            #include "Helper.hlsl"

            // 引入自定义散射函数
            // 提供 AtmosphereParameter、Rayleigh、Mie、Ozone 等散射相关函数
            #include "Scattering.hlsl"

            // 引入大气参数封装文件
            // 提供 GetAtmosphereParameter()，用于从 Unity 全局变量构造大气参数结构体
            #include "AtmosphereParameter.hlsl"

            // 引入光线步进和 LUT 查询函数
            // 这里会用到 TransmittanceToAtmosphere()
            #include "Raymarching.hlsl"

            // 顶点输入结构体
            struct appdata
            {
                // 模型空间顶点位置
                // 对天空盒来说，通常来自一个立方体或球体网格
                float4 vertex : POSITION;

                // 第一套 UV 坐标
                // 当前代码中没有使用这个 uv
                float2 uv : TEXCOORD0;
            };

            // 顶点输出结构体，同时也是片元输入结构体
            struct v2f
            {
                // 裁剪空间位置
                // SV_POSITION 是 GPU 光栅化必须使用的位置语义
                float4 vertex : SV_POSITION;

                // 世界空间位置
                // 用来在片元阶段计算当前像素对应的天空观察方向
                //
                // 注意：
                // SEMANTIC_HELLO_WORLD 是一个自定义语义名。
                // 在部分平台或渲染后端上可能不如 TEXCOORDn 稳定。
                // 更常见、更安全的写法是：
                // float3 worldPos : TEXCOORD0;
                float3 worldPos : TEXCOORD0;
            };

            // 顶点着色器
            // 负责把天空盒顶点转换到裁剪空间，并把世界空间位置传给片元着色器
            v2f vert (appdata v)
            {
                // 声明输出结构体
                v2f o;

                // 将模型空间顶点转换到齐次裁剪空间
                // 这是正常渲染天空盒几何体所需的位置变换
                o.vertex = TransformObjectToHClip(v.vertex);

                // 将模型空间顶点转换到世界空间
                // 后续片元阶段会用 normalize(i.worldPos) 得到视线方向
                o.worldPos = TransformObjectToWorld(v.vertex.xyz);

                // 返回顶点输出
                return o;
            }

            // 声明一个线性 Clamp 采样器
            // 理论上可用于采样 skybox LUT 或 HDR 贴图
            // 但当前代码实际没有使用 sampler_skyboxLinearClamp，而是使用了 sampler_LinearClamp
            SAMPLER(sampler_skyboxLinearClamp);

            // 天空视图 LUT
            // 这张纹理通常由 SkyViewLut Pass 预计算得到
            // 存储不同视线方向下的天空大气散射颜色
            Texture2D _skyViewLut;

            // 透射率 LUT
            // 用于计算太阳光从相机位置沿视线方向穿过大气时的衰减
            Texture2D _transmittanceLut;

            // 源 HDR 纹理
            // 当前代码中没有使用
            // 可能是预留给 HDRI 天空、调试背景或后续混合使用
            Texture2D _SourceHdrTexture;

            // ------------------------------------------------------------
            // 函数：GetSunDisk
            // 作用：计算当前视线方向上是否能看到太阳盘，
            //      如果能看到，则返回经过大气衰减后的太阳亮度。
            //
            // 技术原理：
            // 1. 判断 viewDir 是否接近太阳方向
            // 2. 判断太阳方向是否被星球遮挡
            // 3. 判断视线是否穿过大气层
            // 4. 使用 Transmittance LUT 计算太阳光穿过大气后的衰减
            // ------------------------------------------------------------
            float3 GetSunDisk(in AtmosphereParameter param, float3 eyePos, float3 viewDir, float3 lightDir)
            {
                // 计算视线方向和太阳方向之间的夹角余弦
                //
                // 这里使用 dot(viewDir, -lightDir)
                // 说明此函数内部认为 -lightDir 才是太阳所在方向
                //
                // cosine_theta 越接近 1，表示当前视线越接近太阳中心
                float cosine_theta = dot(viewDir, -lightDir);

                // 将夹角从弧度转换为角度
                //
                // acos(cosine_theta) 得到弧度制夹角
                // 乘以 180 / PI 转换成角度
                //
                // 后续会和 param.SunDiskAngle 比较，用于判断是否在太阳圆盘范围内
                float theta = acos(cosine_theta) * (180.0 / PI);

                // 计算太阳亮度
                // 太阳颜色乘太阳强度，得到太阳入射光的 HDR 亮度
                float3 sunLuminance = param.SunLightColor * param.SunLightIntensity;

                // ------------------------------------------------------------
                // 判断光线是否被星球阻挡
                // ------------------------------------------------------------

                // 计算当前视线方向与星球地表球体的交点
                // 如果 disToPlanet >= 0，说明这条视线会打到星球表面
                float disToPlanet = RayIntersectSphere(float3(0,0,0), param.PlanetRadius, eyePos, viewDir);

                // 如果视线被星球挡住，则太阳不可见，返回黑色
                // 这可以避免太阳出现在地平线以下或地球背面
                if(disToPlanet >= 0) return float3(0,0,0);

                // ------------------------------------------------------------
                // 判断视线是否与大气层相交
                // ------------------------------------------------------------

                // 计算视线与大气层外边界的交点
                // 大气层外半径 = 星球半径 + 大气高度
                float disToAtmosphere = RayIntersectSphere(float3(0,0,0), param.PlanetRadius + param.AtmosphereHeight, eyePos, viewDir);

                // 如果视线没有穿过大气层，则没有大气中的太阳衰减计算，直接返回黑色
                if(disToAtmosphere < 0) return float3(0,0,0);

                // ------------------------------------------------------------
                // 计算太阳盘的大气衰减
                // ------------------------------------------------------------

                // 下面两行是被注释掉的旧写法：
                // 先求视线与大气层的命中点，再从命中点到眼睛直接积分 Transmittance
                //
                // float3 hitPoint = eyePos + viewDir * disToAtmosphere;
                // sunLuminance *= Transmittance(param, hitPoint, eyePos);

                // 当前使用查表方式计算透射率
                // TransmittanceToAtmosphere(param, eyePos, viewDir, ...)
                // 表示从 eyePos 沿 viewDir 到大气层边缘的透射率
                //
                // 对太阳盘来说，viewDir 近似就是指向太阳的方向，
                // 所以这可以近似表示太阳光从大气外部到相机的反向路径衰减
                //
                // 注意：
                // 这里使用的是 sampler_LinearClamp，而不是上面声明的 sampler_skyboxLinearClamp。
                // 如果 sampler_LinearClamp 在其他 include 文件中没有定义，会导致编译错误。
                sunLuminance *= TransmittanceToAtmosphere(param, eyePos, viewDir, _transmittanceLut, sampler_LinearClamp);

                // 如果当前视线与太阳方向的夹角小于太阳圆盘角度，
                // 说明当前像素位于太阳盘内部，返回太阳亮度
                if(theta < param.SunDiskAngle) return sunLuminance;

                // 否则当前视线不在太阳盘范围内，返回黑色
                return float3(0,0,0);
            }

            // ------------------------------------------------------------
            // 片元着色器
            // 作用：计算天空盒每个像素的最终颜色
            // ------------------------------------------------------------
            float4 frag (v2f i) : SV_Target
            {
                // 获取大气参数结构体
                // 包含星球半径、大气高度、太阳颜色、散射参数等
                AtmosphereParameter param = GetAtmosphereParameter();

                // 初始化输出颜色
                // RGB 后面会累加天空 LUT 和太阳盘
                // A 设置为 1，表示不透明背景
                float4 color = float4(0, 0, 0, 1);

                // 根据插值后的世界空间位置得到当前像素的观察方向
                //
                // 对天空盒来说，顶点位置通常代表方向。
                // normalize 后得到单位视线方向 viewDir。
                //
                // 注意：
                // 如果天空盒网格不是以世界原点或相机为中心，
                // 更稳妥的写法通常是：
                // float3 viewDir = normalize(i.worldPos - _WorldSpaceCameraPos.xyz);
                float3 viewDir = normalize(i.worldPos - _WorldSpaceCameraPos.xyz);

                // 获取 URP 当前主光源
                // 在大气系统中，主光源通常被当作太阳
                Light mainLight = GetMainLight();

                // 获取太阳方向
                //
                // 这里使用 -mainLight.direction。
                // 但你前面的 AerialPerspectiveLut 中使用的是：
                // float3 lightDir = mainLight.direction;
                //
                // 所以需要注意整个项目里 lightDir 的方向约定必须一致：
                // 它到底表示“从点指向太阳”，还是“太阳光照射方向”。
                float3 lightDir = -mainLight.direction;

                // 根据 Unity 世界空间相机高度，计算大气模型中的相机半径高度
                //
                // _WorldSpaceCameraPos.y 是 Unity 世界空间相机高度
                // param.SeaLevel 是海平面高度
                // param.PlanetRadius 是星球半径
                //
                // h 表示相机到星球中心的距离
                float h = _WorldSpaceCameraPos.y - param.SeaLevel + param.PlanetRadius;

                // 构造大气模型中的观察点
                //
                // 由于球形大气具有旋转对称性，
                // 可以把相机放在 y 轴上，只保留高度信息。
                float3 eyePos = float3(0, h, 0);
                
                // ------------------------------------------------------------
                // 采样 Sky View LUT
                // ------------------------------------------------------------

                // 将当前视线方向 viewDir 转换成 SkyViewLUT 的二维 UV 坐标
                // 然后从 _skyViewLut 中读取该方向对应的天空散射颜色
                //
                // SAMPLE_TEXTURE2D_X 是 Unity 用于兼容普通纹理、XR 纹理数组等情况的采样宏
                //
                // 注意：
                // 这里同样使用了 sampler_LinearClamp，而不是声明的 sampler_skyboxLinearClamp。
                color.rgb += _skyViewLut.SampleLevel(sampler_LinearClamp, ViewDirToUV(viewDir), 0).rgb;

                // ------------------------------------------------------------
                // 添加太阳盘
                // ------------------------------------------------------------

                // 计算当前视线方向上是否存在太阳盘
                // 如果 viewDir 落在太阳圆盘角度范围内，就返回太阳亮度，否则返回 0
                color.rgb += GetSunDisk(param, eyePos, viewDir, lightDir);

                // 返回最终天空盒颜色
                // RGB = SkyViewLUT 天空颜色 + 太阳盘颜色
                // A = 1
                return color;
            }

            // 结束 HLSL 程序
            ENDHLSL
        }
    }
}
