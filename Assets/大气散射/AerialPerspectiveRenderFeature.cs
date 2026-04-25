using UnityEngine;
using System;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

/// <summary>
/// Unity 2022.3 / URP 14 兼容版 Aerial Perspective 后处理 Renderer Feature。
/// 
/// 作用：
/// 1. 在相机颜色缓冲上执行一次 Aerial Perspective 后处理。
/// 2. 先把相机颜色复制到临时 RT。
/// 3. 使用 AerialPerspective Material 处理临时 RT。
/// 4. 再把处理结果写回相机颜色缓冲。
/// 
/// 注意：
/// AerialPerspective Shader 通过 URP Blitter 绑定的 _BlitTexture 读取当前屏幕颜色。
/// </summary>
public class AerialPerspectiveRenderFeature : ScriptableRendererFeature
{
    [Serializable]
    public class FeatureSettings
    {
        public Material aerialPerspectiveMaterial;
        public RenderPassEvent renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
    }

    /// <summary>
    /// 真正执行后处理的自定义 RenderPass。
    /// </summary>
    class CustomRenderPass : ScriptableRenderPass
    {
        // 当前相机颜色缓冲。
        // 在 Unity 2022.3 / URP 14 中应通过 SetupRenderPasses 传入。
        private RTHandle m_Source;

        // 临时颜色 RT。
        // 用于存放 Aerial Perspective 处理后的中间结果。
        private RTHandle m_TempColorTexture;

        // Aerial Perspective 后处理材质。
        // 该材质应使用你的 Shader "CasualAtmosphere/AerialPerspective"。
        private Material m_Material;

        // ProfilingSampler 用于 Frame Debugger / Profiler 中显示 Pass 名称。
        private readonly ProfilingSampler m_ProfilingSampler = new ProfilingSampler("Aerial Perspective Pass");

        /// <summary>
        /// 构造函数。
        /// </summary>
        public CustomRenderPass()
        {
            // 你的 AerialPerspective Shader 会采样 _CameraDepthTexture。
            // ConfigureInput(Depth) 会告诉 URP：这个 Pass 需要相机深度纹理。
            ConfigureInput(ScriptableRenderPassInput.Depth);
        }

        /// <summary>
        /// 每帧由 RendererFeature 传入当前相机颜色缓冲和材质。
        /// </summary>
        public void Setup(RTHandle source, Material material)
        {
            // 保存当前相机颜色缓冲。
            m_Source = source;

            // 保存后处理材质。
            m_Material = material;
        }

        /// <summary>
        /// 在相机渲染前配置临时 RT。
        /// </summary>
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            // 如果没有材质或源纹理，则不需要创建临时 RT。
            if (m_Material == null || m_Source == null)
                return;

            // 获取当前相机目标描述。
            // 这个描述包含相机颜色缓冲的宽、高、HDR 格式、MSAA 等信息。
            RenderTextureDescriptor descriptor = renderingData.cameraData.cameraTargetDescriptor;

            // 后处理临时 RT 不需要深度缓冲。
            descriptor.depthBufferBits = 0;

            // 后处理临时 RT 不需要 MSAA。
            // 屏幕后处理一般直接处理已经解析后的颜色纹理。
            descriptor.msaaSamples = 1;

            // 创建或按需重建临时 RTHandle。
            // 当分辨率、HDR 格式等变化时，RenderingUtils 会自动释放旧 RT 并创建新 RT。
            RenderingUtils.ReAllocateIfNeeded(
                ref m_TempColorTexture,
                descriptor,
                FilterMode.Bilinear,
                TextureWrapMode.Clamp,
                name: "_TempAerialPerspectiveRT"
            );
        }

        /// <summary>
        /// 执行 Aerial Perspective 后处理。
        /// </summary>
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            // 缺少材质、源 RT 或临时 RT 时直接跳过，避免报错。
            if (m_Material == null || m_Source == null || m_TempColorTexture == null)
                return;

            // Preview 相机通常来自 Inspector 预览窗口，不需要执行后处理。
            if (renderingData.cameraData.cameraType == CameraType.Preview)
                return;

            // 从命令缓冲池获取 CommandBuffer。
            CommandBuffer cmd = CommandBufferPool.Get("Aerial Perspective");

