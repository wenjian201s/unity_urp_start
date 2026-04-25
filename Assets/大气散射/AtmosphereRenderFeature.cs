// 引入 System 命名空间
// 这里主要用于 [Serializable] 特性，使内部设置类可以被 Unity 序列化并显示在 Inspector 中
using System;

// 引入 UnityEngine 命名空间
// 提供 Unity 基础类型，例如 Camera、Material、RenderTexture、Texture2D、Vector4、Application、Debug 等
using UnityEngine;

// 引入 UnityEngine.Rendering 命名空间
// 提供 CommandBuffer、CommandBufferPool、RenderTextureDescriptor 等底层渲染 API
using UnityEngine.Rendering;

// 引入 URP 命名空间
// 提供 ScriptableRendererFeature、ScriptableRenderPass、RenderingData、RenderPassEvent 等 URP 扩展接口
using UnityEngine.Rendering.Universal;


/// <summary>
/// Unity 2022.3 / URP 14 兼容版实时大气散射 LUT 生成 Feature。
/// 
/// 作用：
/// 1. 创建并维护 Transmittance LUT
/// 2. 创建并维护 MultiScattering LUT
/// 3. 创建并维护 SkyView LUT
/// 4. 创建并维护 AerialPerspective LUT
/// 5. 将 AtmosphereSettings 参数传入 Shader
/// 6. 将生成好的 LUT 设置为全局纹理，供 Skybox / AerialPerspective 使用
/// </summary>

// 定义一个 URP Renderer Feature
// Renderer Feature 是 URP 中给渲染器插入自定义渲染逻辑的入口
public class AtmosphereRenderFeature : ScriptableRendererFeature
{
    // 标记 FeatureSettings 可以被序列化
    // 这样该类里的字段可以在 Unity Inspector 中显示和保存
    [Serializable]

    // 定义 FeatureSettings 配置类
    // 用于保存该 RendererFeature 的可调参数，例如 LUT 分辨率、Pass 插入时机、Debug 开关
    public class FeatureSettings
    {
        // 在 Inspector 中显示分组标题 Render Pass
        [Header("Render Pass")]

        // 设置该 Pass 插入 URP 渲染流程的位置
        // BeforeRenderingSkybox 表示在渲染天空盒之前生成 LUT
        // 这样 Skybox Shader 采样 _skyViewLut 时，LUT 已经准备好
        public RenderPassEvent renderPassEvent = RenderPassEvent.BeforeRenderingSkybox;


        // 在 Inspector 中显示分组标题 LUT Size
        [Header("LUT Size")]

        // SkyView LUT 的宽度
        // SkyView LUT 用于存储不同天空方向上的天空散射颜色
        public int skyViewLutWidth = 256;

        // SkyView LUT 的高度
        // 通常宽高比为 2:1，用于覆盖球面方向映射
        public int skyViewLutHeight = 128;


        // Transmittance LUT 的宽度
        // 横向通常表示光线方向 / 透射路径相关参数
        public int transmittanceLutWidth = 256;

        // Transmittance LUT 的高度
        // 纵向通常表示大气高度参数
        public int transmittanceLutHeight = 64;


        // MultiScattering LUT 的宽度
        // 横向通常表示太阳天顶角 cosSunZenithAngle
        public int multiScatteringLutWidth = 32;

        // MultiScattering LUT 的高度
        // 纵向通常表示采样点高度
        public int multiScatteringLutHeight = 32;


        // Aerial Perspective 单个 slice 的宽度
        // 一个 slice 表示某个距离层下的视线方向大气透视数据
        public int aerialPerspectiveSliceWidth = 32;

        // Aerial Perspective 单个 slice 的高度
        // 和 sliceWidth 一起构成每个距离层的 2D 方向 LUT
        public int aerialPerspectiveSliceHeight = 32;

        // Aerial Perspective 距离方向的 slice 数量
        // 例如 32 表示把最大大气透视距离分成 32 层
        public int aerialPerspectiveSliceCount = 32;


        // 在 Inspector 中显示分组标题 Debug
        [Header("Debug")]

        // 是否启用 Scene View 中的 Debug.DrawLine 调试绘制
        // 该功能会从 GPU 读回 AerialPerspective LUT，因此默认关闭更安全
        public bool enableSceneViewDebugDraw = false;
    }


