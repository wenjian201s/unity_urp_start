using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
    // 继承自 ScriptableRendererFeature，这是 URP 允许开发者插入自定义渲染管线的唯一入口
public class CharacterAlphaClipRendererFeature : ScriptableRendererFeature
{
    

    // 声明一个具体的渲染 Pass 实例
    public CharacterAlphaClipRenderPass renderPass;
    
    // 暴露给 Inspector 面板的材质，即你之前写的那个 CharacterAlphaClip Shader 生成的材质
    public Material alphaClipMaterial;

    /// <inheritdoc/> // 当管线初始化或设置更改时调用一次
    public override void Create()
    {
        // 实例化 Pass，把材质传进去
        renderPass = new CharacterAlphaClipRenderPass(alphaClipMaterial);
        
        // 【关键】设置 Pass 的执行时机：在渲染完所有不透明物体之后执行
        // 这保证了此时场景里的地形、建筑等都已经画好了，深度已经准备就绪
        renderPass.renderPassEvent = RenderPassEvent.AfterRenderingOpaques;
    }

    // 每一帧渲染前，URP 会调用这个方法，让你把 Pass 加入执行队列
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        // 将我们自定义的 Pass 加入到 URP 的渲染队列中
        renderer.EnqueuePass(renderPass);
    }
}


