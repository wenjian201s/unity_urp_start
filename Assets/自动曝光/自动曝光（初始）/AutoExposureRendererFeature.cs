// 【作用】引入Unity引擎核心命名空间
// 【原理】提供基础的Unity API支持。
using UnityEngine;

// 【作用】引入URP渲染管线专属命名空间
// 【原理】包含在URP下编写自定义渲染功能所需的核心基类，如 ScriptableRendererFeature 和 ScriptableRenderPass。
using UnityEngine.Rendering.Universal;

// 【作用】声明一个名为 AutoExposureRendererFeature 的公开类，并继承自 ScriptableRendererFeature
// 【原理】继承自 ScriptableRendererFeature 是告诉Unity：“这是一个可以添加到URP Renderer身上的自定义渲染步骤”。它本身不执行具体的绘制或计算，而是充当一个“管理者”和“挂载点”。
public class AutoExposureRendererFeature : ScriptableRendererFeature
{
    // 【作用】声明一个公开的配置类实例
    // 【原理】这个类（虽然在当前代码块未展示，但通常包含ComputeShader引用、Texture目标等）用于在Unity Inspector面板中配置该渲染特征的参数，实现代码与数据的分离。
    public AutoExposureRenderSettings autoExposureRenderSettings;

    // 【作用】声明一个私有的渲染Pass实例
    // 【原理】RenderPass才是真正包含具体执行逻辑（比如执行前面写的那些Compute Shader）的类。这里保持私有，因为外部不需要直接访问它。
    private AutoExposureRenderPass autoExposureRenderPass;

    // 【作用】重写基类的 Create 方法
    // 【原理】当这个 RendererFeature 被添加到URP Renderer上，或者Unity编译刷新时，会调用一次这个方法。它用于初始化资源，而不是每帧执行。
    public override void Create()
    {
        // 【作用】实例化具体的渲染Pass，并将配置数据传入
        // 【原理】将外部的设置（如计算着色器引用）传递给Pass，让Pass知道自己要执行什么计算、操作什么纹理。
        autoExposureRenderPass = new AutoExposureRenderPass(autoExposureRenderSettings);
        
        // 【作用】设置该Pass在渲染管线中的执行时机
        // 【原理】RenderPassEvent.AfterRenderingTransposables 表示“在渲染完所有透明物体之后执行”。
        // 自动曝光本质上是一个屏幕后处理效果，必须等场景中所有不透明和透明物体（如玻璃、粒子）都画到屏幕上之后，才能读取完整的屏幕颜色进行亮度统计和曝光应用。
        autoExposureRenderPass.renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
    }

    // 【作用】重写基类的 AddRenderPasses 方法
    // 【原理】Unity每渲染一帧（每个相机）都会调用这个方法。它的职责是决定在当前帧的渲染队列中，是否要把我们的 Pass 加进去。
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        // 【作用】将初始化好的 Pass 加入到当前帧的执行队列中
        // 【原理】renderer.EnqueuePass 是触发实际工作的关键。调用后，URP会在前面设定的 AfterRenderingTransparents 时机，自动调用 AutoExposureRenderPass 里面的 Execute 方法，从而执行你在Compute Shader里写的那些代码。
        renderer.EnqueuePass(autoExposureRenderPass);
    }
}