    // 定义真正执行 LUT 生成的 RenderPass
    // ScriptableRenderPass 是 URP 中执行自定义渲染命令的核心单位
    class AtmosphereLutPass : ScriptableRenderPass
    {
        // 保存外部传入的 FeatureSettings
        // readonly 表示该引用只能在构造函数中赋值，避免运行时被误替换
        private readonly FeatureSettings m_Settings;


        // SkyView LUT 的 RenderTexture
        // 保存天空方向对应的散射颜色
        private RenderTexture m_SkyViewLut;

        // Transmittance LUT 的 RenderTexture
        // 保存从某高度、某方向到大气边界的透射率
        private RenderTexture m_TransmittanceLut;

        // MultiScattering LUT 的 RenderTexture
        // 保存多重散射近似补偿结果
        private RenderTexture m_MultiScatteringLut;

        // AerialPerspective LUT 的 RenderTexture
        // 保存不同方向、不同距离层下的大气透视结果
        private RenderTexture m_AerialPerspectiveLut;


        // AerialPerspective LUT 的 CPU 读回纹理
        // 只用于 Scene View Debug，将 GPU RenderTexture 数据读回 CPU
        private Texture2D m_AerialPerspectiveReadback;


        // 生成 SkyView LUT 使用的材质
        // 该材质应使用 CasualAtmosphere/SkyViewLut Shader
        private Material m_SkyViewLutMaterial;

        // 生成 Transmittance LUT 使用的材质
        // 该材质应使用 CasualAtmosphere/TransmittanceLut Shader
        private Material m_TransmittanceLutMaterial;

        // 生成 MultiScattering LUT 使用的材质
        // 该材质应使用 CasualAtmosphere/MultiScatteringLut Shader
        private Material m_MultiScatteringLutMaterial;

        // 生成 AerialPerspective LUT 使用的材质
        // 该材质应使用 CasualAtmosphere/AerialPerspectiveLut Shader
        private Material m_AerialPerspectiveLutMaterial;


        // 大气参数配置资源
        // 保存星球半径、大气高度、太阳颜色、Rayleigh/Mie/Ozone 参数等
        private AtmosphereSettings m_AtmosphereSettings;


        // 将 Shader 属性名 _skyViewLut 转换为 int ID
        // 使用 PropertyToID 可以避免每帧用字符串查找属性，提高效率
        private static readonly int SkyViewLutId = Shader.PropertyToID("_skyViewLut");

        // 将 Shader 属性名 _transmittanceLut 转换为 int ID
        // 该全局纹理会被多个大气 Shader 采样
        private static readonly int TransmittanceLutId = Shader.PropertyToID("_transmittanceLut");

        // 将 Shader 属性名 _multiScatteringLut 转换为 int ID
        // 该全局纹理用于多重散射补偿
        private static readonly int MultiScatteringLutId = Shader.PropertyToID("_multiScatteringLut");

        // 将 Shader 属性名 _aerialPerspectiveLut 转换为 int ID
        // 该全局纹理用于场景大气透视后处理
        private static readonly int AerialPerspectiveLutId = Shader.PropertyToID("_aerialPerspectiveLut");


        // 海平面高度参数 ID
        // Shader 中对应 float _SeaLevel
        private static readonly int SeaLevelId = Shader.PropertyToID("_SeaLevel");

        // 星球半径参数 ID
        // Shader 中对应 float _PlanetRadius
        private static readonly int PlanetRadiusId = Shader.PropertyToID("_PlanetRadius");

        // 大气层高度参数 ID
        // Shader 中对应 float _AtmosphereHeight
        private static readonly int AtmosphereHeightId = Shader.PropertyToID("_AtmosphereHeight");

        // 太阳光强度参数 ID
        // Shader 中对应 float _SunLightIntensity
        private static readonly int SunLightIntensityId = Shader.PropertyToID("_SunLightIntensity");

        // 太阳光颜色参数 ID
        // Shader 中对应 float3 _SunLightColor
        private static readonly int SunLightColorId = Shader.PropertyToID("_SunLightColor");

        // 太阳盘角度参数 ID
        // Shader 中对应 float _SunDiskAngle
        private static readonly int SunDiskAngleId = Shader.PropertyToID("_SunDiskAngle");


        // Rayleigh 散射强度缩放参数 ID
        // 用于控制分子散射整体强度
        private static readonly int RayleighScatteringScaleId = Shader.PropertyToID("_RayleighScatteringScale");

        // Rayleigh 散射标高参数 ID
        // 用于控制空气分子密度随高度指数衰减
        private static readonly int RayleighScatteringScalarHeightId = Shader.PropertyToID("_RayleighScatteringScalarHeight");


