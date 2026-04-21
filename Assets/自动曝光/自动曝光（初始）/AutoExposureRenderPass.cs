// // 【作用】引入系统运行时互操作服务命名空间
// // 【原理】提供 [StructLayout] 和 Marshal.SizeOf 等功能，这是将C#结构体精确映射到C++/GPU显存布局（字节对齐）的必备工具。
// using System.Runtime.InteropServices;
// // 【作用】引入Unity基础命名空间
// using UnityEngine;
// using UnityEngine.Experimental.Rendering.RenderGraphModule;
// // 【作用】引入Unity通用渲染命名空间
// using UnityEngine.Rendering;
// // 【作用】引入URP的Render Graph核心模块
// // 【原理】Render Graph是现代Unity用于管理复杂渲染管线内存和依赖关系的API，能自动处理中间纹理的创建与复用。
// using UnityEngine.Rendering.RenderGraphModule;
// // 【作用】引入Render Graph的工具类模块
// using UnityEngine.Rendering.RenderGraphModule.Util;
// // 【作用】引入URP专属命名空间
// using UnityEngine.Rendering.Universal;
// // 【作用】静态引入RenderGraphUtils类，简化后续代码书写
// // 【原理】这样可以直接调用类内的方法（如某些扩展方法），而不需要写类名前缀。
// using static UnityEngine.Rendering.RenderGraphModule.Util.RenderGraphUtils;
//
// // 【作用】声明自动曝光渲染Pass，继承自ScriptableRenderPass
// // 【原理】继承该类意味着它可以被前面的 RendererFeature 放入URP的执行队列中，负责单次具体的渲染/计算任务。
// public class AutoExposureRenderPass : ScriptableRenderPass
// {
//     // 【作用】保存外部传入的配置实例（如ComputeShader引用等）
//     private AutoExposureRenderSettings settings;
//     
//     // 【作用】定义CPU端的读写参数数组（长度为1）
//     // 【原理】作为CPU和GPU之间传输数据的中间载体。只有1个元素是因为全屏统计结果只需要一组数据。
//     private RWParameters[] rwParameters;
//     // 【作用】定义CPU端的只读参数数组
//     private RParameters[] rParameters;
//     
//     // 【作用】声明对应上述数组的GPU ComputeBuffer（可读写）
//     // 【原理】对应HLSL中的 RWStructuredBuffer<RWParameters>。GPU会在显存中开辟一块结构化缓冲区。
//     private ComputeBuffer rwParameterBuffer;
//     // 【作用】声明对应上述数组的GPU ComputeBuffer（只读）
//     // 【原理】对应HLSL中的 StructuredBuffer<RParameters>。
//     private ComputeBuffer rParameterBuffer;
//     
//     // 【作用】定义Compute Shader的线程组大小，与HLSL中的 [numthreads(16,16,1)] 保持严格一致
//     private Vector3Int numThreads = new Vector3Int(16, 16, 1);
//     // 【作用】声明X轴需要调度的线程组数量
//     private int threadGroupsX;
//     // 【作用】声明Y轴需要调度的线程组数量
//     private int threadGroupsY;
//
//     // 【作用】强制指定C#结构体在内存中的布局为顺序排列
//     // 【原理】极其重要！默认情况下C#会自动优化结构体内存对齐（可能插入空字节）。加上此特性后，C#结构的内存字节排布将与HLSL中的结构体完全一致，防止GPU读取数据时发生错位和乱码。
//     [StructLayout(LayoutKind.Sequential)]
//     public struct RWParameters
//     {
//         public uint importance;
//         public uint luminance;
//         public float historyEV;
//         public float exposure;
//     }
//
//     // 【作用】同上，定义只读参数的内存布局
//     [StructLayout(LayoutKind.Sequential)]
//     public struct RParameters
//     {
//         public float deltaTime;
//     }
//
//     // 【作用】定义一个内部类，用于向Render Graph的执行函数传递参数
//     // 【原理】Render Graph采用延迟执行机制。Lambda表达式不能直接捕获外部变量（如settings），必须将需要的数据打包进这个PassData类中传递给执行函数。
//     public class PassData
//     {
//         public ComputeShader computeShader; // 要执行的算图shader
//         public TextureHandle screenTexture;  // Render Graph中的纹理句柄（代表屏幕图像）
//     }
//
//     // 【作用】构造函数，在RendererFeature中创建此Pass时调用
//     public AutoExposureRenderPass(AutoExposureRenderSettings autoExposureRenderSettings)
//     {
//         // 【作用】保存配置引用
//         settings = autoExposureRenderSettings;
//
//         // 【作用】初始化CPU端数组
//         rwParameters = new RWParameters[1];
//         // 【作用】在GPU创建结构化缓冲区
//         // 【原理】参数1：元素数量(1)；参数2：单个元素的字节大小（通过Marshal计算，保证精准）；参数3：指定为Structured类型。
//         rwParameterBuffer = new ComputeBuffer(1, Marshal.SizeOf(typeof(RWParameters)), ComputeBufferType.Structured);
//         // 【作用】将CPU端的数据（初始为0）拷贝到GPU缓冲区
//         rwParameterBuffer.SetData(rwParameters);
//
//         // 【作用】同上，初始化只读参数的CPU数组和GPU缓冲区
//         rParameters = new RParameters[1];
//         rParameterBuffer = new ComputeBuffer(1, Marshal.SizeOf(typeof(RParameters)), ComputeBufferType.Structured);
//         rParameterBuffer.SetData(rParameters);
//
//         // 【作用】计算覆盖整个屏幕需要的线程组数量
//         // 【原理】屏幕像素数 / 每个线程组处理的像素数(16)。使用 Mathf.CeilToInt 向上取整，确保屏幕边缘多出来的零星像素也能被一个线程组处理到。
//         threadGroupsX = Mathf.CeilToInt(Screen.width / (float)numThreads.x);
//         threadGroupsY = Mathf.CeilToInt(Screen.height / (float)numThreads.y);
//     }
//
//     // 【作用】重写Render Graph的记录方法（每帧由管线调用）
//     // 【原理】这里不执行真正的渲染，而是“向图纸添加节点”，声明我需要什么资源，我做什么操作。
//     public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
//     {
//         // 【作用】从帧数据中获取当前相机的信息
//         UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
//         // 【作用】从帧数据中获取当前管线的资源（如当前屏幕的RenderTarget）
//         UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
//
//         // 【作用】克隆一个当前相机的渲染纹理描述符
//         RenderTextureDescriptor descriptor = cameraData.cameraTargetDescriptor;
//         // 【作用】关闭MSAA（多重采样抗锯齿）
//         // 【原理】Compute Shader的UAV（RWTexture2D）通常不支持直接读写带有MSAA的纹理。必须使用非MSAA纹理。
//         descriptor.msaaSamples = 1;
//         // 【作用】开启随机写入权限
//         // 【原理】极其关键！如果不开启，这张纹理在GPU端只能被采样，不能被Compute Shader的 _ScreenTexture[id.xy] = xxx 写入。
//         descriptor.enableRandomWrite = true;
//         // 【作用】设置为半精度浮点格式
//         // 【原理】ARGBHalf对于HDR颜色和曝光值来说精度足够，且比全精度(RGBAFloat)节省一半的显存带宽。
//         descriptor.depthStencilFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.None; // 不需要深度缓冲
//         
//         // 【作用】通过Render Graph API创建一张临时的纹理
//         // 【原理】第二个参数false表示这不是临时的 transient 资源（因为我们要多次读写它）。Render Graph会自动管理这张图的生命周期，不用我们手动Release。
//         TextureHandle screenTexture = UniversalRenderer.CreateRenderGraphTexture(renderGraph, descriptor, "_ScreenTexture", false);
//         
//         // 【作用】添加一个Blit（拷贝）Pass
//         // 【原理】将URP当前渲染好的画面（activeColorTexture）完整地拷贝到我们刚刚创建的、带有随机写入权限的 screenTexture 中，为后续Compute Shader处理准备数据。
//         renderGraph.AddBlitPass(resourceData.activeColorTexture, screenTexture, Vector2.one, Vector2.zero);
//
//         // 【作用】使用 using 语法开始构建一个 Compute Pass
//         // 【原理】AddComputePass 会向Render Graph注册一个计算节点，并返回一个构建器。using确保在作用域结束时正确结束构建。
//         using (var builder = renderGraph.AddComputePass("Auto Exposure", out PassData passData))
//         {
//             // 【作用】将需要的数据打包进 PassData
//             passData.computeShader = settings.computeShader;
//             passData.screenTexture = screenTexture;
//
//             // 【作用】禁止Render Graph自动剔除这个Pass
//             // 【原理】Render Graph会分析依赖关系，如果它认为某个Pass的结果没被后续使用，就会跳过它。因为我们是在原地上修改纹理，没有显式的“输出”连接，所以必须强制禁止剔除。
//             builder.AllowPassCulling(false);
//             // 【作用】告诉Render Graph，这个Pass会使用（读写）这张纹理
//             // 【原理】让Render Graph生成正确的资源依赖和同步屏障。
//             builder.UseTexture(passData.screenTexture);
//
//             // 【作用】设置该Pass真正执行时的具体逻辑（Lambda延迟执行函数）
//             // 【原理】这个函数内的代码不会在RecordRenderGraph时运行，而是稍后在GPU开始干活时由Render Graph调用。参数 context 提供了操作GPU的命令缓冲区。
//             builder.SetRenderFunc((PassData data, ComputeGraphContext context) =>
//             {
//                 // 【作用】每帧更新CPU端的只读参数（如deltaTime），并推送到GPU
//                 UpdateRParameters();
//
//                 // 获取要执行的Compute Shader和命令缓冲区
//                 ComputeShader computeShader = data.computeShader;
//                 ComputeCommandBuffer ccb = context.cmd;
//
//                 // ========== 1. 执行 AccumulateLuminance Kernel ==========
//                 // 【作用】找到HLSL中对应的Kernel索引
//                 int kernelIndex = computeShader.FindKernel("AccumulateLuminance");
//                 // 【作用】将可读写的屏幕纹理绑定到Shader
//                 ccb.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", data.screenTexture);
//                 // 【作用】将读写缓冲区绑定到Shader
//                 ccb.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer);
//                 // 【作用】派发计算
//                 // 【原理】使用前面算好的线程组数量，让全屏像素并行执行统计。
//                 ccb.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);
//
//                 // ========== 2. 执行 ComputeTargetEV Kernel ==========
//                 kernelIndex = computeShader.FindKernel("ComputeTargetEV");
//                 ccb.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", data.screenTexture);
//                 ccb.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer);
//                 // 【作用】绑定只读缓冲区（传入deltaTime）
//                 ccb.SetComputeBufferParam(computeShader, kernelIndex, "_RParameters", rParameterBuffer);
//                 // 【作用】派发计算
//                 // 【原理】只需1个线程执行一次，算出最终的exposure值。
//                 ccb.DispatchCompute(computeShader, kernelIndex, 1, 1, 1);
//
//                 // ========== 3. 执行 ApplyExposure Kernel ==========
//                 kernelIndex = computeShader.FindKernel("ApplyExposure");
//                 ccb.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", data.screenTexture);
//                 ccb.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer); 
//                 // 【作用】派发计算
//                 // 【原理】再次全屏并行，将算好的exposure乘进每个像素里。
//                 ccb.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);
//                 
//                 // (注：此处代码省略了局部曝光的 BilateralBlur 和 GaussianBlur 的调度，可能被精简了，但执行逻辑同上)
//             });
//         }
//         
//         // 【作用】将我们处理过的纹理句柄重新赋值给管线的最终颜色输出
//         // 【原理】极其关键！如果不做这一步，URP后续的流程（如后处理、UI绘制、最终输出到屏幕）依然会使用原来未处理的图像。赋值后，相当于把我们计算的图“接”回了主渲染管线。
//         resourceData.cameraColor = screenTexture;
//     }
//
//     // 【作用】更新只读参数的辅助方法
//     private void UpdateRParameters()
//     {
//         // 【作用】获取当前帧的时间增量
//         rParameters[0].deltaTime = Time.deltaTime;
//         // 【作用】将新数据推送到GPU显存中
//         // 【原理】确保Compute Shader拿到的 _RParameters 始终是最新一帧的时间。
//         rParameterBuffer.SetData(rParameters);
//     }
// }


