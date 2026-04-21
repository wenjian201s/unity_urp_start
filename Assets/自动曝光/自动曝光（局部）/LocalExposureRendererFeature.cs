// 【作用】引入Unity引擎核心命名空间
// 【原理】提供基础的Unity API支持。
using UnityEngine;

// 【作用】引入URP渲染管线专属命名空间
// 【原理】包含 ScriptableRendererFeature（自定义渲染特征基类）、ScriptableRenderer（渲染器）等核心类，是编写URP管线的必备环境。
using UnityEngine.Rendering.Universal;

// 【作用】声明名为 LocalExposureRendererFeature 的公开类，继承自 ScriptableRendererFeature
// 【原理】继承此基类使得该脚本可以作为一个“插件”直接挂载到 URP 的 Renderer 配置面板中，成为渲染管线的一个扩展环节。
public class LocalExposureRendererFeature : ScriptableRendererFeature
{
    // 【作用】声明一个公开的配置类实例
    // 【原理】用于在Unity的Inspector面板中暴露参数（通常包含局部曝光专用的ComputeShader引用、双边滤波半径等），实现代码与配置数据的分离。
    public LocalExposureRenderSettings localExposureRenderSettings;

    // 【作用】声明一个私有的渲染Pass实例
    // 【原理】对应具体的局部曝光执行逻辑类。设为私有是因为外部（如RendererFeature）不需要直接调用它的方法，只负责管理它的生命周期和入队。
    private LocalExposureRenderPass localExposureRenderPass;

    // 【作用】重写基类的 Create 方法
    // 【原理】当此Feature被添加到Renderer上，或者Unity编辑器编译刷新时执行一次。用于初始化核心资源。
    public override void Create()
    {
        // 【作用】实例化局部曝光的具体Pass，并将配置数据传入
        // 【原理】将面板上的配置参数传递给Pass，让Pass知道自己要执行哪些具体的计算逻辑和操作哪些纹理。
        localExposureRenderPass = new LocalExposureRenderPass(localExposureRenderSettings);
        
        // 【作用】设置该Pass在渲染管线中的执行时机
        // 【原理】RenderPassEvent.AfterRenderingTransparents 表示“在渲染完所有透明物体之后执行”。
        // 局部曝光属于屏幕后处理，必须等场景中所有不透明和透明物体（比如玻璃、粒子特效）都画完之后，才能获取完整的屏幕色彩进行双边滤波和亮度提亮/压暗计算。
        localExposureRenderPass.renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
    }

    // 【作用】重写基类的 AddRenderPasses 方法
    // 【原理】Unity每渲染一帧（每个相机）都会调用此方法，用于决定当前帧是否要把这个Pass加入执行队列。
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        // 【作用】将初始化好的局部曝光Pass加入当前帧的渲染队列
        // 【原理】renderer.EnqueuePass 是触发实际工作的关键指令。调用后，URP会在上述设定的 AfterRenderingTransparents 时机，调用 LocalExposureRenderPass 里面的 Execute 方法，进而驱动GPU执行你之前写的双边滤波和局部曝光Compute Shader。
        renderer.EnqueuePass(localExposureRenderPass);
    }
}