        // Mie 散射强度缩放参数 ID
        // 用于控制气溶胶散射强度、雾感和光晕
        private static readonly int MieScatteringScaleId = Shader.PropertyToID("_MieScatteringScale");

        // Mie 各向异性参数 ID
        // 用于 Mie 相函数中的 g，控制前向散射强度
        private static readonly int MieAnisotropyId = Shader.PropertyToID("_MieAnisotropy");

        // Mie 散射标高参数 ID
        // 用于控制气溶胶密度随高度衰减
        private static readonly int MieScatteringScalarHeightId = Shader.PropertyToID("_MieScatteringScalarHeight");


        // 臭氧吸收强度缩放参数 ID
        // 用于控制臭氧吸收对天空颜色的影响
        private static readonly int OzoneAbsorptionScaleId = Shader.PropertyToID("_OzoneAbsorptionScale");

        // 臭氧层中心高度参数 ID
        // 表示臭氧密度最大的位置
        private static readonly int OzoneLevelCenterHeightId = Shader.PropertyToID("_OzoneLevelCenterHeight");

        // 臭氧层宽度参数 ID
        // 控制臭氧吸收在高度方向上的影响范围
        private static readonly int OzoneLevelWidthId = Shader.PropertyToID("_OzoneLevelWidth");


        // Aerial Perspective 最大距离参数 ID
        // 场景物体距离会被归一化到该范围内采样 LUT slice
        private static readonly int AerialPerspectiveDistanceId = Shader.PropertyToID("_AerialPerspectiveDistance");

        // Aerial Perspective 体素尺寸参数 ID
        // Shader 中对应 float4 _AerialPerspectiveVoxelSize
        private static readonly int AerialPerspectiveVoxelSizeId = Shader.PropertyToID("_AerialPerspectiveVoxelSize");


        // AtmosphereLutPass 构造函数
        // 创建 RenderPass 时传入 FeatureSettings
        public AtmosphereLutPass(FeatureSettings settings)
        {
            // 保存外部设置对象
            // 后续创建 RT、设置 slice 数量、判断 Debug 开关都会使用它
            m_Settings = settings;
        }


        // Setup 用于每帧或每次 AddRenderPasses 时更新 Pass 所需资源
        // 这样 Inspector 中替换材质或 AtmosphereSettings 后，Pass 能拿到最新引用
        public void Setup(
            Material skyViewLutMaterial,
            Material transmittanceLutMaterial,
            Material multiScatteringLutMaterial,
            Material aerialPerspectiveLutMaterial,
            AtmosphereSettings atmosphereSettings)
        {
            // 保存 SkyView LUT 生成材质
            m_SkyViewLutMaterial = skyViewLutMaterial;

            // 保存 Transmittance LUT 生成材质
            m_TransmittanceLutMaterial = transmittanceLutMaterial;

            // 保存 MultiScattering LUT 生成材质
            m_MultiScatteringLutMaterial = multiScatteringLutMaterial;

            // 保存 AerialPerspective LUT 生成材质
            m_AerialPerspectiveLutMaterial = aerialPerspectiveLutMaterial;

            // 保存大气配置资源
            m_AtmosphereSettings = atmosphereSettings;
        }


        // Execute 是 Unity 2022.3 URP 中 ScriptableRenderPass 的主要执行入口
        // URP 会在 renderPassEvent 指定的时机调用它
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            // 检查材质、设置、大气参数是否完整
            // 如果缺失资源，就直接跳过，避免 NullReferenceException
            if (!IsValid())
                return;

            // 获取当前正在渲染的相机
            // renderingData.cameraData.camera 是 URP 当前相机对象
            Camera camera = renderingData.cameraData.camera;

            // 如果当前相机为空，说明没有有效渲染上下文，直接返回
            if (camera == null)
                return;

            // Unity 2022 URP 下，Preview 相机有时会触发不必要的 Blit 或资源错误。
            // Preview 相机一般来自 Inspector 预览窗口，不需要生成大气 LUT
            if (camera.cameraType == CameraType.Preview)
                return;

            // 确保四张 LUT RenderTexture 已经创建
            // 如果尺寸、格式变化，也会自动释放旧 RT 并重新创建
            EnsureRenderTextures();

