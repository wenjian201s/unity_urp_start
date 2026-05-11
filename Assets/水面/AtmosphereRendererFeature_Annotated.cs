using UnityEngine; // 引入Unity基础命名空间，提供Shader、Material、Camera等类型。
using UnityEngine.Rendering; // 引入渲染命名空间，提供CommandBuffer、RTHandle、RenderTextureDescriptor等类型。
using UnityEngine.Rendering.Universal; // 引入URP命名空间，提供ScriptableRendererFeature、ScriptableRenderPass、RenderingData等类型。

// URP渲染器功能：用于替代Built-in管线中的OnRenderImage后处理入口。
// 作用：把大气散射作为一个自定义全屏后处理Pass插入URP渲染流程。
// 原理：URP不依赖Camera.OnRenderImage，而是通过RendererFeature把ScriptableRenderPass加入渲染队列。
// 使用方式：把该RendererFeature添加到URP Renderer Data的Renderer Features列表中。
public class AtmosphereRendererFeature : ScriptableRendererFeature {
    [System.Serializable] // 让Settings显示在Inspector中，方便在Renderer Data里配置。
    public class Settings {
        public Shader atmosphereShader; // 大气散射后处理Shader；为空时会自动查找Hidden/AtmosphereURP。
        public RenderPassEvent renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing; // Pass插入位置；默认在URP内置后处理之前执行。
    }

    public Settings settings = new Settings(); // RendererFeature的可调配置数据。

    private Material atmosphereMaterial; // 由Shader创建的材质，用于全屏Blit时执行AtmosphereURP.shader。
    private AtmospherePass atmospherePass; // 实际执行后处理逻辑的ScriptableRenderPass实例。

    public override void Create() { // RendererFeature创建/重新加载时调用，例如进入播放模式或修改Renderer Data。
        if (settings.atmosphereShader == null) { // 如果RendererFeature没有手动指定Shader。
            settings.atmosphereShader = Shader.Find("Hidden/AtmosphereURP"); // 自动查找URP版本大气Shader。
        }

        if (settings.atmosphereShader != null) { // 找到Shader后才能创建材质。
            atmosphereMaterial = CoreUtils.CreateEngineMaterial(settings.atmosphereShader); // 创建引擎内部材质；比new Material更适合渲染管线内部资源。
        }

        atmospherePass = new AtmospherePass(atmosphereMaterial); // 创建自定义渲染Pass，并把后处理材质传进去。
        atmospherePass.renderPassEvent = settings.renderPassEvent; // 设置Pass在URP渲染流程中的执行时机。
    }

    public override void SetupRenderPasses(ScriptableRenderer renderer, in RenderingData renderingData) { // URP14+推荐：在这里访问cameraColorTargetHandle。
        if (atmospherePass == null) return; // Pass不存在则无需配置。

        Atmosphere atmosphere = GetAtmosphere(renderingData.cameraData.camera); // 从当前相机或全局Active组件获取大气参数源。
        atmospherePass.Setup(renderer.cameraColorTargetHandle, atmosphere); // 设置当前相机颜色目标和大气组件，供Execute阶段使用。
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData) { // 每帧每个相机调用，用于决定是否把Pass加入渲染队列。
        if (atmosphereMaterial == null || atmospherePass == null) return; // 没有材质或Pass则无法执行。
        if (renderingData.cameraData.cameraType == CameraType.Preview) return; // 跳过预览相机，避免材质球预览/Inspector预览窗口被后处理影响。

        Atmosphere atmosphere = GetAtmosphere(renderingData.cameraData.camera); // 获取当前可用的大气组件。
        if (atmosphere == null || !atmosphere.isActiveAndEnabled) return; // 没有启用的大气组件时不执行后处理。

        renderer.EnqueuePass(atmospherePass); // 将自定义Pass加入URP渲染队列；后续URP会在指定时机调用Execute。
    }

    protected override void Dispose(bool disposing) { // RendererFeature被销毁或重新加载时释放资源。
        if (atmospherePass != null) { // 如果Pass存在，需要释放内部RTHandle。
            atmospherePass.Dispose(); // 释放Pass持有的临时纹理资源。
            atmospherePass = null; // 清空引用，避免重复释放。
        }

        CoreUtils.Destroy(atmosphereMaterial); // 销毁材质，避免编辑器/运行时内存泄漏。
        atmosphereMaterial = null; // 清空材质引用。
    }

