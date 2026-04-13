using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class CharacterAlphaClipRenderPass : ScriptableRenderPass
{
    private Material alphaClipMat;
    private FilteringSettings filteringSettings;
    private ShaderTagId shaderTagId = new ShaderTagId("UniversalForward");
    
    // URP 2022 推荐使用 RTHandle 管理渲染纹理
    private RTHandle playerRT;
    private const string ProfilerTag = "Character Alpha Clip Pass";

    public CharacterAlphaClipRenderPass(Material alphaClipMaterial)
    {
        this.alphaClipMat = alphaClipMaterial;
        
        // 过滤出 Player 层级
        filteringSettings = new FilteringSettings(RenderQueueRange.opaque, LayerMask.GetMask("Player"));
        
        // 渲染时机：通常放在不透明物体或透明物体渲染之后
        renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
    }

    public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
    {
        var descriptor = renderingData.cameraData.cameraTargetDescriptor;
        // 颜色图不需要深度缓冲
        descriptor.depthBufferBits = 0; 
        descriptor.msaaSamples = 1;
        descriptor.graphicsFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.R8G8B8A8_UNorm;

        // 分配临时 Render Target
        RenderingUtils.ReAllocateIfNeeded(ref playerRT, descriptor, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_PlayerRT");
    }

    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        if (alphaClipMat == null) return;

        CommandBuffer cmd = CommandBufferPool.Get();
        using (new ProfilingScope(cmd, new ProfilingSampler(ProfilerTag)))
        {
            var cameraData = renderingData.cameraData;
            var cameraColorTarget = cameraData.renderer.cameraColorTargetHandle;
            var cameraDepthTarget = cameraData.renderer.cameraDepthTargetHandle;

            // 1. 设置渲染目标为临时 RT (playerRT)，并绑定相机的深度缓冲用于遮挡剔除
            CoreUtils.SetRenderTarget(cmd, playerRT, cameraDepthTarget);
            
            // ==========================================
            // 🚨 解决重影的核心代码 🚨
            // 必须清除临时 RT 的颜色为全透明。否则上一帧的角色像素会残留，导致移动时严重拖尾！
            CoreUtils.ClearRenderTarget(cmd, ClearFlag.Color, Color.clear);
            // ==========================================

            // 2. 绘制 Player 层物体
            var sortingCriteria = cameraData.defaultOpaqueSortFlags;
            var drawingSettings = CreateDrawingSettings(shaderTagId, ref renderingData, sortingCriteria);
            // 兼容可能使用 Unlit 材质的角色
            drawingSettings.SetShaderPassName(1, new ShaderTagId("SRPDefaultUnlit"));
            
            // 提交前面的设置命令
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();

            // 执行绘制
            context.DrawRenderers(renderingData.cullResults, ref drawingSettings, ref filteringSettings);

            // 3. 将 PlayerRT 通过 Material Blit 回主相机的 Color Buffer
            // Blitter 是 URP 2022 中推荐的全屏后处理混合方式
            Blitter.BlitCameraTexture(cmd, playerRT, cameraColorTarget, alphaClipMat, 0);
        }

        context.ExecuteCommandBuffer(cmd);
        CommandBufferPool.Release(cmd);
    }

    // 释放 RT 资源
    public void Dispose()
    {
        playerRT?.Release();
    }
}