using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.Rendering;
// 【作用】移除了6000版本的 RenderGraphModule 引用，2022.3不需要
using UnityEngine.Rendering.Universal;

public class AutoExposureRenderPass : ScriptableRenderPass
{
    private AutoExposureRenderSettings settings;
    
    private RWParameters[] rwParameters;
    private RParameters[] rParameters;
    
    private ComputeBuffer rwParameterBuffer;
    private ComputeBuffer rParameterBuffer;
    
    private Vector3Int numThreads = new Vector3Int(16, 16, 1);
    // 【作用】移除了全局的线程组计算，因为2022.3中应该在Execute时根据实际相机分辨率动态计算，避免编辑器分屏或不同分辨率相机导致错误。
    
    // 【作用】新增：声明用于存储中间屏幕图像的 RTHandle
    // 【原理】在2022.3中，必须手动管理渲染纹理。因为原生的 cameraColorTarget 往往不支持 Compute Shader 的随机写入(UAV)，所以需要创建一张支持UAV的临时纹理来做中转。
    private RTHandle tempScreenTexture;

    // 【作用】强制指定C#结构体内存布局，与GPU对齐（此部分在所有Unity版本通用）
    [StructLayout(LayoutKind.Sequential)]
    public struct RWParameters
    {
        public uint importance;
        public uint luminance;
        public float historyEV;
        public float exposure;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RParameters
    {
        public float deltaTime;
    }

