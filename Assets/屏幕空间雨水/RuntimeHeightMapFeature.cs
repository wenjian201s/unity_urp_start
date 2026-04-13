using System;
using System.Collections.Generic;
// 引入Unity实验性API，用于获取底层的图形格式（GraphicsFormat）
using static UnityEngine.Experimental.Rendering.RayTracingAccelerationStructure;
using static UnityEngine.Experimental.Rendering.Universal.RenderObjects;

//屏幕空间雨水 Shader 的黄金搭档：运行时高度图生成器（C# 侧的 URP Renderer Feature）。
//核心原理是：在主摄像机的正上方，偷偷放置一个虚拟的“正交（Orthographic）摄像机”，向下拍摄一张深度图（Depth Map）。
//这张深度图记录了场景从上到下的最高点（比如屋顶、树冠），随后传给 Shader，让 Shader 知道哪里有遮挡，从而实现“躲在屋檐下没有雨”的效果。

//工作流
//1 C# 侧（收集情报）： 每帧在玩家头顶挂一个隐形的天眼（正交相机），实时拍下周围建筑/地形的俯视深度图。
//2 C# 侧（分发情报）： 把这张图（_RuntimeHeightMapTexture）和天眼的坐标系矩阵（_RuntimeHeightMapMatrix）广播给全图。
//3 Shader 侧（执行裁决）： 屏幕后处理 Shader 根据玩家视角，在屏幕上算出一个虚拟雨滴的3D坐标。
//把这个坐标丢进天眼矩阵里换算，去深度图上查一下：“天眼能看到这个雨滴吗？”。如果天眼看到的深度比雨滴还浅（说明屋顶挡在前面了），这个雨滴就不画（Alpha=0）。

namespace UnityEngine.Rendering.Universal
{
    // 定义高度图的分辨率枚举
    // 原理：分辨率越高，雨水被遮挡的边缘越精确（不会漏雨或错位），但性能消耗也越大
    public enum HeightMapResolution
    {
        _512 = 512,
        _1024 = 1024,
        _2048 = 2048,
    }
    
    [Serializable]
    // 渲染Pass的设置面板类，暴露给Inspector面板供美术/TA调整
    internal class RuntimeHeightMapPassSettings
    {
        [SerializeField] public HeightMapResolution resolution = HeightMapResolution._1024; // 贴图分辨率
        [SerializeField] public float cameraHeight = 100.0f; // 虚拟摄像机距离主摄像机的高度
        [SerializeField] public float viewPortWidth = 100.0f; // 正交摄像机的视口宽度（覆盖多大范围的雨水区域）
        [SerializeField] public float heightMapDepth = 500.0f; // 正交摄像机的远裁剪面（往下能拍多深）
        [SerializeField] public LayerMask opaqueLayerMask = -1; // 遮挡物层级掩码（比如可以去掉“水面”层，让雨滴能落到水面上）
    }

    [DisallowMultipleRendererFeature("RuntimeHeightMap Feature")] // 不允许在同一个RendererData里添加多个此Feature
    [Tooltip("RuntimeHeightMap Feature")]
    // URP的ScriptableRendererFeature基类，用于向渲染管线中插入自定义的渲染步骤
    internal class RuntimeHeightMapFeature : ScriptableRendererFeature
    {
        
        // 序列化字段
        [SerializeField, HideInInspector] private Shader m_Shader = null; // 此处未用到，可能是遗留或为了后续扩展
        [SerializeField] private RuntimeHeightMapPassSettings m_Settings = new RuntimeHeightMapPassSettings();
        
        // 内部渲染Pass实例
        private RuntimeHeightMapPass m_RuntimeHeightMapPass = null;
        
        /// <inheritdoc/>
        // 管线初始化时调用，用于创建Pass实例
        public override void Create()
        {
            if (m_RuntimeHeightMapPass == null)
                m_RuntimeHeightMapPass = new RuntimeHeightMapPass();

            // 将此Pass插入到渲染管线的哪个阶段：在渲染不透明物体之前（BeforeRendering）
            // 原理：必须在早期生成高度图，后续的不透明/透明物体渲染（或者后处理）才能采样到它
            m_RuntimeHeightMapPass.renderPassEvent = RenderPassEvent.BeforeRendering;
        }

        /// <inheritdoc/>
        // 每帧调用，决定是否将此Pass加入渲染队列
        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            // 只有当设置有效，且当前摄像机是游戏主摄像机（Game视图）时才添加。
            // 原理：避免在Scene视图的漫游摄像机上生成高度图，造成资源浪费和逻辑错误
            bool shouldEnqueue = m_RuntimeHeightMapPass.Setup(m_Settings) && renderingData.cameraData.cameraType == CameraType.Game;

