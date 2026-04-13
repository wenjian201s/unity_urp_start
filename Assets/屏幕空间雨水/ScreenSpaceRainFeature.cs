using System;
//核心原理
//模拟视差与动感 如果雨水只是简单地贴在屏幕上，当摄像机旋转或移动时，雨水会显得非常呆板（像贴纸）。
//管线集成与时机控制  利用 URP 的 ScriptableRendererFeature 机制，将自定义的渲染逻辑无缝插入到 Unity 官方的渲染流程中。
//数据桥接  Shader 无法主动获取摄像机的上一帧位置或复杂的逻辑状态，必须由 C# 脚本计算后“喂”给它

//工作流 
//1从 Inspector 面板获取材质（Material）和设置。 核心作用：告诉 Unity 管线，“我接下来的渲染需要深度图”。这会强制管线提前准备好 _CameraDepthTexture，
//否则 Shader 中的深度剔除逻辑（躲在屋檐下不淋雨）将失效。
//2每帧状态更新  位置采样：位置采样：获取当前摄像机世界坐标。 位移计算：当前坐标 - 上一帧坐标 = 移动矢量。 空间变换：将移动矢量乘以 worldToCameraMatrix（转为相对相机的局部坐标）。
//累加偏移：将这个位移不断累加到 m_CameraMoveOffset。
//3渲染指令录制  申请画布：通过 RTHandle 获取一张临时纹理。 设置状态：通过 CommandBuffer 设置全局变量（如偏移量、高度图矩阵等）。 执行绘制（The Blit）：调用 Blitter.BlitTexture。
namespace UnityEngine.Rendering.Universal
{
    [Serializable]// 材质设置类：将 Shader 资源封装进一个可序列化的类，方便在 Inspector 面板中配置
    internal class ScreenSpaceRainPassSettings
    {
        [SerializeField]
        public Material material;// 指向封装了 RainShader 的材质，它是最终“画”雨滴的工具
    }

    [DisallowMultipleRendererFeature("ScreenSpaceRain Feature")] // 防止在同一个 Renderer Data 中添加多个此 Feature，避免重复渲染造成浪费
    [Tooltip("ScreenSpaceRain Feature")]// 继承 ScriptableRendererFeature：这是 URP 扩展渲染管线的标准入口
    internal class ScreenSpaceRainFeature : ScriptableRendererFeature
    {
        // 序列化字段：在编辑器中保存材质配置
        [SerializeField, HideInInspector] private Shader m_Shader = null; // 预留 Shader 引用，虽然主要通过 Settings 传递
        [SerializeField] private ScreenSpaceRainPassSettings m_Settings = new ScreenSpaceRainPassSettings();

        // 内部 Pass 实例：真正负责每帧逻辑计算和渲染指令提交的对象
        private ScreenSpaceRainPass m_ScreenSpaceRainPass = null;

        // Constants

        /// <inheritdoc/>
        // Create：Feature 初始化时调用。原理是实例化具体的渲染 Pass
        public override void Create()
        {
            if (m_ScreenSpaceRainPass == null)
                m_ScreenSpaceRainPass = new ScreenSpaceRainPass();
            // 关键时机：设为透明物体渲染后。原理是雨水作为后处理，必须叠加在包括玻璃、水面在内的所有场景元素之上
            m_ScreenSpaceRainPass.renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
        }

        /// <inheritdoc/>
        // AddRenderPasses：每帧调用，判断是否需要将雨水 Pass 加入渲染序列
        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (!m_Settings.material)// 安全检查：如果没有指定材质，直接报错返回，防止空指针异常导致管线挂起
            {
                Debug.LogErrorFormat(
                    "{0}.AddRenderPasses(): Missing material. {1} render pass will not be added. Check for missing reference in the renderer resources.",
                    GetType().Name, name);
                return;
            }
            // 逻辑筛选：只有在 Game 视图（而非 Scene 或预览视图）才渲染。原理是避免开发时干扰美术编辑
            bool shouldEnqueue = m_ScreenSpaceRainPass.Setup(m_Settings) && renderingData.cameraData.cameraType == CameraType.Game;

            if (shouldEnqueue)
            {
                renderer.EnqueuePass(m_ScreenSpaceRainPass);
            }
        }

        /// <inheritdoc/>
        // Dispose：资源释放逻辑。原理是防止临时生成的渲染纹理（RT）产生内存泄漏
        protected override void Dispose(bool disposing)
        {
            m_ScreenSpaceRainPass?.Dispose();
            m_ScreenSpaceRainPass = null;
        }


        // Nested classes 核心渲染逻辑 Pass
        internal class ScreenSpaceRainPass : ScriptableRenderPass
        {
            // Profiling tag
            private static string m_ProfilerTag = "ScreenSpaceRain";// 在 Frame Debugger 中显示的调试标签名称

            // Public Variables

            // Private Variables
            private Material m_Material;// 缓存当前使用的材质
            private ScreenSpaceRainPassSettings m_CurrentSettings;
            private RTHandle m_RenderTarget;// 临时 RT 句柄，用于存储处理过程中的纹理
            
