// // 【作用】引入系统运行时互操作服务命名空间
// // 【原理】用于C#结构体与GPU显存字节对齐。
// using System.Runtime.InteropServices;
// // 【作用】引入Unity基础及渲染命名空间
// using UnityEngine;
// using UnityEngine.Rendering;
// // 【作用】引入Unity 6000+ 的 Render Graph 核心模块与工具模块
// using UnityEngine.Rendering.RenderGraphModule;
// using UnityEngine.Rendering.RenderGraphModule.Util;
// // 【作用】引入URP专属命名空间
// using UnityEngine.Rendering.Universal;
// // 【作用】静态引入工具类，简化代码书写
// using static UnityEngine.Rendering.RenderGraphModule.Util.RenderGraphUtils;
//
// // 【作用】声明局部曝光渲染Pass
// public class LocalExposureRenderPass : ScriptableRenderPass
// {
//     // 【作用】保存配置实例
//     private LocalExposureRenderSettings settings;
//     // 【作用】缓存ComputeShader引用
//     // 【原理】避免在每帧执行的函数中频繁从settings里取值，提升微小的性能。
//     private ComputeShader computeShader;
//     // 【作用】声明一个局部Shader关键字
//     // 【原理】对应HLSL中的 `#pragma multi_compile_local __ LOCAL_EXPOSURE`。通过这个对象，C#可以在运行时动态开启或关闭HLSL里的 `#ifdef LOCAL_EXPOSURE` 分支。
//     private LocalKeyword localExposureKeyword;
//     
//     // 【作用】定义CPU/GPU数据交互结构体及缓冲区（与之前解析的全局曝光一致）
//     private RWParameters[] rwParameters;
//     private RParameters[] rParameters;
//     private ComputeBuffer rwParameterBuffer;
//     private ComputeBuffer rParameterBuffer;
//     
//     private Vector3Int numThreads = new Vector3Int(16, 16, 1);
//     private int threadGroupsX;
//     private int threadGroupsY;
//
//     // 【作用】定义Render Graph延迟执行所需的数据包类
//     // 【原理】因为局部曝光需要分配多张中间纹理，必须将这些纹理句柄全部打包传递给执行函数。
//     public class PassData
//     {
//         public ComputeShader computeShader;
//         public TextureHandle screenTexture;         // 源屏幕图像
//         public TextureHandle logLuminance;          // 对数亮度图（单通道）
//         public TextureHandle bilateralLogLuminance; // 双边滤波后的亮度图（单通道）
//         public TextureHandle gaussianLogLuminance;  // 高斯模糊后的亮度图（单通道）
//         public TextureHandle gaussianTempBuffer;    // 高斯模糊的临时缓冲图（单通道）
//     }
//
//     // 【作用】强制C#结构体内存按顺序排列，与HLSL对齐
//     [StructLayout(LayoutKind.Sequential)]
//     public struct RWParameters
//     {
//         public uint importance;
//         public uint luminance;
//         public float historyEV;
//         public float exposure;
//     }
//
//     // 【作用】只读参数结构体（注意：比全局曝光多了一个参数）
//     [StructLayout(LayoutKind.Sequential)]
//     public struct RParameters
//     {
//         public float deltaTime;
//         // 【作用】混合系数，由Volume组件传入
//         public float blurredLumBlend;
//     }
//
//     // 【作用】构造函数
//     public LocalExposureRenderPass(LocalExposureRenderSettings localExposureRenderSettings)
//     {
//         settings = localExposureRenderSettings;
//         computeShader = settings.computeShader;
//         // 【作用】初始化局部关键字，绑定到具体的ComputeShader上
//         // 【原理】告诉Unity这个关键词属于哪个Shader，后续才能通过它设置启用/禁用。
//         localExposureKeyword = new LocalKeyword(computeShader, "LOCAL_EXPOSURE");
//
//         // 【作用】初始化GPU缓冲区（逻辑与全局曝光完全一致）
//         rwParameters = new RWParameters[1];
//         rwParameterBuffer = new ComputeBuffer(1, Marshal.SizeOf(typeof(RWParameters)), ComputeBufferType.Structured);
//         rwParameterBuffer.SetData(rwParameters);
//
//         rParameters = new RParameters[1];
//         rParameterBuffer = new ComputeBuffer(1, Marshal.SizeOf(typeof(RParameters)), ComputeBufferType.Structured);
//         rParameterBuffer.SetData(rParameters);
//
//         threadGroupsX = Mathf.CeilToInt(Screen.width / (float)numThreads.x);
//         threadGroupsY = Mathf.CeilToInt(Screen.height / (float)numThreads.y);
//     }
//
//     // 【作用】重写Render Graph记录方法
//     public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
//     {
//         // 【作用】从全局Volume堆栈中获取 AutoExposure 组件的实例
//         // 【原理】极其重要！这是C#逻辑与美术Inspector面板连接的桥梁。只有场景中存在该Volume组件，后续逻辑才有意义。
//         var volume = VolumeManager.instance.stack.GetComponent<AutoExposure>();
//         // 【作用】安全校验，如果没添加Volume组件，直接跳过本帧渲染
//         if (volume == null) return;
//         // 【作用】更新R参数（将Volume的值写进缓冲区，并处理Shader关键字开关）
//         UpdateRParameters(volume);
//
//         // 【作用】获取相机数据和管线资源数据
//         UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();
//         UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();
//
//         // 【作用】克隆屏幕纹理描述符并配置基础属性（关闭MSAA，开启随机写入，半精度浮点，无深度）
//         RenderTextureDescriptor descriptor = cameraData.cameraTargetDescriptor;
//         descriptor.msaaSamples = 1;
//         descriptor.enableRandomWrite = true;
//         descriptor.colorFormat = RenderTextureFormat.ARGBHalf;
//         descriptor.depthStencilFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.None;
//         
//         // 【作用】创建可读写的屏幕中转纹理
//         TextureHandle screenTexture = UniversalRenderer.CreateRenderGraphTexture(renderGraph, descriptor, "_ScreenTexture", false);
//         // 【作用】将当前画面拷贝到中转纹理
//         renderGraph.AddBlitPass(resourceData.activeColorTexture, screenTexture, Vector2.one, Vector2.zero);
//
//         // ========== 核心区别：为局部曝光的多个Pass分配专属的中间纹理 ==========
//         // 【作用】将格式修改为 RHalf（单通道16位浮点）
//         // 【原理】对数亮度只是一个灰度值，不需要RGB三个通道。使用RHalf能将显存占用和带宽消耗暴降为原来的四分之一，极大提升性能。
//         descriptor.colorFormat = RenderTextureFormat.RHalf;
//         
//         // 【作用】创建原始对数亮度图
//         TextureHandle _LogLuminance = UniversalRenderer.CreateRenderGraphTexture(renderGraph, descriptor, "_LogLuminance", false);
//         // 【作用】创建双边滤波结果图
//         TextureHandle bilateralLogLuminance = UniversalRenderer.CreateRenderGraphTexture(renderGraph, descriptor, "_BilateralLogLuminance", false);
//         // 【作用】创建高斯模糊最终结果图
//         TextureHandle gaussianLogLuminance = UniversalRenderer.CreateRenderGraphTexture(renderGraph, descriptor, "_GaussianLogLuminance", false);
//         // 【作用】创建高斯模糊水平/垂直分离计算的临时图
//         TextureHandle gaussianTempBuffer = UniversalRenderer.CreateRenderGraphTexture(renderGraph, descriptor, "_GaussianTempBuffer", false);
//
//         // 【作用】开始构建 Compute Pass 节点
//         using (var builder = renderGraph.AddComputePass("Local Exposure", out PassData passData))
//         {
//             // 【作用】将所有需要的资源打包进 PassData
//             passData.computeShader = settings.computeShader;
//             passData.screenTexture = screenTexture;
//             passData.logLuminance = _LogLuminance;
//             passData.bilateralLogLuminance = bilateralLogLuminance;
//             passData.gaussianLogLuminance = gaussianLogLuminance;
//             passData.gaussianTempBuffer = gaussianTempBuffer;
//
//             // 【作用】禁止剔除，声明资源依赖（将5张图全部声明，让Render Graph管理内存生命周期）
//             builder.AllowPassCulling(false);
//             builder.UseTexture(passData.screenTexture);
//             builder.UseTexture(passData.logLuminance);
//             builder.UseTexture(passData.bilateralLogLuminance);
//             builder.UseTexture(passData.gaussianLogLuminance);
//             builder.UseTexture(passData.gaussianTempBuffer);
//
//             // 【作用】设置延迟执行的GPU指令
//             builder.SetRenderFunc((PassData data, ComputeGraphContext context) =>
//             {
//                 ComputeShader computeShader = data.computeShader;
//                 ComputeCommandBuffer ccb = context.cmd;
//
//                 // ========== 1. 统计亮度并生成对数亮度图 ==========
//                 int kernelIndex = computeShader.FindKernel("AccumulateLuminance");
//                 ccb.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", data.screenTexture);
//                 // 【作用】多绑定了一个输出目标
//                 ccb.SetComputeTextureParam(computeShader, kernelIndex, "_LogLuminance", data.logLuminance);
//                 ccb.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer);
//                 ccb.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);
//
//                 // ========== 2. 计算全局EV（为局部提供基准值） ==========
//                 kernelIndex = computeShader.FindKernel("ComputeTargetEV");
//                 ccb.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", data.screenTexture);
//                 ccb.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer);
//                 ccb.SetComputeBufferParam(computeShader, kernelIndex, "_RParameters", rParameterBuffer);
//                 ccb.DispatchCompute(computeShader, kernelIndex, 1, 1, 1);
//
//                 // 【作用】关键的性能优化分支：判断是否在Volume面板开启了局部曝光
//                 if (volume.localExposure.value)
//                 {
//                     // ========== 3. 执行双边滤波（极其耗性能） ==========
//                     kernelIndex = computeShader.FindKernel("BilateralBlur");
//                     ccb.SetComputeTextureParam(computeShader, kernelIndex, "_LogLuminance", data.logLuminance);
//                     ccb.SetComputeTextureParam(computeShader, kernelIndex, "_BilateralLogLuminance", data.bilateralLogLuminance);
//                     ccb.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);
//
//                     // ========== 4. 执行分离式高斯模糊（较耗性能） ==========
//                     kernelIndex = computeShader.FindKernel("GaussianBlur");
//                     // 【原理】高斯模糊需要从原图读取，写入临时图，再从临时图读取，写入最终图。因此这里要把相关的纹理都绑上。
//                     ccb.SetComputeTextureParam(computeShader, kernelIndex, "_GaussianLogLuminance", data.gaussianLogLuminance);
//                     ccb.SetComputeTextureParam(computeShader, kernelIndex, "_LogLuminance", data.logLuminance);
//                     ccb.SetComputeTextureParam(computeShader, kernelIndex, "_BilateralLogLuminance", data.bilateralLogLuminance);
//                     ccb.SetComputeTextureParam(computeShader, kernelIndex, "_GaussianTempBuffer", data.gaussianTempBuffer);
//                     ccb.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);
//                 }
//
//                 // ========== 5. 应用曝光（无论是否开启局部，都会执行） ==========
//                 kernelIndex = computeShader.FindKernel("ApplyExposure");
//                 ccb.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", data.screenTexture);
//                 // 【作用】绑定局部亮度图供Shader读取
//                 ccb.SetComputeTextureParam(computeShader, kernelIndex, "_GaussianLogLuminance", data.bilateralLogLuminance);
//                 ccb.SetComputeTextureParam(computeShader, kernelIndex, "_BilateralLogLuminance", data.gaussianLogLuminance);
//                 ccb.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer);
//                 ccb.SetComputeBufferParam(computeShader, kernelIndex, "_RParameters", rParameterBuffer);
//                 ccb.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);
//             });
//         }
//         
//         // 【作用】将处理完的图接回主管线
//         resourceData.cameraColor = screenTexture;
//     }
//
//     // 【作用】更新只读参数并控制Shader变体的辅助方法
//     private void UpdateRParameters(AutoExposure volume)
//     {
//         // 【作用】写入帧时间
//         rParameters[0].deltaTime = Time.deltaTime;
//         // 【作用】从Volume组件读取美术调节的混合系数，写入缓冲区
//         rParameters[0].blurredLumBlend = volume.blurredLumBlend.value;
//         // 【作用】推送到GPU
//         rParameterBuffer.SetData(rParameters);
//
//         // 【作用】根据Volume面板的Bool值，动态开启或关闭Shader中的 LOCAL_EXPOSURE 关键字
//         // 【原理】当设为false时，HLSL中的 `#ifdef LOCAL_EXPOSURE` 内部的局部提亮/压暗代码将被编译器剔除，虽然前面仍然Dispatch了ApplyExposure，但GPU执行时相当于只做全局曝光，极大地节省了算力。
//         computeShader.SetKeyword(localExposureKeyword, volume.localExposure.value);
//     }
// }