    private Atmosphere GetAtmosphere(Camera camera) { // 优先读取当前相机上的Atmosphere组件，其次读取全局Active组件。
        if (camera != null) { // 确保相机存在。
            Atmosphere localAtmosphere = camera.GetComponent<Atmosphere>(); // 获取挂在当前渲染相机上的Atmosphere。
            if (localAtmosphere != null) return localAtmosphere; // 如果当前相机有Atmosphere，优先使用它，支持多相机不同参数。
        }

        return Atmosphere.Active; // 如果当前相机没有Atmosphere，则使用最后启用的全局Atmosphere。
    }

    private class AtmospherePass : ScriptableRenderPass { // 自定义URP渲染Pass，真正执行大气后处理。
        private readonly Material material; // 后处理材质，内部使用AtmosphereURP.shader。
        private RTHandle sourceColor; // 当前相机颜色目标，也就是URP已经渲染好的场景颜色。
        private RTHandle tempColor; // 临时颜色纹理，用作中转，避免从source读又写回source造成读写冲突。
        private Atmosphere atmosphere; // 当前使用的大气参数组件。

        public AtmospherePass(Material material) { // 构造函数，接收RendererFeature创建好的材质。
            this.material = material; // 缓存材质引用。
            ConfigureInput(ScriptableRenderPassInput.Depth); // 声明该Pass需要深度纹理；URP会为该相机准备_CameraDepthTexture。
        }

        public void Setup(RTHandle sourceColor, Atmosphere atmosphere) { // 设置Pass执行所需数据。
            this.sourceColor = sourceColor; // 保存当前相机颜色目标。
            this.atmosphere = atmosphere; // 保存大气参数来源。
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData) { // 每个相机执行Pass前调用，用来配置临时RT。
            RenderTextureDescriptor descriptor = renderingData.cameraData.cameraTargetDescriptor; // 获取当前相机颜色目标描述，包括分辨率、HDR格式等。
            descriptor.depthBufferBits = 0; // 临时颜色纹理只存颜色，不需要深度缓冲。
            descriptor.msaaSamples = 1; // Blit中间纹理通常不使用MSAA，避免不必要的消耗和解析问题。

            RenderingUtils.ReAllocateIfNeeded( // 如果tempColor为空或分辨率/格式变化，则重新分配；否则复用已有RTHandle。
                ref tempColor, // 引用传入RTHandle，函数内部可能创建或替换它。
                descriptor, // 使用当前相机的颜色格式和尺寸，保证后处理结果匹配屏幕。
                FilterMode.Bilinear, // 双线性过滤，Blit采样时更平滑。
                TextureWrapMode.Clamp, // Clamp防止屏幕边缘采样越界产生重复纹理。
                name: "_AtmosphereTempColorTexture" // 临时纹理名称，方便Frame Debugger中查看。
            ); // 按当前分辨率分配或复用临时颜色纹理。
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData) { // URP在指定RenderPassEvent时调用，执行大气散射全屏后处理。
            if (material == null || sourceColor == null || tempColor == null) return; // 缺少必要资源则跳过。
            if (atmosphere == null || !atmosphere.isActiveAndEnabled) return; // 没有启用的大气组件则跳过。

            CommandBuffer cmd = CommandBufferPool.Get("Atmosphere URP Pass"); // 从命令缓冲池获取CommandBuffer，减少GC和临时分配。

            atmosphere.ApplyToMaterial(material, renderingData.cameraData.camera); // 每帧向Shader传递最新大气参数和相机逆VP矩阵。

            // 第一步：将当前相机颜色纹理作为输入，经过大气Shader处理后写入临时纹理。
            // 原理：material的第0个Pass会读取_BlitTexture、_CameraDepthTexture，并输出混合雾/天空/太阳光晕后的颜色。
            Blitter.BlitCameraTexture(cmd, sourceColor, tempColor, material, 0);
            // 第二步：将处理后的临时纹理拷贝回当前相机颜色目标。
            // 原理：后续URP内置后处理、UI或最终BackBuffer输出会继续使用sourceColor。
            Blitter.BlitCameraTexture(cmd, tempColor, sourceColor);

            context.ExecuteCommandBuffer(cmd); // 提交命令缓冲给渲染上下文，让GPU实际执行Blit命令。
            CommandBufferPool.Release(cmd); // 释放CommandBuffer回池中，避免内存泄漏和频繁分配。
        }

        public void Dispose() { // RendererFeature销毁时调用，释放Pass内部资源。
            tempColor?.Release(); // 释放RTHandle持有的临时RenderTexture。
            tempColor = null; // 清空引用，避免重复释放。
        }
    }
}