            // 从命令缓冲池获取一个 CommandBuffer
            // CommandBuffer 用于记录 GPU 渲染命令，例如 SetGlobalTexture、Blit 等
            CommandBuffer cmd = CommandBufferPool.Get("Casual Atmosphere LUT Pass");

            // 将 AtmosphereSettings 中的大气参数设置为 Shader 全局变量
            // 所有大气 Shader 都会通过这些全局变量构造 AtmosphereParameter
            SetGlobalAtmosphereParameters(cmd);

            // 将当前持有的 LUT RenderTexture 设置为 Shader 全局纹理
            // 后续 LUT 生成材质可以相互引用，例如 MultiScattering 需要 Transmittance
            SetGlobalLutTextures(cmd);

            // LUT 生成顺序不能乱：
            // 1. Transmittance 是最基础 LUT。
            // 2. MultiScattering 依赖 Transmittance。
            // 3. SkyView 依赖 Transmittance + MultiScattering。
            // 4. AerialPerspective 依赖 Transmittance + MultiScattering。

            // 生成 Transmittance LUT
            // Blit 的 source 为 null，表示材质本身通过全屏 Pass 生成目标内容
            cmd.Blit(null, m_TransmittanceLut, m_TransmittanceLutMaterial);

            // 生成 MultiScattering LUT
            // 它会采样前面生成的 _transmittanceLut，用于计算多重散射近似
            cmd.Blit(null, m_MultiScatteringLut, m_MultiScatteringLutMaterial);

            // 生成 SkyView LUT
            // 它会采样 _transmittanceLut 和 _multiScatteringLut，计算天空方向颜色
            cmd.Blit(null, m_SkyViewLut, m_SkyViewLutMaterial);

            // 生成 AerialPerspective LUT
            // 它也会采样 _transmittanceLut 和 _multiScatteringLut，计算场景空气透视
            cmd.Blit(null, m_AerialPerspectiveLut, m_AerialPerspectiveLutMaterial);

            // Blit 后再次设置一遍全局纹理，确保后续 Skybox / AerialPerspective Pass 读取到当前帧的 LUT。
            // 因为当前帧 LUT 已经被 Blit 更新，这里重新绑定可以避免后续 Pass 读到旧引用
            SetGlobalLutTextures(cmd);

            // 将 CommandBuffer 提交给 ScriptableRenderContext
            // 这一步后，URP 才会真正执行上面记录的 GPU 命令
            context.ExecuteCommandBuffer(cmd);

            // 将 CommandBuffer 归还到池中
            // 使用 CommandBufferPool.Get 后必须 Release，避免资源泄漏
            CommandBufferPool.Release(cmd);

            // 如果开启 Scene View Debug，并且当前相机是 Scene View 相机
            // 则从 AerialPerspective LUT 读回数据并绘制调试线
            if (m_Settings.enableSceneViewDebugDraw && renderingData.cameraData.isSceneViewCamera)
            {
                // 执行 Scene View 调试绘制
                DrawSceneViewDebug(camera);
            }
        }


        // 判断当前 Pass 是否拥有完整运行资源
        // 缺少任意材质或设置时，Pass 不应执行
        private bool IsValid()
        {
            // 返回所有必要对象是否都不为空
            // && 表示所有条件都成立时才返回 true
            return m_Settings != null
                   && m_AtmosphereSettings != null
                   && m_SkyViewLutMaterial != null
                   && m_TransmittanceLutMaterial != null
                   && m_MultiScatteringLutMaterial != null
                   && m_AerialPerspectiveLutMaterial != null;
        }