    // 【作用】移除了 PassData 内部类
    // 【原理】2022.3不使用Render Graph的延迟执行机制，可以直接在类中访问成员变量，无需打包传递。

    public AutoExposureRenderPass(AutoExposureRenderSettings autoExposureRenderSettings)
    {
        settings = autoExposureRenderSettings;
        // 【作用】在构造函数中设置Pass的执行时机
        // 【原理】对应6000版本中在Feature里设置的执行节点，保证在不透明和透明物体渲染完后执行。
        this.renderPassEvent = RenderPassEvent.AfterRenderingTransparents;

        rwParameters = new RWParameters[1];
        rwParameterBuffer = new ComputeBuffer(1, Marshal.SizeOf(typeof(RWParameters)), ComputeBufferType.Structured);
        rwParameterBuffer.SetData(rwParameters);

        rParameters = new RParameters[1];
        rParameterBuffer = new ComputeBuffer(1, Marshal.SizeOf(typeof(RParameters)), ComputeBufferType.Structured);
        rParameterBuffer.SetData(rParameters);
    }

    // 【作用】新增：2022.3标准的管线配置回调
    // 【原理】每帧渲染前调用，用于获取当前相机的描述符，并分配我们需要的中转纹理。
    public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
    {
        // 【作用】获取当前相机的渲染纹理描述符
        RenderTextureDescriptor descriptor = renderingData.cameraData.cameraTargetDescriptor;
        
        // 【作用】配置描述符属性，与6000版本逻辑完全一致
        descriptor.msaaSamples = 1; // 关闭MSAA
        descriptor.enableRandomWrite = true; // 开启UAV随机写入权限（Compute Shader必备）
        descriptor.depthStencilFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.None; // 不需要深度
        
        // 【作用】使用URP提供的工具类分配或重新分配 RTHandle
        // 【原理】RenderingUtils.ReAllocateIfNeeded 是2022.3中非常安全的写法，如果纹理尺寸没变则不重新创建，避免每帧造垃圾导致卡顿。
        RenderingUtils.ReAllocateIfNeeded(ref tempScreenTexture, descriptor, FilterMode.Point, TextureWrapMode.Clamp, name: "_AutoExposureTempTexture");
    }

