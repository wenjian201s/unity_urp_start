// 引入 System.Collections 命名空间
// 里面包含非泛型集合类型，例如 ArrayList、Hashtable 等
// 当前代码中没有直接使用，可以删除
using System.Collections;

// 引入 System.Collections.Generic 命名空间
// 里面包含泛型集合类型，例如 List<T>、Dictionary<TKey, TValue> 等
// 当前代码中没有直接使用，可以删除
using System.Collections.Generic;

// 引入 UnityEngine 命名空间
// ScriptableObject、Color、SerializeField、CreateAssetMenu 等 Unity 类型都来自这里
using UnityEngine;

// 引入 System 命名空间
// Serializable 特性来自 System
using System;


// 标记该类可以被序列化
// Unity 可以把该类中的可序列化字段保存到资源文件中
[Serializable]

// 允许在 Unity 编辑器的 Assets/Create 菜单中创建这个 ScriptableObject 资产
// fileName = "Atmosphere" 表示默认创建出来的资源文件名
// menuName = "AtmosphereSettings" 表示菜单路径为 Assets/Create/AtmosphereSettings
[CreateAssetMenu(fileName = "Atmosphere", menuName = "AtmosphereSettings")]

// 定义一个名为 AtmosphereSettings 的类
// 它继承自 ScriptableObject，因此可以作为 Unity 资源资产保存，而不是挂在 GameObject 上
public class AtmosphereSettings : ScriptableObject
{
    // 标记 SeaLevel 字段可以被 Unity 序列化
    // public 字段本身已经会被 Unity 序列化，所以这里的 [SerializeField] 严格来说是重复的
    [SerializeField]

    // 海平面高度
    // 作为大气模型中的高度参考基准
    // Shader 中通常通过 _SeaLevel 接收该值
    public float SeaLevel = 0.0f;


    // 标记 PlanetRadius 字段可以被 Unity 序列化
    [SerializeField]

    // 星球半径
    // 默认值 6360000 米，接近地球半径
    // 在球形大气模型中用于计算地表、大气边界、采样点高度、射线与星球求交等
    public float PlanetRadius = 6360000.0f;


    // 标记 AtmosphereHeight 字段可以被 Unity 序列化
    [SerializeField]

    // 大气层高度
    // 默认值 60000 米，表示大气层从地表向上延伸 60km
    // 大气顶部半径通常为 PlanetRadius + AtmosphereHeight
    public float AtmosphereHeight = 60000.0f;


    // 标记 SunLightIntensity 字段可以被 Unity 序列化
    [SerializeField]

    // 太阳光强度
    // 控制天空、大气散射、太阳盘的整体亮度
    // 在 Shader 中通常参与 sunLuminance = SunLightColor * SunLightIntensity
    public float SunLightIntensity = 31.4f;


    // 标记 SunLightColor 字段可以被 Unity 序列化
    [SerializeField]

    // 太阳光颜色
    // 默认是白色
    // 可以调成偏黄、偏橙，用于模拟日出、日落或不同风格化天空
    public Color SunLightColor = Color.white;


    // 标记 SunDiskAngle 字段可以被 Unity 序列化
    [SerializeField]

    // 太阳圆盘角度
    // 用于 Skybox Shader 中判断当前视线是否落入太阳盘范围
    // 数值越大，太阳盘看起来越大
    //
    // 注意：
    // 真实太阳视角直径约 0.53 度。
    // 这里默认 9.0f 明显偏大，可能是为了风格化表现或调试效果。
    public float SunDiskAngle = 9.0f;


    // 标记 RayleighScatteringScale 字段可以被 Unity 序列化
    [SerializeField]

    // Rayleigh 散射强度缩放
    // Rayleigh 散射主要来自空气分子，是天空呈蓝色的主要原因
    // 数值越大，蓝天和远处蓝色空气透视越明显
    //
    // 当前会在 Scattering.hlsl 的 RayleighCoefficient() 中作为整体倍率生效。
    public float RayleighScatteringScale = 1.0f;


    // 标记 RayleighScatteringScalarHeight 字段可以被 Unity 序列化
    [SerializeField]

    // Rayleigh 散射标高
    // 控制空气分子密度随高度的指数衰减速度
    // 常见公式类似：density = exp(-height / scaleHeight)
    //
    // 默认 8000 米，接近真实地球大气中 Rayleigh 标高的常用近似值
    public float RayleighScatteringScalarHeight = 8000.0f;


    // 标记 MieScatteringScale 字段可以被 Unity 序列化
    [SerializeField]

    // Mie 散射强度缩放
    // Mie 散射主要来自气溶胶、水汽、尘埃等较大粒子
    // 数值越大，雾感、地平线泛白、太阳附近光晕越明显
    //
    // 当前会在 Scattering.hlsl 的 MieCoefficient() / MieAbsorption() 中作为整体倍率生效。
    public float MieScatteringScale = 1.0f;


    // 标记 MieAnisotropy 字段可以被 Unity 序列化
    [SerializeField]

    // Mie 各向异性参数 g
    // 用于 MiePhase() 相函数，控制前向散射强度
    //
    // g = 0 表示接近各向同性散射
    // g 越接近 1，前向散射越强，太阳附近光晕越集中
    //
    // 默认 0.8，是大气 Mie 散射中常见的前向散射参数
    public float MieAnisotropy = 0.8f;


    // 标记 MieScatteringScalarHeight 字段可以被 Unity 序列化
    [SerializeField]

    // Mie 散射标高
    // 控制气溶胶 / 水汽 / 尘埃密度随高度衰减的速度
    //
    // 默认 1200 米，说明 Mie 粒子主要集中在低空
    // 这符合雾霾、水汽、尘埃通常靠近地表的特性
    public float MieScatteringScalarHeight = 1200.0f;


    // 标记 OzoneAbsorptionScale 字段可以被 Unity 序列化
    [SerializeField]

    // 臭氧吸收强度缩放
    // 臭氧会吸收部分波段的光，对日出、日落、高空天空颜色有影响
    //
    // 当前会在 Scattering.hlsl 的 OzoneAbsorption() 中作为整体倍率生效。
    public float OzoneAbsorptionScale = 1.0f;


    // 标记 OzoneLevelCenterHeight 字段可以被 Unity 序列化
    [SerializeField]

    // 臭氧层中心高度
    // 表示臭氧密度分布最强的位置
    //
    // 默认 25000 米，也就是 25km
    // 这比较符合臭氧层主要位于平流层中的大致高度范围
    public float OzoneLevelCenterHeight = 25000.0f;


    // 标记 OzoneLevelWidth 字段可以被 Unity 序列化
    [SerializeField]

    // 臭氧层宽度
    // 控制臭氧吸收在高度方向上的影响范围
    //
    // 你前面 Scattering.hlsl 中使用的是三角形分布：
    // rho = max(0, 1 - abs(h - center) / width)
    //
    // 所以 width 越大，臭氧吸收影响的高度范围越宽
    public float OzoneLevelWidth = 15000.0f;


    // 标记 AerialPerspectiveDistance 字段可以被 Unity 序列化
    [SerializeField]

    // 大气透视最大距离
    // 用于 AerialPerspectiveLut 和 AerialPerspective Pass
    //
    // 场景中物体距离相机会被归一化到：
    // distance / AerialPerspectiveDistance
    //
    // 然后映射到 Aerial Perspective LUT 的距离 slice。
    //
    // 默认 32000 米，表示最多预计算 / 应用 32km 范围内的大气透视
    public float AerialPerspectiveDistance = 32000.0f;
}
