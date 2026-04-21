// 【作用】引入C#的基础系统库命名空间
// 【原理】提供基础的类和方法支持，例如下面用到的 [Serializable] 序列化特性就来源于此。
using System;

// 【作用】引入Unity引擎的核心命名空间
// 【原理】包含Unity最基础的API，如Mathf、GameObject等，是编写Unity脚本的必备基础。
using UnityEngine;

// 【作用】引入Unity的渲染命名空间
// 【原理】这个命名空间非常关键，它包含了URP/HDRP后处理系统所需的底层类，比如此处的 VolumeComponent（体积组件基类）以及各种 Parameter（参数包装类）。
using UnityEngine.Rendering;

// 【作用】将该类标记为“可序列化”
// 【原理】告诉Unity引擎，这个类里面的变量需要被序列化保存。只有加上这个特性，类内部的参数才能在Unity的Inspector（检视面板）中正确显示，并且当你在编辑器中修改参数后，数据能被保存到场景或预设文件中。
[Serializable]

// 【作用】定义该组件在Volume面板中的添加路径
// 【原理】当开发者点击Unity的 "Add Override" 按钮时，这个属性决定了该后处理效果出现在菜单的哪个位置。此处表示它会被归类在 "Custom" 分类下，名称显示为 "AutoExposure"。
[VolumeComponentMenu("Custom/AutoExposure")]

// 【作用】声明一个名为 AutoExposure 的公开类，并继承自 VolumeComponent
// 【原理】继承 VolumeComponent 是让这个C#脚本成为URP后处理“体积效果”的核心前提。只有继承它，这个类才能被挂载到 Volume（体积）对象上，并且Unity才能自动处理它的参数在不同Volume之间的优先级覆盖和混合过渡逻辑。
public class AutoExposure : VolumeComponent
{
    // 【作用】声明一个布尔类型的参数，命名为 localExposure，默认值为 false
    // 【原理】不能直接用 bool，必须用 Unity 提供的 BoolParameter 包装。这是因为 Volume 系统需要支持参数的“插值混合”（例如摄像机从体积A走进体积B，参数需要平滑过渡）。这个变量直接对应 Shader 中的 `#pragma multi_compile_local __ LOCAL_EXPOSURE` 关键字，控制是否开启局部曝光计算。
    public BoolParameter localExposure = new BoolParameter(false);
    
    // 【作用】声明一个带范围限制的浮点参数，命名为 blurredLumBlend，默认值为0.5，最小值为0，最大值为1
    // 【原理】使用 ClampedFloatParameter 包装浮点数，除了支持Volume混合外，还能在Inspector面板中强制限制输入范围，防止美术或程序员填入不合理的数值（如负数或大于1的数）。这个参数直接对应 Shader 中 `_RParameters[0].blurredLumBlend`，用于控制局部曝光中“双边滤波亮度”与“高斯模糊亮度”的混合比例（0为纯保留边缘，1为纯平滑）。
    public ClampedFloatParameter blurredLumBlend = new ClampedFloatParameter(0.5f, 0f, 1f);
}