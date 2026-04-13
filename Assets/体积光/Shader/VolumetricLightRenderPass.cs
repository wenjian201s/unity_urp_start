// 引入系统基础命名空间
using System;
// 引入泛型集合命名空间
using System.Collections.Generic;
// 引入Unity引擎核心命名空间
using UnityEngine;
// 引用Unity底层渲染API命名空间
using UnityEngine.Rendering;
// 引入URP专用的渲染命名空间
using UnityEngine.Rendering.Universal;

namespace RecaNoMaho
{
    // 声明体积光渲染Pass类，继承自ScriptableRenderPass。这是真正每帧执行GPU绘制的地方
    public class VolumetricLightRenderPass : ScriptableRenderPass
    {
        // 定义一个结构体，用于缓存当前帧需要渲染体积光的光源信息
        struct LightVolumeData
        {
            // 该光源上挂载的体积光组件引用
            public LightVolumeRenderer lightVolumeRenderer;
            // 该光源在URP可见光源列表中的索引
            public int lightIndex;
            // 该光源在URP"额外光源"（Additional Lights）中的索引（极其重要，用于对齐阴影贴图索引）
            public int additionalLightIndex;
            // 当前体积光在列表中的序号
            public int volumeIndex;
        }

        // 静态内部类，集中管理所有需要传给Shader的属性ID
        static class ShaderConstants
        {
            // --- 光源相关参数 ---
            // 缓存属性ID：方向光的理论距离
            public static readonly int _DirLightDistance = Shader.PropertyToID("_DirLightDistance");
            // 缓存属性ID：光源位置（.w作为类型开关：0为方向光，1为聚光灯）
            public static readonly int _LightPosition = Shader.PropertyToID("_LightPosition");
            // 缓存属性ID：光源方向（聚光灯主轴方向）
            public static readonly int _LightDirection = Shader.PropertyToID("_LightDirection");
            // 缓存属性ID：光源颜色和强度
            public static readonly int _LightColor = Shader.PropertyToID("_LightColor");
            // 缓存属性ID：聚光灯半角余弦值，用于在Shader中判断片元是否在光锥内
            public static readonly int _LightCosHalfAngle = Shader.PropertyToID("_LightCosHalfAngle");
            // 缓存属性ID：是否开启阴影的开关
            public static readonly int _UseShadow = Shader.PropertyToID("_UseShadow");
            // 缓存属性ID：阴影索引。必须与URP内部的Additional Light索引对齐，才能在Shadowmap图集中找到正确的阴影贴图
            public static readonly int _ShadowLightIndex = Shader.PropertyToID("_ShadowLightIndex");
            
            // --- Ray Marching 相关参数 ---
            // 缓存属性ID：包围盒裁剪平面的数量
            public static readonly int _BoundaryPlanesCount = Shader.PropertyToID("_BoundaryPlanesCount");
            // 缓存属性ID：包围盒裁剪平面方程数组 (Ax+By+Cz+D=0)
            public static readonly int _BoundaryPlanes = Shader.PropertyToID("_BoundaryPlanes");
            // 缓存属性ID：光线步进的次数
            public static readonly int _Steps = Shader.PropertyToID("_Steps");
            // 缓存属性ID：透射消光系数（雾的浓度）
            public static readonly int _TransmittanceExtinction = Shader.PropertyToID("_TransmittanceExtinction");
            // 缓存属性ID：吸收系数
            public static readonly int _Absorption = Shader.PropertyToID("_Absorption");
            // 缓存属性ID：入射光损耗系数
            public static readonly int _IncomingLoss = Shader.PropertyToID("_IncomingLoss");
            // 缓存属性ID：HG相位函数的非对称因子
            public static readonly int _HGFactor = Shader.PropertyToID("_HGFactor");
            // 缓存属性ID：蓝噪声贴图
            public static readonly int _BlueNoiseTexture = Shader.PropertyToID("_BlueNoiseTexture");
            // 缓存属性ID：当前渲染分辨率和倒数（用于UV映射）
            public static readonly int _RenderExtent = Shader.PropertyToID("_RenderExtent");
            
            // --- 相机相关参数 ---
            // 缓存属性ID：打包的相机FOV信息（水平/垂直正切值），用于在Shader中精确重建视线方向
            public static readonly int _CameraPackedInfo = Shader.PropertyToID("_CameraPackedInfo");
            