        // 确保所有 LUT RenderTexture 已经被创建
        // 如果目标平台不支持 ARGBFloat，则降级到 ARGBHalf
        private void EnsureRenderTextures()
        {
            // 检查当前平台是否支持 ARGBFloat RenderTexture
            // ARGBFloat 是 32-bit float x4，精度高，适合 HDR 大气散射
            RenderTextureFormat format = SystemInfo.SupportsRenderTextureFormat(RenderTextureFormat.ARGBFloat)
                ? RenderTextureFormat.ARGBFloat
                : RenderTextureFormat.ARGBHalf;

            // 确保 Transmittance LUT RT 存在且尺寸格式正确
            EnsureRenderTexture(
                ref m_TransmittanceLut,
                m_Settings.transmittanceLutWidth,
                m_Settings.transmittanceLutHeight,
                format,
                "Atmosphere_TransmittanceLut"
            );

            // 确保 MultiScattering LUT RT 存在且尺寸格式正确
            EnsureRenderTexture(
                ref m_MultiScatteringLut,
                m_Settings.multiScatteringLutWidth,
                m_Settings.multiScatteringLutHeight,
                format,
                "Atmosphere_MultiScatteringLut"
            );

            // 确保 SkyView LUT RT 存在且尺寸格式正确
            EnsureRenderTexture(
                ref m_SkyViewLut,
                m_Settings.skyViewLutWidth,
                m_Settings.skyViewLutHeight,
                format,
                "Atmosphere_SkyViewLut"
            );

            // 计算 AerialPerspective 2D Atlas 的总宽度
            // 宽度 = 单个 slice 宽度 × slice 数量
            int aerialWidth = m_Settings.aerialPerspectiveSliceWidth * m_Settings.aerialPerspectiveSliceCount;

            // 计算 AerialPerspective 2D Atlas 的高度
            // 高度 = 单个 slice 高度
            int aerialHeight = m_Settings.aerialPerspectiveSliceHeight;

            // 确保 AerialPerspective LUT RT 存在且尺寸格式正确
            EnsureRenderTexture(
                ref m_AerialPerspectiveLut,
                aerialWidth,
                aerialHeight,
                format,
                "Atmosphere_AerialPerspectiveLut"
            );

            // 如果开启 Scene View Debug，并且 CPU 读回纹理还没创建
            if (m_Settings.enableSceneViewDebugDraw && m_AerialPerspectiveReadback == null)
            {
                // 创建 CPU 读回 Texture2D
                // 宽高只读一个 slice 的大小，而不是整个 atlas
                m_AerialPerspectiveReadback = new Texture2D(
                    m_Settings.aerialPerspectiveSliceWidth,
                    m_Settings.aerialPerspectiveSliceHeight,
                    TextureFormat.RGBAFloat,
                    false,
                    true
                );
            }
        }


        // 创建或重建单张 RenderTexture 的工具函数
        // 使用 ref 是为了在函数内部替换外部传入的 RenderTexture 引用
        private static void EnsureRenderTexture(
            ref RenderTexture rt,
            int width,
            int height,
            RenderTextureFormat format,
            string name)
        {
            // 判断是否需要创建新的 RenderTexture
            // 当 RT 不存在、尺寸变化、格式变化时都需要重建
            bool needCreate = rt == null
                              || rt.width != width
                              || rt.height != height
                              || rt.format != format;

            // 如果不需要重建，直接返回
            // 这样可以避免每帧重复创建 RenderTexture
            if (!needCreate)
                return;

            // 如果旧 RT 存在，先释放旧 RT
            // 避免显存泄漏
            ReleaseRenderTexture(ref rt);

            // 创建 RenderTexture 描述符
            // width / height 是尺寸，format 是颜色格式，0 表示无深度缓冲
            RenderTextureDescriptor desc = new RenderTextureDescriptor(width, height, format, 0)
            {
                // 禁用 MSAA
                // LUT 不需要多重采样，因为它不是几何边缘渲染目标
                msaaSamples = 1,

                // 关闭 sRGB
                // 大气 LUT 保存的是线性空间物理计算结果，不应进行 sRGB 编码
                sRGB = false,

                // 不使用 mipmap
                // 大气 LUT 通常直接采样 mip 0，避免 mip 影响物理精度
                useMipMap = false,

                // 不自动生成 mipmap
                // 因为 useMipMap 为 false，这里也保持关闭
                autoGenerateMips = false,

                // 不需要深度缓冲
                // LUT 生成是全屏 Blit，不需要深度测试结果写入
                depthBufferBits = 0
            };

            // 根据描述符创建 RenderTexture 对象
            rt = new RenderTexture(desc)
            {
                // 设置 RT 名称，方便在 Frame Debugger 或 RenderDoc 中识别
                name = name,

                // 设置双线性过滤
                // LUT 采样时可以在 texel 之间平滑过渡
                filterMode = FilterMode.Bilinear,

                // 设置 Clamp 寻址
                // 防止采样超出 [0,1] 后发生重复环绕
                wrapMode = TextureWrapMode.Clamp,

                // 设置隐藏标记
                // HideAndDontSave 表示不在层级中显示，也不保存到场景资源
                hideFlags = HideFlags.HideAndDontSave
            };

            // 真正分配 GPU RenderTexture 资源
            rt.Create();
        }