            // 摄像机运动模拟变量
            private Vector3 m_CameraLastPos; // This should change to per camera's property. // 记录上一帧摄像机世界坐标，用于计算位移差
            private Vector2 m_CameraMoveOffset;// 累积的 UV 偏移量。原理是让雨滴随着玩家移动而产生反向位移

            // Constants
            private const int colorAttachmentNum = 1;

            // Statics

            internal ScreenSpaceRainPass() //初始化参数
            {
                this.profilingSampler = new ProfilingSampler(m_ProfilerTag);  // 初始化性能分析采样器
                m_CurrentSettings = new ScreenSpaceRainPassSettings();
                m_CameraLastPos = Vector3.zero;
                m_CameraMoveOffset = Vector2.zero;
            }

            /// <summary>
            /// Setup controls per frame shouldEnqueue this pass.
            /// </summary>
            /// <param name="settings"></param>
            /// <param name="renderingData"></param>
            /// <returns></returns>// Setup：渲染前的参数同步
            internal bool Setup(ScreenSpaceRainPassSettings settings)
            {
                m_Material = settings.material;
                m_CurrentSettings = settings;
                
                // 【核心原理】：告诉管线本 Pass 需要访问深度贴图。
                // 这会导致管线提前生成 _CameraDepthTexture，供 Shader 中的 SampleSceneDepth 函数使用
                ConfigureInput(ScriptableRenderPassInput.Depth);

                return true;
            }

            /// <inheritdoc/>
            // OnCameraSetup：配置渲染目标的描述信息
            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
            {
                var desc = renderingData.cameraData.cameraTargetDescriptor;
                desc.depthBufferBits = 0;// 后处理层不需要额外的深度缓冲区
                desc.msaaSamples = 1;// 后处理通常在渲染后的缓冲区操作，不需要抗锯齿
                // 分配临时 RT。原理是确保有一个合适尺寸的“画布”来执行 Blit 操作
                RenderingUtils.ReAllocateIfNeeded(ref m_RenderTarget, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_ScreenSpaceRainTexture");

                //ConfigureTarget(m_RenderTarget);
                //ConfigureClear(ClearFlag.Color, Color.black);
            }

            /// <inheritdoc/>
            // Execute：每一帧最核心的计算逻辑
            public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
            {
                if (m_Material == null)
                {
                    Debug.LogErrorFormat("{0}.Execute(): Missing material. ScreenSpaceShadows pass will not execute. Check for missing reference in the renderer resources.", GetType().Name);
                    return;
                }
                // 获取当前主摄像机的渲染目标（通常是屏幕颜色缓冲区）
                var cameraColorHandle = renderingData.cameraData.renderer.cameraColorTargetHandle;


                // Camera Move  // --- 物理模拟计算段 --
                {
                    var camera = renderingData.cameraData.camera;
                    // 计算位移差：当前帧坐标 - 上一帧坐标
                    Vector3 camMoveDirWS = m_CameraLastPos - camera.transform.position;
                    // 将位移转为摄像机空间（View Space）。
                    // 原理：只有当玩家左右/上下移动时，雨滴才应该偏移；如果是前后移动，偏移感较弱。
                    var camMoveVS = camera.worldToCameraMatrix * camMoveDirWS;
                    // 累加 X 和 Y 轴的偏移。这些值会传给 Shader 的 UV 偏移计算
                    m_CameraMoveOffset.x += camMoveVS.x;
                    m_CameraMoveOffset.y += camMoveVS.y;
                    // 将计算好的偏移向量通过材质接口传给 Shader。原理是实现雨水的动态视差感
                    m_Material.SetVector("_CameraMoveOffset", m_CameraMoveOffset);
                    // 更新历史坐标，供下一帧计算参考
                    m_CameraLastPos = camera.transform.position;
                }
                

                // 开启命令缓冲区录制
                var cmd = CommandBufferPool.Get(m_ProfilerTag); //根据标签从缓冲池里获取CMD
                using (new ProfilingScope(cmd, this.profilingSampler))
                {
                    // 【关键渲染动作】：执行全屏绘制。
                    // 原理：它会在屏幕上铺满一个三角形，对每个像素执行 RainShader 的片元着色器。
                    // Vector4(1,1,0,0) 代表全屏 Tiling 和 Offset。
                    //Blitter.BlitCameraTexture(cmd, cameraColorHandle, cameraColorHandle, m_Material, 0);
                    Blitter.BlitTexture(cmd, new Vector4(1.0f, 1.0f, 0.0f, 0.0f), m_Material, 0);



                    // Execute commandBuffer and clean
                    context.ExecuteCommandBuffer(cmd);// 立即执行当前缓冲区中的所有命令
                    cmd.Clear();
                    CommandBufferPool.Release(cmd);
                }
            }

            /// <inheritdoc/>
            public override void OnCameraCleanup(CommandBuffer cmd)
            {
                if (cmd == null)
                    throw new ArgumentNullException("cmd");

                // Clean Keyword if need
                //CoreUtils.SetKeyword(cmd, ShaderKeywordStrings, false);
            }

            /// <summary>
            /// Clean up resources used by this pass.
            /// </summary>
            public void Dispose()// Dispose：清理分配的纹理资源，防止 GPU 显存溢出
            {
                m_RenderTarget?.Release();
            }
        }
    }
}