            // --- 风格化参数 ---
            // 缓存属性ID：亮部强度乘数
            public static readonly int _BrightIntensity = Shader.PropertyToID("_BrightIntensity");
            // 缓存属性ID：暗部强度乘数（控制体积外暗部的衰减程度）
            public static readonly int _DarkIntensity = Shader.PropertyToID("_DarkIntensity");
        }

        // 枚举类型，对应VolumetricLight Shader中的Pass索引
        enum ShaderPass
        {
            COPY_BLIT = 0,             // 第0个Pass（本代码未深用）
            VOLUMETRIC_LIGHT_SPOT = 1, // 第1个Pass，执行聚光灯光线步进的Pass
        }

        // 性能分析采样器。原理：在Profiler和Frame Debugger中会显示为"Volumetric Light"，方便排查性能瓶颈
        private ProfilingSampler profilingSampler;
        // 缓存找到的体积光Shader
        private Shader shader;
        // 缓存由Shader生成的材质
        private Material mat;
        
        // 存储当前帧收集到的所有需要渲染体积光的数据列表
        private List<LightVolumeData> lightVolumeDatas;
        // 缓存从RenderFeature传下来的全局参数副本
        private VolumetricLightRenderFeature.GlobalParams globalParams;
        // 存储临时渲染纹理（RT）的描述符（宽、高、格式等）
        private RenderTextureDescriptor sourceDesc;
        // 临时申请的渲染纹理。原理：体积光必须先画到一张独立的黑底RT上，最后再与屏幕加法混合，不能直接画在屏幕上
        private RenderTexture volumetricLightTex;
        // 帧计数器。用于在多张蓝噪声贴图中按帧轮换，实现时间维度的抗锯齿
        private int frameIndex = 0;

        // 构造函数，在RenderFeature的Create中被调用
        public VolumetricLightRenderPass()
        {
            // 实例化性能分析器，命名该Pass
            profilingSampler = new ProfilingSampler("Volumetric Light");
            // 初始化光源数据列表
            lightVolumeDatas = new List<LightVolumeData>();
            // 初始化全局参数结构体
            globalParams = new VolumetricLightRenderFeature.GlobalParams();
        }

        // 每帧在AddRenderPasses中调用的准备方法，用于验证环境并初始化本帧所需数据
        public bool Setup(ref RenderingData renderingData, VolumetricLightRenderFeature.GlobalParams globalParams)
        {
            // 尝试加载Shader和创建材质，如果找不到Shader文件则返回false，中断本帧渲染
            if (!FetchMaterial())
            {
                return false;
            }

            // 遍历场景剔除后的可见光源，提取挂载了体积光组件的数据。如果场景中没光源则返回false
            if (!FetchLightVolumeDatas(ref renderingData))
            {
                return false;
            }
            
            // 将传入的全局参数保存为本地副本
            this.globalParams = globalParams;

            // 获取当前相机目标纹理的描述符
            sourceDesc = renderingData.cameraData.cameraTargetDescriptor;
            // 核心性能优化：根据设置的比例缩小宽高。原理：体积光是模糊的雾气效果，不需要全分辨率渲染，半分辨率能省下巨量性能且肉眼几乎看不出差别
            sourceDesc.width = (int)(sourceDesc.width * globalParams.renderScale);
            sourceDesc.height = (int)(sourceDesc.height * globalParams.renderScale);

            // 安全校验：如果缩放后宽高小于等于0（比如 renderScale 被误设为0），则放弃渲染防止报错
            if (sourceDesc.width <= 0 || sourceDesc.height <= 0)
            {
                return false;
            }
            
            // 将深度缓冲位数设为0。原理：我们只是画2D的光雾图，不需要深度测试和深度写入，能节省显存带宽
            sourceDesc.depthBufferBits = 0;

            // 仅当渲染的是游戏相机时（排除Scene视图、预览相机等），才去申请和配置RT
            if (renderingData.cameraData.cameraType == CameraType.Game)
            {
                // 检查或创建用于绘制体积光的临时RT
                SetupVolumetricLightTexture();
            }

            // 一切准备就绪，返回true允许管线执行接下来的Execute
            return true;
        }