        // 将四张 LUT 设置为 Shader 全局纹理
        // 任何 Shader 只要声明对应名称，就可以直接采样这些 LUT
        private void SetGlobalLutTextures(CommandBuffer cmd)
        {
            // 设置 SkyView LUT 全局纹理
            cmd.SetGlobalTexture(SkyViewLutId, m_SkyViewLut);

            // 设置 Transmittance LUT 全局纹理
            cmd.SetGlobalTexture(TransmittanceLutId, m_TransmittanceLut);

            // 设置 MultiScattering LUT 全局纹理
            cmd.SetGlobalTexture(MultiScatteringLutId, m_MultiScatteringLut);

            // 设置 AerialPerspective LUT 全局纹理
            cmd.SetGlobalTexture(AerialPerspectiveLutId, m_AerialPerspectiveLut);
        }


        // 将 AtmosphereSettings 中的大气参数设置为 Shader 全局变量
        // 这些变量会在 AtmosphereParameter.hlsl 中被 GetAtmosphereParameter() 读取
        private void SetGlobalAtmosphereParameters(CommandBuffer cmd)
        {
            // 获取当前大气配置的局部引用
            // 简化后续代码书写
            AtmosphereSettings s = m_AtmosphereSettings;

            // 设置海平面高度
            cmd.SetGlobalFloat(SeaLevelId, s.SeaLevel);

            // 设置星球半径
            cmd.SetGlobalFloat(PlanetRadiusId, s.PlanetRadius);

            // 设置大气层高度
            cmd.SetGlobalFloat(AtmosphereHeightId, s.AtmosphereHeight);


            // 设置太阳光强度
            cmd.SetGlobalFloat(SunLightIntensityId, s.SunLightIntensity);

            // 设置太阳光颜色
            cmd.SetGlobalColor(SunLightColorId, s.SunLightColor);

            // 设置太阳圆盘角度
            cmd.SetGlobalFloat(SunDiskAngleId, s.SunDiskAngle);


            // 设置 Rayleigh 散射强度缩放
            cmd.SetGlobalFloat(RayleighScatteringScaleId, s.RayleighScatteringScale);

            // 设置 Rayleigh 散射标高
            cmd.SetGlobalFloat(RayleighScatteringScalarHeightId, s.RayleighScatteringScalarHeight);


            // 设置 Mie 散射强度缩放
            cmd.SetGlobalFloat(MieScatteringScaleId, s.MieScatteringScale);

            // 设置 Mie 各向异性参数
            cmd.SetGlobalFloat(MieAnisotropyId, s.MieAnisotropy);

            // 设置 Mie 散射标高
            cmd.SetGlobalFloat(MieScatteringScalarHeightId, s.MieScatteringScalarHeight);


            // 设置臭氧吸收强度缩放
            cmd.SetGlobalFloat(OzoneAbsorptionScaleId, s.OzoneAbsorptionScale);

            // 设置臭氧层中心高度
            cmd.SetGlobalFloat(OzoneLevelCenterHeightId, s.OzoneLevelCenterHeight);

            // 设置臭氧层宽度
            cmd.SetGlobalFloat(OzoneLevelWidthId, s.OzoneLevelWidth);


            // 设置 Aerial Perspective 最大距离
            cmd.SetGlobalFloat(AerialPerspectiveDistanceId, s.AerialPerspectiveDistance);

            // 设置 Aerial Perspective 体素尺寸
            // x = 单个 slice 宽度
            // y = 单个 slice 高度
            // z = 距离 slice 数量
            // w = 预留
            cmd.SetGlobalVector(
                AerialPerspectiveVoxelSizeId,
                new Vector4(
                    m_Settings.aerialPerspectiveSliceWidth,
                    m_Settings.aerialPerspectiveSliceHeight,
                    m_Settings.aerialPerspectiveSliceCount,
                    0.0f
                )
            );
        }