            if (shouldEnqueue)
            {
                renderer.EnqueuePass(m_RuntimeHeightMapPass); // 将Pass推入渲染队列
            }
        }
        
        /// <inheritdoc/>
        // 资源清理
        protected override void Dispose(bool disposing)
        {
            m_RuntimeHeightMapPass?.Dispose();
            m_RuntimeHeightMapPass = null;
        }
        
        
        // =================================================================================
        // 内部类：具体的渲染逻辑 Pass
        // =================================================================================
        internal class RuntimeHeightMapPass : ScriptableRenderPass
        {
            
            // Profiler标签，用于在Frame Debugger中识别这个Pass的耗时
            private static string m_ProfilerTag = "RuntimeHeightMap";

            private RuntimeHeightMapPassSettings m_CurrentSettings;
            private RTHandle m_RenderTarget; // 渲染目标句柄（用于存储深度高度图）
            
            // 定义需要被高度图相机渲染的Shader Pass标签
            // 原理：包含这些标签的材质才会被“拍”进高度图里，通常就是场景里的基础模型  //当含有该列表的标签 的材质模型将被渲染到高度图
            private static List<ShaderTagId> s_shaderTagIds = new List<ShaderTagId>() { new ShaderTagId("SRPDefaultUnlit"), new ShaderTagId("UniversalForward"), new ShaderTagId("UniversalForwardOnly") };
            
            internal RuntimeHeightMapPass() //初始化
            {
                this.profilingSampler = new ProfilingSampler(m_ProfilerTag);
                m_CurrentSettings = new RuntimeHeightMapPassSettings();
            }
            // 初始化当前帧的设置
            internal bool Setup(RuntimeHeightMapPassSettings settings)
            {
                m_CurrentSettings = settings;
                return true;
            }
            
            /// <inheritdoc/>
            // 配置渲染目标（RT）
            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
            {
                int resolution = (int)m_CurrentSettings.resolution;

                // 获取主摄像机的目标描述作为基础模板
                var desc = renderingData.cameraData.cameraTargetDescriptor;
                desc.msaaSamples = 1; // 关闭抗锯齿（深度图不需要MSAA）
                // 【关键】将格式设置为32位浮点型深度格式。高度图其实就是一张精细的深度图！
                desc.graphicsFormat = Experimental.Rendering.GraphicsFormat.D32_SFloat; 
                desc.width = resolution;
                desc.height = resolution;

                // 如果RT还没分配或尺寸不一致，则重新分配内存。采样模式设为Point(最近邻)，防止深度插值导致边缘漏雨
                RenderingUtils.ReAllocateIfNeeded(ref m_RenderTarget, desc, FilterMode.Point, TextureWrapMode.Clamp, name: "_RuntimeHeightMapTexture");

                // 告诉管线：接下来的渲染指令请画到这个RT上
                ConfigureTarget(m_RenderTarget);
                // 渲染前清空RT（ClearFlag.All），颜色填充为黑色
                ConfigureClear(ClearFlag.All, Color.black);
            }
            
            // 计算用于Shader中将世界坐标转换到高度图UV空间的矩阵（类似计算阴影贴图的投影矩阵）
            static Matrix4x4 GetShadowTransform(Matrix4x4 proj, Matrix4x4 view)
            {
                // 处理不同图形API（DirectX vs OpenGL/Vulkan）的Z轴深度反转问题
                // 原理：DX的深度是近1远0 (Reversed-Z)，GL是近-1远1。为了统一，如果是DX环境，需要反转投影矩阵的Z分量。
                if (SystemInfo.usesReversedZBuffer)
                {
                    proj.m20 = -proj.m20;
                    proj.m21 = -proj.m21;
                    proj.m22 = -proj.m22;
                    proj.m23 = -proj.m23;
                }

                // 世界空间 到 裁剪空间 的矩阵 (VP矩阵)
                Matrix4x4 worldToShadow = proj * view;

                // 构建一个缩放和平移矩阵 (Scale & Bias)
                var textureScaleAndBias = Matrix4x4.identity;
                textureScaleAndBias.m00 = 0.5f;
                textureScaleAndBias.m11 = 0.5f;
                textureScaleAndBias.m22 = 0.5f;
                textureScaleAndBias.m03 = 0.5f;
                textureScaleAndBias.m23 = 0.5f;
                textureScaleAndBias.m13 = 0.5f;
                // 原理：投影后的坐标范围是[-1, 1] (Clip Space)，但贴图UV范围是[0, 1]。
                // 这个矩阵的作用是将[-1, 1]映射到[0, 1]，即 x * 0.5 + 0.5。提前在C#算好，省去Shader里的计算。

                return textureScaleAndBias * worldToShadow;
            }
            