    // 【作用】重写：2022.3标准的执行回调（替代了6000版本的 RecordRenderGraph）
    // 【原理】这里每帧真正向GPU发送指令。
    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        // 【作用】获取当前相机的实际渲染宽高
        // 【原理】不能用Screen.width，因为在编辑器Game视图拉大拉小、或者多相机渲染时，Screen.width并不等于当前相机的真实渲染分辨率。
        int width = renderingData.cameraData.cameraTargetDescriptor.width;
        int height = renderingData.cameraData.cameraTargetDescriptor.height;
        
        // 【作用】根据真实分辨率动态计算线程组
        int threadGroupsX = Mathf.CeilToInt(width / (float)numThreads.x);
        int threadGroupsY = Mathf.CeilToInt(height / (float)numThreads.y);

        // 【作用】从对象池获取一个CommandBuffer
        CommandBuffer cmd = CommandBufferPool.Get("Auto Exposure Compute");

        // 【作用】将原生相机画面 Blit (拷贝) 到我们创建的临时纹理中
        // 【原理】因为原生画面不支持直接被Compute Shader写入，必须先拷贝一份出来。cameraColorTargetHandle代表了当前相机的画面。
        cmd.Blit(renderingData.cameraData.renderer.cameraColorTargetHandle, tempScreenTexture);