        // Scene View 调试绘制函数
        // 从 AerialPerspective LUT 的第一个 slice 读回数据，并画出调试线
        private void DrawSceneViewDebug(Camera camera)
        {
            // 如果 AerialPerspective LUT 或读回纹理不存在，则无法调试，直接返回
            if (m_AerialPerspectiveLut == null || m_AerialPerspectiveReadback == null)
                return;

            // 保存当前激活的 RenderTexture
            // 因为 ReadPixels 依赖 RenderTexture.active
            RenderTexture oldActive = RenderTexture.active;

            // 将当前激活 RT 切换为 AerialPerspective LUT
            // 后续 ReadPixels 会从这张 RT 读取像素
            RenderTexture.active = m_AerialPerspectiveLut;

            // 从 AerialPerspective LUT 左下角读取一个 slice 大小的区域
            // 当前只读取第 0 个 slice，而不是整个 atlas
            m_AerialPerspectiveReadback.ReadPixels(
                new Rect(
                    0,
                    0,
                    m_Settings.aerialPerspectiveSliceWidth,
                    m_Settings.aerialPerspectiveSliceHeight
                ),
                0,
                0
            );

            // 将 ReadPixels 结果应用到 CPU Texture2D
            // 参数 false 表示不更新 mipmap，第二个 false 表示纹理仍可读
            m_AerialPerspectiveReadback.Apply(false, false);

            // 恢复之前的 RenderTexture.active
            // 避免影响 Unity 后续渲染流程
            RenderTexture.active = oldActive;

            // 获取当前相机的世界坐标
            // Debug.DrawLine 会从这个位置开始画线
            Vector3 cameraPos = camera.transform.position;

            // 获取 CPU 读回纹理第 0 mip 的像素数据
            // Vector4 对应 RGBAFloat 数据
            var data = m_AerialPerspectiveReadback.GetPixelData<Vector4>(0);

            // 初始化线性索引
            // 用于遍历一维像素数组
            int index = 0;

            // 遍历 slice 高度方向
            for (int y = 0; y < m_Settings.aerialPerspectiveSliceHeight; y++)
            {
                // 遍历 slice 宽度方向
                for (int x = 0; x < m_Settings.aerialPerspectiveSliceWidth; x++)
                {
                    // 读取当前像素数据，并让 index 自增
                    // 修复原代码一直读取 data[0] 的问题
                    Vector4 d4 = data[index++];

                    // 注意：
                    // AerialPerspectiveLut.rgb 实际含义是 inScattering，不是方向。
                    // 这里只保留为调试显示，不能当成真实 viewDir。

                    // 将 RGB 构造成 Vector3
                    // 这里用于可视化 LUT 数据强度或方向式调试
                    Vector3 dirOrColor = new Vector3(d4.x, d4.y, d4.z);

                    // 在 Scene View 中绘制调试线
                    // 起点是相机位置，终点是相机位置加上 dirOrColor * 100
                    Debug.DrawLine(cameraPos, cameraPos + dirOrColor * 100.0f, Color.cyan);
                }
            }
        }


        // 释放该 Pass 持有的所有 GPU / CPU 资源
        // RendererFeature Dispose 时会调用
        public void Dispose()
        {
            // 释放 SkyView LUT RT
            ReleaseRenderTexture(ref m_SkyViewLut);

            // 释放 Transmittance LUT RT
            ReleaseRenderTexture(ref m_TransmittanceLut);

            // 释放 MultiScattering LUT RT
            ReleaseRenderTexture(ref m_MultiScatteringLut);

            // 释放 AerialPerspective LUT RT
            ReleaseRenderTexture(ref m_AerialPerspectiveLut);

            // 如果 CPU 读回纹理存在
            if (m_AerialPerspectiveReadback != null)
            {
                // 销毁 CPU 读回纹理
                DestroyObject(m_AerialPerspectiveReadback);

                // 清空引用，避免悬空引用
                m_AerialPerspectiveReadback = null;
            }
        }


        // 释放 RenderTexture 的工具函数
        // 使用 ref 可以在函数内部把外部引用置空
        private static void ReleaseRenderTexture(ref RenderTexture rt)
        {
            // 如果 RT 为空，说明没有资源需要释放
            if (rt == null)
                return;

            // 释放 GPU RenderTexture 资源
            rt.Release();

            // 销毁 Unity Object
            // 编辑器模式下用 DestroyImmediate，运行时用 Destroy
            DestroyObject(rt);

            // 将引用置空
            rt = null;
        }