using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.Rendering;
// 【作用】移除了 6000 版本的 RenderGraphModule 引用，2022.3 不需要
using UnityEngine.Rendering.Universal;

public class LocalExposureRenderPass : ScriptableRenderPass
{
    private LocalExposureRenderSettings settings;
    private ComputeShader computeShader;
    private LocalKeyword localExposureKeyword;
    
    private RWParameters[] rwParameters;
    private RParameters[] rParameters;
    private ComputeBuffer rwParameterBuffer;
    private ComputeBuffer rParameterBuffer;
    
    private Vector3Int numThreads = new Vector3Int(16, 16, 1);
    // 【作用】移除了全局的线程组计算，2022.3必须在Execute时根据当前相机的真实分辨率动态计算
    private int threadGroupsX;
    private int threadGroupsY;

    // 【作用】移除了 PassData 类
    // 【原理】2022.3 不使用延迟执行，可以直接在 Execute 中访问类成员变量。

    // 【作用】新增：声明 5 个 RTHandle 用于存储中间纹理
    // 【原理】局部曝光涉及大量的对数亮度和模糊计算，不能像全局曝光那样只操作一张图，必须分配多张单通道中间图。
    private RTHandle screenTexture;
    private RTHandle logLuminance;
    private RTHandle bilateralLogLuminance;
    private RTHandle gaussianLogLuminance;
    private RTHandle gaussianTempBuffer;

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
        public float blurredLumBlend;
    }

    public LocalExposureRenderPass(LocalExposureRenderSettings localExposureRenderSettings)
    {
        settings = localExposureRenderSettings;
        computeShader = settings.computeShader;
        localExposureKeyword = new LocalKeyword(computeShader, "LOCAL_EXPOSURE");

        rwParameters = new RWParameters[1];
        rwParameterBuffer = new ComputeBuffer(1, Marshal.SizeOf(typeof(RWParameters)), ComputeBufferType.Structured);
        rwParameterBuffer.SetData(rwParameters);

        rParameters = new RParameters[1];
        rParameterBuffer = new ComputeBuffer(1, Marshal.SizeOf(typeof(RParameters)), ComputeBufferType.Structured);
        rParameterBuffer.SetData(rParameters);

        // 【作用】在 2022.3 中，通常把渲染时机设置放在构造函数或Feature中
        this.renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
    }

    // 【作用】新增：2022.3 标准的管线配置回调
    // 【原理】每帧渲染前调用，用于获取当前相机描述符，并安全地分配/复用我们需要的 5 张中转纹理。
    public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
    {
        var descriptor = renderingData.cameraData.cameraTargetDescriptor;
        
        // --- 1. 配置屏幕中转纹理描述符 ---
        descriptor.msaaSamples = 1;
        descriptor.enableRandomWrite = true; // 必须开启 UAV
        descriptor.depthStencilFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.None;
        descriptor.colorFormat = RenderTextureFormat.ARGBHalf;
        // 【作用】使用 URP 工具类分配或复用 RTHandle
        RenderingUtils.ReAllocateIfNeeded(ref screenTexture, descriptor, FilterMode.Point, TextureWrapMode.Clamp, name: "_LocalExposure_ScreenTex");

        // --- 2. 配置单通道亮度纹理描述符 ---
        // 【原理】对数亮度是标量，用 RHalf 单通道能节省 75% 显存带宽。
        descriptor.colorFormat = RenderTextureFormat.RHalf;
        RenderingUtils.ReAllocateIfNeeded(ref logLuminance, descriptor, FilterMode.Point, TextureWrapMode.Clamp, name: "_LogLuminance");
        RenderingUtils.ReAllocateIfNeeded(ref bilateralLogLuminance, descriptor, FilterMode.Point, TextureWrapMode.Clamp, name: "_BilateralLogLuminance");
        RenderingUtils.ReAllocateIfNeeded(ref gaussianLogLuminance, descriptor, FilterMode.Point, TextureWrapMode.Clamp, name: "_GaussianLogLuminance");
        RenderingUtils.ReAllocateIfNeeded(ref gaussianTempBuffer, descriptor, FilterMode.Point, TextureWrapMode.Clamp, name: "_GaussianTempBuffer");
    }

    // 【作用】重写：2022.3 标准的执行回调（替代 6000 的 RecordRenderGraph）
    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        // 【作用】从全局 Volume 堆栈获取参数
        var volume = VolumeManager.instance.stack.GetComponent<AutoExposure>();
        if (volume == null) return;

        // 【作用】根据当前相机真实分辨率动态计算线程组
        int width = renderingData.cameraData.cameraTargetDescriptor.width;
        int height = renderingData.cameraData.cameraTargetDescriptor.height;
        threadGroupsX = Mathf.CeilToInt(width / (float)numThreads.x);
        threadGroupsY = Mathf.CeilToInt(height / (float)numThreads.y);

        // 【作用】更新参数并开启/关闭 Shader 关键字
        UpdateRParameters(volume);

        CommandBuffer cmd = CommandBufferPool.Get("Local Exposure Compute");

        // 【作用】将原生相机画面拷贝到我们开启 UAV 的中转纹理中
        cmd.Blit(renderingData.cameraData.renderer.cameraColorTargetHandle, screenTexture);

        // ========== 1. 统计亮度并生成对数亮度图 ==========
        int kernelIndex = computeShader.FindKernel("AccumulateLuminance");
        cmd.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", screenTexture);
        cmd.SetComputeTextureParam(computeShader, kernelIndex, "_LogLuminance", logLuminance);
        cmd.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer);
        cmd.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);

        // ========== 2. 计算全局EV ==========
        kernelIndex = computeShader.FindKernel("ComputeTargetEV");
        cmd.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", screenTexture);
        cmd.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer);
        cmd.SetComputeBufferParam(computeShader, kernelIndex, "_RParameters", rParameterBuffer);
        cmd.DispatchCompute(computeShader, kernelIndex, 1, 1, 1);

        // 【作用】性能优化分支：判断是否开启了局部曝光
        if (volume.localExposure.value)
        {
            // ========== 3. 双边滤波 ==========
            kernelIndex = computeShader.FindKernel("BilateralBlur");
            cmd.SetComputeTextureParam(computeShader, kernelIndex, "_LogLuminance", logLuminance);
            cmd.SetComputeTextureParam(computeShader, kernelIndex, "_BilateralLogLuminance", bilateralLogLuminance);
            cmd.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);

            // ========== 4. 分离式高斯模糊 ==========
            kernelIndex = computeShader.FindKernel("GaussianBlur");
            cmd.SetComputeTextureParam(computeShader, kernelIndex, "_GaussianLogLuminance", gaussianLogLuminance);
            cmd.SetComputeTextureParam(computeShader, kernelIndex, "_LogLuminance", logLuminance);
            cmd.SetComputeTextureParam(computeShader, kernelIndex, "_BilateralLogLuminance", bilateralLogLuminance);
            cmd.SetComputeTextureParam(computeShader, kernelIndex, "_GaussianTempBuffer", gaussianTempBuffer);
            cmd.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);
        }

        // ========== 5. 应用曝光 ==========
        kernelIndex = computeShader.FindKernel("ApplyExposure");
        cmd.SetComputeTextureParam(computeShader, kernelIndex, "_ScreenTexture", screenTexture);
        
        // 【重要修正】：在你原本的 6000 代码中，这里将 gaussian 和 bilateral 的绑定写反了（交叉绑定了）。
        // 在 2022.3 中我已将其修正为与 HLSL 变量名严格对应，否则会导致画面局部曝光计算出错！
        cmd.SetComputeTextureParam(computeShader, kernelIndex, "_GaussianLogLuminance", gaussianLogLuminance);
        cmd.SetComputeTextureParam(computeShader, kernelIndex, "_BilateralLogLuminance", bilateralLogLuminance);
        
        cmd.SetComputeBufferParam(computeShader, kernelIndex, "_RWParameters", rwParameterBuffer);
        cmd.SetComputeBufferParam(computeShader, kernelIndex, "_RParameters", rParameterBuffer);
        cmd.DispatchCompute(computeShader, kernelIndex, threadGroupsX, threadGroupsY, 1);

        // 【作用】将处理完的画面拷贝回真正的相机目标
        cmd.Blit(screenTexture, renderingData.cameraData.renderer.cameraColorTargetHandle);

        // 【作用】执行并释放命令缓冲区
        context.ExecuteCommandBuffer(cmd);
        CommandBufferPool.Release(cmd);
    }

    // 【作用】新增：手动释放 GPU 资源的方法
    // 【原理】2022.3 没有 Render Graph 的自动垃圾回收，如果不手动 Release，切换分辨率或卸载资源时会造成严重的显存泄漏！
    public void Dispose()
    {
        if (rwParameterBuffer != null) rwParameterBuffer.Release();
        if (rParameterBuffer != null) rParameterBuffer.Release();
        
        if (screenTexture != null) screenTexture.Release();
        if (logLuminance != null) logLuminance.Release();
        if (bilateralLogLuminance != null) bilateralLogLuminance.Release();
        if (gaussianLogLuminance != null) gaussianLogLuminance.Release();
        if (gaussianTempBuffer != null) gaussianTempBuffer.Release();
    }

    private void UpdateRParameters(AutoExposure volume)
    {
        rParameters[0].deltaTime = Time.deltaTime;
        rParameters[0].blurredLumBlend = volume.blurredLumBlend.value;
        rParameterBuffer.SetData(rParameters);

        computeShader.SetKeyword(localExposureKeyword, volume.localExposure.value);
    }
}