        // 核心执行方法，每帧由URP管线自动调用，在此下发GPU指令
        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            // 从对象池获取一个名为"Volumetric Light"的指令缓冲区。使用对象池避免每帧实例化产生GC
            var cmd = CommandBufferPool.Get("Volumetric Light");
            // 开启性能分析作用域
            using (new ProfilingScope(cmd, profilingSampler))
            {
                // 获取当前正在渲染的相机
                Camera camera = renderingData.cameraData.camera;
                
                // 设置接下来的绘制目标为我们自己申请的临时RT（volumetricLightTex）
                cmd.SetRenderTarget(volumetricLightTex, RenderBufferLoadAction.DontCare, RenderBufferStoreAction.Store);
                // 清空这个RT的颜色为纯黑。
                // 原理：DontCare表示不关心之前RT里有什么（省带宽）；清空为黑色是因为体积光最后要使用"加法混合"，黑色(0,0,0)加上任何颜色都不变原色
                cmd.ClearRenderTarget(false, true, Color.black);
                
                // 遍历收集到的每一个挂载了体积光脚本的光源
                for (int i = 0; i < lightVolumeDatas.Count; i++)
                {
                    // 获取当前光源的数据
                    LightVolumeData lightVolumeData = lightVolumeDatas[i];
                    // 获取该光源上的组件脚本
                    LightVolumeRenderer lightVolumeRenderer = lightVolumeData.lightVolumeRenderer;
                    // 如果脚本被禁用，跳过这个光源不画
                    if (!lightVolumeRenderer.enabled)
                    {
                        continue;
                    }

                    // --- 1. 准备光源相关参数 ---
                    // 从URP剔除结果中拿到真正的光源数据
                    VisibleLight light = renderingData.cullResults.visibleLights[lightVolumeData.lightIndex];
                    // 将额外光源索引传给Shader，这是读取正确阴影贴图切片的关键！
                    cmd.SetGlobalInt(ShaderConstants._ShadowLightIndex, lightVolumeData.additionalLightIndex);
                    // 调用之前写的算法，根据光源类型提取视锥体裁剪平面方程
                    List<Vector4> boundaryPlanes = lightVolumeRenderer.GetVolumeBoundFaces(camera);
                    // 声明变量接收URP内部计算好的光源标准参数（位置、颜色、衰减、方向等）
                    Vector4 lightPos, lightColor, lightAttenuation, lightSpotDir, lightOcclusionChannel;
                    // 调用URP底层方法提取参数。原理：直接用URP算好的能保证和实时光照的参数（如正交光的方向处理）绝对一致
                    UniversalRenderPipeline.InitializeLightConstants_Common(renderingData.lightData.visibleLights, lightVolumeData.lightIndex, out lightPos, out lightColor, out lightAttenuation, out lightSpotDir, out lightOcclusionChannel);

                    // 将提取到的参数设置给GPU的全局Shader变量
                    cmd.SetGlobalVector(ShaderConstants._LightPosition, lightPos);
                    cmd.SetGlobalVector(ShaderConstants._LightDirection, lightSpotDir);
                    // 颜色乘以组件上的强度系数
                    cmd.SetGlobalVector(ShaderConstants._LightColor,
                        lightColor * lightVolumeData.lightVolumeRenderer.intensityMultiplier);
                    cmd.SetGlobalFloat(ShaderConstants._DirLightDistance,
                        lightVolumeRenderer.dirLightDistance);
                    // 计算聚光灯半角余弦值。如果是方向光，设为-2（在Shader的step函数中-2永远小于任何余弦值，相当于关闭锥形限制）
                    cmd.SetGlobalFloat(ShaderConstants._LightCosHalfAngle,
                        light.lightType == LightType.Spot ? Mathf.Cos(Mathf.Deg2Rad * light.spotAngle / 2) : -2);
                    
                    // --- 2. 准备Ray Marching相关参数 ---
                    // 传入边界平面数量
                    cmd.SetGlobalInt(ShaderConstants._BoundaryPlanesCount, boundaryPlanes.Count);
                    // 传入边界平面数组
                    cmd.SetGlobalVectorArray(ShaderConstants._BoundaryPlanes, boundaryPlanes);
                    // 判断使用组件自身的步数还是全局步数
                    cmd.SetGlobalInt(ShaderConstants._Steps, lightVolumeRenderer.stepOverride ? lightVolumeRenderer.rayMarchingSteps : globalParams.steps);
                    // 判断使用组件自身的消光系数还是全局消光系数（可见距离转换而来）
                    cmd.SetGlobalFloat(ShaderConstants._TransmittanceExtinction,
                        lightVolumeRenderer.extinctionOverride ? lightVolumeRenderer.GetExtinction(): globalParams.GetExtinction());
                    // 判断使用组件自身的吸收系数还是全局吸收系数
                    cmd.SetGlobalFloat(ShaderConstants._Absorption, lightVolumeRenderer.extinctionOverride ? lightVolumeRenderer.absorption : globalParams.absorption);
                    // 传入入射损耗
                    cmd.SetGlobalFloat(ShaderConstants._IncomingLoss, lightVolumeRenderer.inComingLoss);
                    // 传入HG相位因子
                    cmd.SetGlobalFloat(ShaderConstants._HGFactor, globalParams.HGFactor);
                    
                    // --- 3. 蓝噪声抖动处理 ---
                    // 如果配置了蓝噪声贴图列表
                    if (globalParams.blueNoiseTextures.Count != 0)
                    {
                        // 取余循环：根据帧数取出不同的一张蓝噪声图，实现时间上的随机化
                        cmd.SetGlobalTexture(ShaderConstants._BlueNoiseTexture, globalParams.blueNoiseTextures[frameIndex % globalParams.blueNoiseTextures.Count]);
                        // 防止帧计数器无限增大导致整数溢出，超过1024后归零
                        if (frameIndex > 1024)
                        {
                            frameIndex = 0;
                        }
                        else
                        {
                            // 帧数加1，等待下一帧
                            frameIndex++;
                        }
                        
                        // 传入RT的宽高以及宽高的倒数。Shader中用这些值来计算精准的蓝噪声UV坐标
                        cmd.SetGlobalVector(ShaderConstants._RenderExtent,
                            new Vector4(sourceDesc.width, sourceDesc.height, 1f / sourceDesc.width,
                                1f / sourceDesc.height));
                    }
                    
                    
                    // --- 4. 相机相关参数 ---
                    // 计算相机垂直FOV的一半的正切值
                    float tanFov = Mathf.Tan(camera.fieldOfView / 2 * Mathf.Deg2Rad);
                    // 打包传入。X为垂直Tan，Y为水平Tan(乘以宽高比)。Shader用这两个值无需矩阵乘法即可重建世界空间视线
                    cmd.SetGlobalVector(ShaderConstants._CameraPackedInfo, new Vector4(tanFov, tanFov * camera.aspect, 0, 0));
                    
                    // --- 5. 风格化参数 ---
                    // 传入亮暗部系数
                    cmd.SetGlobalFloat(ShaderConstants._BrightIntensity, lightVolumeRenderer.brightIntensity);
                    cmd.SetGlobalFloat(ShaderConstants._DarkIntensity, lightVolumeRenderer.darkIntentsity);

                    // --- 6. 绘制调用 ---
                    // 根据光源类型执行不同的绘制逻辑
                    switch (light.lightType)
                    {
                        case LightType.Point:
                            // 暂未实现点光源体积光
                            break;
                        case LightType.Spot:
                            // 核心绘制指令：以该光源的世界矩阵为基准，绘制该光源组件上挂载的锥体网格。
                            // 原理：GPU光栅化这个锥体网格，只有在锥体覆盖到的像素（即光柱可能存在的区域）才会执行Fragment Shader，极大节省了性能（否则全屏计算太慢）
                            // mat: 材质；0: 子网格索引；(int)ShaderPass.VOLUMETRIC_LIGHT_SPOT: 强制使用Shader里的第1个Pass
                            cmd.DrawMesh(lightVolumeRenderer.volumeMesh,
                                lightVolumeRenderer.transform.localToWorldMatrix,
                                mat, 0, (int)ShaderPass.VOLUMETRIC_LIGHT_SPOT);
                            break;
                        case LightType.Directional:
                            // 暂未实现方向光体积光（虽然C#提取了平面，但Shader部分未走这个分支）
                            break;
                    }
                }
                
                // --- 7. 最终合成 ---
                // 调用之前写的通用工具类，将画满体积光的临时RT，以"加法混合"叠加到URP相机的最终颜色目标上
                // 原理：这一步实现了光效与场景的融合
                CommonUtil.BlitAdd(cmd, volumetricLightTex, renderingData.cameraData.renderer.cameraColorTargetHandle);

                // 将构建好的所有指令提交给URP上下文去真正执行GPU渲染
                context.ExecuteCommandBuffer(cmd);
                // 清空指令缓冲区内容
                cmd.Clear();
                // 将指令缓冲区放回对象池，等待下一帧复用
                CommandBufferPool.Release(cmd);
            }
        }