            /// <inheritdoc/>
            // 执行具体的渲染指令
            public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
            {
                var cmd = CommandBufferPool.Get(m_ProfilerTag); // 从对象池获取CommandBuffer
                using (new ProfilingScope(cmd, this.profilingSampler))
                {
                    int resolution = (int)m_CurrentSettings.resolution;
                    float viewPortSize = m_CurrentSettings.viewPortWidth;
                    
                    // 获取主摄像机的位置
                    var camera = renderingData.cameraData.camera;
                    var camPosWS = camera.transform.position;
                    // 【关键1】计算虚拟俯视摄像机的位置：跟随主摄像机移动，但在其正上方 cameraHeight 处
                    var vritualCamPosWS = new Vector3(camPosWS.x, camPosWS.y + m_CurrentSettings.cameraHeight, camPosWS.z);
                    var upDirWS = new Vector3(0.0f, 0.0f, 1.0f); // 设置虚拟相机的“上”方向为世界Z轴（因为它朝下看，Y成了深度）

                    // 【关键2】计算View矩阵（视图矩阵）
                    // LookAt建立一个从虚拟相机位置看向主相机的矩阵
                    Matrix4x4 lookMatrix = Matrix4x4.LookAt(vritualCamPosWS, camPosWS, upDirWS);
                    // 因为Unity的摄像机看向的是-Z轴（右手坐标系转左手坐标系），所以需要沿着Z轴镜像翻转
                    Matrix4x4 scaleMatrix = Matrix4x4.TRS(Vector3.zero, Quaternion.identity, new Vector3(1, 1, -1));
                    // 最终View矩阵 = 翻转矩阵 * LookAt的逆矩阵（把世界坐标变回相对于相机的坐标）
                    var viewMatrix = scaleMatrix * lookMatrix.inverse;

                    // 【关键3】计算Projection矩阵（投影矩阵）
                    // 构建一个正交投影矩阵。参数：左右下上近远。
                    // 原理：正交相机没有透视变形，拍出来的深度图正好可以严格对应XY平面的世界坐标。
                    var projMatrix = Matrix4x4.Ortho(-viewPortSize, viewPortSize, -viewPortSize, viewPortSize, 0.0f, m_CurrentSettings.heightMapDepth);

                    // 设置绘制视口大小
                    cmd.SetViewport(new Rect(0, 0, resolution, resolution));
                    // 将我们算好的虚拟相机的VP矩阵注入到渲染上下文中
                    // 此后画的所有东西，都是从这个“天眼”虚拟相机的视角画的！
                    cmd.SetViewProjectionMatrices(viewMatrix, projMatrix);

                    // 提交以上配置
                    context.ExecuteCommandBuffer(cmd);
                    cmd.Clear();

                    // === 开始绘制场景物体 ===
                    
                    // 过滤设置：只画不透明物体（Opaque），并且只画设定好的LayerMask（比如忽略水面、特效层）
                    var filteringSettings = new FilteringSettings(RenderQueueRange.opaque, m_CurrentSettings.opaqueLayerMask);
                    var renderStateBlock = new RenderStateBlock(RenderStateMask.Nothing);

                    // 收集场景中带有目标ShaderTagId的物体
                    DrawingSettings drawSettings = RenderingUtils.CreateDrawingSettings(s_shaderTagIds, ref renderingData, renderingData.cameraData.defaultOpaqueSortFlags);
                    
                    // 核心API：通知管线真正去渲染这些物体到当前配置的RT（也就是我们的HeightMap）中
                    context.DrawRenderers(renderingData.cullResults, ref drawSettings, ref filteringSettings, ref renderStateBlock);

                    // === 传递数据给后续的雨水Shader ===
                    
                    // 把天眼相机的投影转换矩阵设置为全局变量，Shader里就是用它把雨滴坐标转为高度图UV
                    cmd.SetGlobalMatrix("_RuntimeHeightMapMatrix", GetShadowTransform(projMatrix, viewMatrix));
                    // 把刚刚画好的高度图（深度图）设置为全局纹理，供雨滴Shader采样（对比高度）
                    cmd.SetGlobalTexture("_RuntimeHeightMapTexture", m_RenderTarget);

                    // 执行CommandBuffer并清理
                    context.ExecuteCommandBuffer(cmd);
                    cmd.Clear();
                    CommandBufferPool.Release(cmd); // 回收CommandBuffer
                }
            }
            
            /// <inheritdoc/>
            // 相机渲染结束时的清理工作
            public override void OnCameraCleanup(CommandBuffer cmd)
            {
                if (cmd == null)
                    throw new ArgumentNullException("cmd");
            }

            // 释放RT资源，防止内存泄漏
            public void Dispose()
            {
                m_RenderTarget?.Release();
            }
        }
    }


}