        // 【作用】更新CPU端时间参数并推送到GPU
        UpdateRParameters();

        ComputeShader computeShader = settings.computeShader;

        // ========== 1. 执行 AccumulateLuminance Kernel ==========
        int kernelIndex = computeShader.FindKernel("AccumulateLuminance");
        // 【原理】在2022.3中，RTHandle可以隐式转换为RenderTargetIdentifier传给API。
        cmd.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", tempScreenTexture);
        cmd.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer);
        cmd.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);

        // ========== 2. 执行 ComputeTargetEV Kernel ==========
        kernelIndex = computeShader.FindKernel("ComputeTargetEV");
        cmd.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", tempScreenTexture);
        cmd.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer);
        cmd.SetComputeBufferParam(computeShader, kernelIndex, "_RParameters", rParameterBuffer);
        cmd.DispatchCompute(computeShader, kernelIndex, 1, 1, 1);

        // ========== 3. 执行 ApplyExposure Kernel ==========
        kernelIndex = computeShader.FindKernel("ApplyExposure");
        cmd.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", tempScreenTexture);
        cmd.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer); 
        cmd.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);

        // ========== 将处理好的图拷贝回原生管线 ==========
        // 【作用】将算完曝光的临时图，拷贝回真正的相机颜色目标中
        // 【原理】等价于6000版本里的 `resourceData.cameraColor = screenTexture;`。如果不做这一步，屏幕上显示的还是没加曝光的旧图。
        cmd.Blit(tempScreenTexture, renderingData.cameraData.renderer.cameraColorTargetHandle);

        // 【作用】将录制的命令缓冲区提交给管线执行
        context.ExecuteCommandBuffer(cmd);
        // 【作用】将命令缓冲区放回对象池
        CommandBufferPool.Release(cmd);
    }

    // 【作用】新增：相机渲染结束后的清理回调
    // 【原理】虽然 ReAllocateIfNeeded 能处理纹理，但如果不写这个函数，在某些特殊情况下URP可能会报警告。
    public override void OnCameraCleanup(CommandBuffer cmd)
    {
        // 2022.3中无需手动释放 tempScreenTexture，由 ReAllocateIfNeeded 统一管理生命周期即可
    }

    // 【作用】新增：手动清理函数
    // 【原理】2022.3没有Render Graph自动帮你管ComputeBuffer，当这个Pass被销毁（比如关闭Feature）时，必须手动释放GPU内存，否则会严重内存泄漏！
    public void Dispose()
    {
        if (rwParameterBuffer != null) rwParameterBuffer.Release();
        if (rParameterBuffer != null) rParameterBuffer.Release();
        if (tempScreenTexture != null) tempScreenTexture.Release();
    }

    private void UpdateRParameters()
    {
        rParameters[0].deltaTime = Time.deltaTime;
        rParameterBuffer.SetData(rParameters);
    }
}