        // 资源清理方法，在Feature禁用、销毁或参数改变时被调用
        public void Cleanup()
        {
            // 如果临时RT存在
            if (volumetricLightTex != null)
            {
                // 释放RT占用的GPU显存。如果不释放，修改分辨率或切换场景时会导致严重的显存泄漏
                volumetricLightTex.Release();
                // 将引用置空
                volumetricLightTex = null;
            }
        }

        // 私有方法：查找并缓存Shader与材质
        private bool FetchMaterial()
        {
            // 如果Shader为空，按路径去全局查找
            if (shader == null)
            {
                shader = Shader.Find("Hidden/RecaNoMaho/VolumetricLight");
            }

            // 如果还是找不到（比如Shader代码写错了被Unity编译失败了），返回失败
            if (shader == null)
            {
                return false;
            }

            // 如果材质为空但Shader存在
            if (mat == null && shader != null)
            {
                // 使用URP安全方法创建材质，不会在Project窗口留下垃圾文件
                mat = CoreUtils.CreateEngineMaterial(shader);
            }

            // 如果材质创建失败，返回失败
            if (mat == null)
            {
                return false;
            }

            // 一切就绪，返回成功
            return true;
        }

        // 私有方法：收集当前场景中所有有效的体积光数据
        private bool FetchLightVolumeDatas(ref RenderingData renderingData)
        {
            // 清空上一帧的旧数据
            lightVolumeDatas.Clear();
            // 额外光源的计数器，从-1开始
            int additionalLightIndex = -1;
            // 遍历URP本轮剔除后可见的所有光源
            for (int i = 0; i < renderingData.cullResults.visibleLights.Length; i++)
            {
                // 获取当前可见光源
                VisibleLight visibleLight = renderingData.cullResults.visibleLights[i];
                // 尝试获取该光源GameObject上挂载的 LightVolumeRenderer 组件
                if (visibleLight.light.TryGetComponent(out LightVolumeRenderer lightVolumeRenderer))
                {
                    // 如果挂载了，说明这是一个需要渲染体积光的光源，将其信息打包存入列表
                    lightVolumeDatas.Add(new LightVolumeData()
                    {
                        lightVolumeRenderer = lightVolumeRenderer,
                        lightIndex = i,
                        // 核心逻辑：计算该光源在Additional Lights中的索引。
                        // 原理：URP的主光源(mainLightIndex)不算在Additional里。如果当前光源是主光，给-1；否则计数器+1作为额外光源索引
                        additionalLightIndex = i == renderingData.lightData.mainLightIndex
                            ? -1 : ++additionalLightIndex,
                        volumeIndex = lightVolumeDatas.Count
                    });
                }
            }

            // 如果列表里一个光源都没有，返回false中断渲染
            return lightVolumeDatas.Count != 0;
        }
        