            // 开启 ProfilingScope，方便在 Frame Debugger / Profiler 中定位该 Pass。
            using (new ProfilingScope(cmd, m_ProfilingSampler))
            {
                // 第一步：
                // 从相机颜色缓冲 m_Source 读取颜色，
                // 使用 AerialPerspective 材质的 pass 0 处理，
                // 输出到临时 RT m_TempColorTexture。
                //
                // 你的 Shader 只有一个 Pass，因此 shaderPass 使用 0。
                Blitter.BlitCameraTexture(
                    cmd,
                    m_Source,
                    m_TempColorTexture,
                    m_Material,
                    0
                );

                // 第二步：
                // 将处理后的临时 RT 拷贝回相机颜色缓冲。
                //
                // 这一步不使用材质，只是单纯把结果写回 camera color target。
                Blitter.BlitCameraTexture(
                    cmd,
                    m_TempColorTexture,
                    m_Source
                );
            }

            // 提交 CommandBuffer。
            context.ExecuteCommandBuffer(cmd);

            // 释放 CommandBuffer。
            CommandBufferPool.Release(cmd);
        }

        /// <summary>
        /// RendererFeature 销毁时释放临时 RT。
        /// </summary>
        public void Dispose()
        {
            // 释放 RTHandle。
            if (m_TempColorTexture != null)
            {
                m_TempColorTexture.Release();
                m_TempColorTexture = null;
            }
        }
    }

    [Header("Settings")]
    public FeatureSettings settings = new FeatureSettings();

    // 兼容旧版本脚本里直接暴露的字段，避免已经在 Inspector 里拖好的材质丢失。
    [SerializeField, HideInInspector]
    private Material m_AerialPerspectiveMaterial;

    // 当前 RendererFeature 持有的自定义 Pass。
    private CustomRenderPass m_ScriptablePass;

    /// <summary>
    /// 创建 RendererFeature 时调用。
    /// </summary>
    public override void Create()
    {
        // 创建自定义后处理 Pass。
        m_ScriptablePass = new CustomRenderPass();

        // 设置 Pass 插入时机。
        //
        // BeforeRenderingPostProcessing：
        // 表示在 URP 内置后处理之前执行。
        // 此时场景颜色、天空盒和深度纹理通常已经可用。
        m_ScriptablePass.renderPassEvent = settings != null
            ? settings.renderPassEvent
            : RenderPassEvent.BeforeRenderingPostProcessing;
    }

    /// <summary>
    /// Unity 2022.3 / URP 14 推荐在这里访问 cameraColorTargetHandle。
    /// 
    /// 原因：
    /// AddRenderPasses 调用时，渲染目标可能还没完全分配；
    /// SetupRenderPasses 调用时，Renderer 的相机颜色目标已经准备好。
    /// </summary>
    public override void SetupRenderPasses(ScriptableRenderer renderer, in RenderingData renderingData)
    {
        Material material = GetAerialPerspectiveMaterial();

        // 如果 Pass 或材质不存在，直接跳过。
        if (m_ScriptablePass == null || material == null)
            return;

        // Preview 相机跳过。
        if (renderingData.cameraData.cameraType == CameraType.Preview)
            return;

        // 把当前相机颜色缓冲传给 Pass。
        m_ScriptablePass.Setup(
            renderer.cameraColorTargetHandle,
            material
        );
    }

    /// <summary>
    /// 每个相机渲染前，把自定义 Pass 加入 URP 渲染队列。
    /// </summary>
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        Material material = GetAerialPerspectiveMaterial();

        // 如果 Pass 或材质不存在，直接跳过。
        if (m_ScriptablePass == null || material == null)
            return;

        // Preview 相机跳过。
        if (renderingData.cameraData.cameraType == CameraType.Preview)
            return;

        m_ScriptablePass.renderPassEvent = settings != null
            ? settings.renderPassEvent
            : RenderPassEvent.BeforeRenderingPostProcessing;

        // 将 Aerial Perspective Pass 加入 URP Renderer。
        renderer.EnqueuePass(m_ScriptablePass);
    }

    /// <summary>
    /// RendererFeature 被销毁或禁用时调用。
    /// </summary>
    protected override void Dispose(bool disposing)
    {
        // 释放 Pass 内部临时 RT。
        m_ScriptablePass?.Dispose();

        // 清空引用。
        m_ScriptablePass = null;
    }

    private Material GetAerialPerspectiveMaterial()
    {
        if (settings != null && settings.aerialPerspectiveMaterial != null)
            return settings.aerialPerspectiveMaterial;

        return m_AerialPerspectiveMaterial;
    }
}