        // 根据当前是否处于运行时，选择正确的销毁方式
        private static void DestroyObject(UnityEngine.Object obj)
        {
            // 如果对象为空，不需要销毁
            if (obj == null)
                return;

            // 如果游戏正在运行
            if (Application.isPlaying)
            {
                // 运行时使用 Destroy
                // Destroy 会在当前帧末尾安全销毁对象
                UnityEngine.Object.Destroy(obj);
            }
            else
            {
                // 编辑器非运行状态使用 DestroyImmediate
                // 立即销毁对象，避免编辑器资源残留
                UnityEngine.Object.DestroyImmediate(obj);
            }
        }
    }


    // 在 Inspector 中显示 Settings 分组
    [Header("Settings")]

    // RendererFeature 的配置对象
    // 包含 LUT 尺寸、Pass 插入时机、Debug 开关
    public FeatureSettings settings = new FeatureSettings();


    // 在 Inspector 中显示 Materials 分组
    [Header("Materials")]

    // SkyView LUT 材质
    // 应使用 CasualAtmosphere/SkyViewLut Shader
    public Material skyViewLutMaterial;

    // Transmittance LUT 材质
    // 应使用 CasualAtmosphere/TransmittanceLut Shader
    public Material transmittanceLutMaterial;

    // MultiScattering LUT 材质
    // 应使用 CasualAtmosphere/MultiScatteringLut Shader
    public Material multiScatteringLutMaterial;

    // AerialPerspective LUT 材质
    // 应使用 CasualAtmosphere/AerialPerspectiveLut Shader
    public Material aerialPerspectiveLutMaterial;


    // 在 Inspector 中显示 Atmosphere 分组
    [Header("Atmosphere")]

    // 大气参数配置资产
    // 应拖入 AtmosphereSettings ScriptableObject
    public AtmosphereSettings atmosphereSettings;


    // 当前 RendererFeature 持有的 RenderPass 实例
    // Unity 会在 AddRenderPasses 中把它加入渲染队列
    private AtmosphereLutPass m_Pass;


    // Create 是 ScriptableRendererFeature 的初始化函数
    // 当 RendererFeature 被创建、启用或重新加载时调用
    public override void Create()
    {
        // 创建大气 LUT 生成 Pass
        // 将 settings 传入，让 Pass 能读取 LUT 尺寸和 Debug 设置
        m_Pass = new AtmosphereLutPass(settings)
        {
            // 设置 Pass 插入渲染流程的位置
            // 使用对象初始化器写法直接给 renderPassEvent 赋值
            renderPassEvent = settings.renderPassEvent
        };
    }


    // AddRenderPasses 会在每个相机渲染前被 URP 调用
    // 用于把自定义 Pass 加入当前相机的渲染队列
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        // 如果 Pass 没有创建，直接返回
        if (m_Pass == null)
            return;

        // 如果必要资源不完整，直接返回
        // 避免材质或 AtmosphereSettings 没拖入时导致报错
        if (!ValidateResources())
            return;

        // 每帧同步当前 settings 中的 renderPassEvent
        // 这样 Inspector 修改插入时机后可以生效
        m_Pass.renderPassEvent = settings.renderPassEvent;

        // 将当前 RendererFeature 上配置的材质和参数传入 Pass
        // Pass 执行时会使用这些资源生成 LUT
        m_Pass.Setup(
            skyViewLutMaterial,
            transmittanceLutMaterial,
            multiScatteringLutMaterial,
            aerialPerspectiveLutMaterial,
            atmosphereSettings
        );

        // 将 Pass 加入 URP Renderer 渲染队列
        // 到达 renderPassEvent 指定时机时，URP 会调用 Pass.Execute()
        renderer.EnqueuePass(m_Pass);
    }


    // RendererFeature 被销毁或禁用时调用
    // 用于释放手动创建的 GPU / CPU 资源
    protected override void Dispose(bool disposing)
    {
        // 如果 Pass 存在，则释放其内部资源
        m_Pass?.Dispose();

        // 清空 Pass 引用
        m_Pass = null;
    }


    // 检查 Inspector 中必须配置的资源是否完整
    // 不完整则不执行 Pass，避免运行时空引用异常
    private bool ValidateResources()
    {
        // 如果 settings 为空，说明配置对象丢失
        if (settings == null)
            return false;

        // 如果大气参数配置为空，Shader 无法获得必要参数
        if (atmosphereSettings == null)
            return false;

        // 如果 SkyView LUT 材质为空，无法生成 _skyViewLut
        if (skyViewLutMaterial == null)
            return false;

        // 如果 Transmittance LUT 材质为空，无法生成 _transmittanceLut
        if (transmittanceLutMaterial == null)
            return false;

        // 如果 MultiScattering LUT 材质为空，无法生成 _multiScatteringLut
        if (multiScatteringLutMaterial == null)
            return false;

        // 如果 AerialPerspective LUT 材质为空，无法生成 _aerialPerspectiveLut
        if (aerialPerspectiveLutMaterial == null)
            return false;

        // 所有必要资源都存在，返回 true
        return true;
    }
}