        // 私有方法：检查并创建/重建用于画体积光的临时渲染纹理
        private void SetupVolumetricLightTexture()
        {
            // 如果RT已经存在，但是它的宽高与当前需要的宽高不一致（比如在面板上改了renderScale）
            if (volumetricLightTex != null && (volumetricLightTex.width != sourceDesc.width ||
                                               volumetricLightTex.height != sourceDesc.height))
            {
                // 释放旧的不再匹配的RT
                volumetricLightTex.Release();
                volumetricLightTex = null;
            }

            // 如果RT为空（不管是第一次还是刚被销毁）
            if (volumetricLightTex == null)
            {
                // 按照（降采样后的）描述符实例化一个新的RenderTexture
                volumetricLightTex = new RenderTexture(sourceDesc);
                // 给它起个名字，方便在Frame Debugger中辨认
                volumetricLightTex.name = "_VolumetricLightTex";
                // 设置过滤模式为双线性。原理：因为RT是降采样的（比如半分辨率），最后Blit到全屏时，双线性过滤可以让光柱边缘看起来平滑而不是全是马赛克像素块
                volumetricLightTex.filterMode = FilterMode.Bilinear;
                // 设置环绕模式为钳制。原理：UV超出0~1范围时直接取边缘颜色，防止屏幕边缘出现对面的光柱像素重影
                volumetricLightTex.wrapMode = TextureWrapMode.Clamp;
                
            }
        }
    }
}
