// 引入系统基础命名空间，提供基本的类型支持
using System;
// 引入泛型集合命名空间，提供List等动态数组支持，用于存放蓝噪声贴图列表
using System.Collections.Generic;
// 引入Unity引擎核心命名空间
using UnityEngine;
// 引用Unity的底层渲染API命名空间，提供CommandBuffer、RenderTexture等核心结构
using UnityEngine.Rendering;
// 引入URP专用的渲染命名空间，提供ScriptableRendererFeature等URP管线特有类的支持
using UnityEngine.Rendering.Universal;

// 定义命名空间
namespace RecaNoMaho
{
    // 声明体积光渲染特性类，继承自ScriptableRendererFeature。
    // 原理：在URP中，所有挂载在Universal Renderer Data上的自定义渲染节点都必须继承此类，它是管线的入口
    public class VolumetricLightRenderFeature : ScriptableRendererFeature
    {
        // 声明一个可序列化的内部类，用于在Inspector面板上整洁地显示全局参数
        [Serializable]
        public class GlobalParams
        {
            // 体积光渲染目标的缩放比例。原理：为了性能，体积光通常不以全分辨率计算，0.5就是半分辨率，能大幅提升帧率
            [Tooltip("Volumetic Light RT Scale")] [Range(0.01f, 2)] public float renderScale = 1f;
            // Ray Marching的全局步进次数。原理：步数决定光线积分的精度，步数低会有明显分层，步数高则耗性能
            [Tooltip("Ray Marching步进次数")][Range(0, 64)] public int steps = 8;
            // 全局的可见距离（雾浓度）。原理：对应透射率公式，值越小代表介质越浓，光衰减越快
            [Tooltip("体积光的可见距离(影响介质透射率)")][Range(0.01f, 50f)] public float visibilityDistance = 50;
            // 全局吸收系数。原理：光撞击微粒时转化为热能等其他能量而不散射出去的比例
            [Tooltip("吸收系数（非严格按照公式）")] [Range(0, 1)] public float absorption = 0.1f;
            // HG相位函数的非对称因子。原理：控制丁达尔效应的形状，1表示光都往逆光方向散（光柱明显），-1表示往顺光方向散
            [Tooltip("散射光在顺光或逆光方向上的相对强度，取值范围[-1, 1]，1在逆光上最强")] [Range(-1f, 1f)] public float HGFactor;
            // 蓝噪声贴图序列。原理：单张蓝噪声只有固定图案，提供多张并在每帧按索引轮换，可以实现时间维度的抖动，彻底消除固定步长带来的低频条带伪影
            [Tooltip("每帧采样不同的BlueNoiseTexture做抖动采样，优化采样次数")]
            public List<Texture2D> blueNoiseTextures;
            
            // 将美术友好的"可见距离"转化为物理公式需要的"消光系数"
            public float GetExtinction()
            {
                // 数学原理：根据比尔-朗伯定律 T = e^(-σ*d)，假设在distance处透射率衰减到1/10，即 0.1 = e^(-σ*d)，解方程得 σ = ln(10) / d
                return Mathf.Log(10f) / visibilityDistance;
            }
        }

        // 实例化一个全局参数对象，该对象会直接显示在URP的Renderer Feature面板上供美术调节
        public GlobalParams globalParams = new GlobalParams();
        
        // 声明一个真正的渲染Pass对象引用，该Pass负责具体的GPU指令下发和Shader执行
        VolumetricLightRenderPass volumetricLightRenderPass;
        
        // 重写URP基类方法：当Renderer Feature被创建或管线设置发生改变时调用一次，用于初始化资源
        public override void Create()
        {
            // 实例化之前写好的体积光渲染Pass类
            volumetricLightRenderPass = new VolumetricLightRenderPass();

            // 设置该Pass在URP渲染管线中的插入时机。
            // 原理：BeforeRenderingPostProcessing 意味着它会在场景颜色绘制完毕后、但还没执行色彩空间转换和Bloom等后处理之前执行。
            // 这样做的好处是体积光作为线性空间的光照信息，能够正确地被后续的Bloom等效果捕捉并泛光
            volumetricLightRenderPass.renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
        }
        
        // 重写URP基类方法：每帧每个相机都会调用一次。用于判断当前帧是否需要执行这个Pass，如果需要则将其加入执行队列
        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            // 调用Pass内部的Setup方法（通常在这里检查当前相机是否是主相机、是否有体积光组件等）。
            // 如果返回true，说明满足渲染条件
            if (volumetricLightRenderPass.Setup(ref renderingData, globalParams))
            {
                // 将该Pass正式注入到当前帧的渲染队列中，URP会在合适的时机自动调用它的Execute方法
                renderer.EnqueuePass(volumetricLightRenderPass);
            }
        }

        // Unity生命周期：当脚本所在对象被销毁时调用
        private void OnDestroy()
        {
            // 安全检查：如果Pass对象存在
            if (volumetricLightRenderPass != null)
            {
                // 调用清理方法。原理：释放Pass内部申请的临时渲染纹理（RT），防止显存泄漏
                volumetricLightRenderPass.Cleanup();
            }
        }

        // Unity生命周期：当脚本被禁用（取消勾选或物体Inactive）时调用
        private void OnDisable()
        {
            // 同上，禁用时也需要释放RT。原因：如果不释放，切换场景或关闭功能时，之前分配的显存就会被一直占用
            if (volumetricLightRenderPass != null)
            {
                volumetricLightRenderPass.Cleanup();
            }
        }

        // Unity编辑器专属生命周期：当在Inspector面板中修改了任何序列化变量（如拖动滑块）时调用
        private void OnValidate()
        {
            // 安全检查
            if (volumetricLightRenderPass != null)
            {
                // 面板参数修改时立刻清理。
                // 原理：例如美术修改了renderScale（渲染缩放比例），原本分配的RT尺寸就不对了，必须在这里立刻销毁旧的RT，下一帧AddRenderPasses时才会按新尺寸重新申请
                volumetricLightRenderPass.Cleanup();
            }
        }
    }
}
