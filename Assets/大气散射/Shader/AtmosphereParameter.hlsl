// 防止头文件被重复包含
// 如果 __ATMOSPHERE_PARAMETER__ 没有被定义过，就继续编译下面的内容
#ifndef __ATMOSPHERE_PARAMETER__

// 定义宏 __ATMOSPHERE_PARAMETER__
// 后续如果其他 HLSL 文件再次 include 本文件，就不会重复定义变量和函数
#define __ATMOSPHERE_PARAMETER__


// ------------------------------------------------------------
// 大气基础参数
// 这些变量通常由 Unity C# 脚本通过 Material.SetFloat / SetVector 传入
// 它们是整个实时大气散射系统的可调参数
// ------------------------------------------------------------


// 海平面高度
// 用于定义大气模型中的参考高度
// 例如计算相机高度时会使用：cameraHeight - SeaLevel + PlanetRadius
float _SeaLevel;


// 星球半径
// 用于构建球形大气模型
// 大气散射通常不是平面模型，而是围绕星球的球壳结构
float _PlanetRadius;


// 大气层高度
// 表示从星球表面到大气层顶部的高度
// 大气外边界通常可以理解为 PlanetRadius + AtmosphereHeight
float _AtmosphereHeight;


// 太阳光强度
// 控制太阳光进入大气后的整体能量大小
// 数值越大，天空和大气散射亮度越高
float _SunLightIntensity;


// 太阳光颜色
// RGB 三通道表示太阳光颜色
// 可以用于模拟偏白、偏黄、偏橙等不同时间段的太阳光
float3 _SunLightColor;


// 太阳圆盘角度
// 用于控制太阳在天空中的视觉大小
// 通常会影响太阳盘渲染、太阳高光范围或太阳附近的亮度集中程度
float _SunDiskAngle;


// ------------------------------------------------------------
// Rayleigh 散射参数
// Rayleigh 散射主要由空气分子造成
// 它对短波长蓝光散射更强，因此是天空呈蓝色的重要原因
// ------------------------------------------------------------


// Rayleigh 散射强度缩放
// 用于整体控制分子散射强弱
// 数值越大，天空蓝色和远处空气感越明显
float _RayleighScatteringScale;


// Rayleigh 散射标高
// 控制 Rayleigh 散射密度随高度衰减的速度
// 常见形式是 exp(-height / scaleHeight)
// 标高越大，分子散射在高空中衰减越慢
float _RayleighScatteringScalarHeight;


// ------------------------------------------------------------
// Mie 散射参数
// Mie 散射主要由气溶胶、尘埃、水汽等较大粒子造成
// 它通常产生雾霾、太阳附近光晕、低空泛白等效果
// ------------------------------------------------------------


// Mie 散射强度缩放
// 用于整体控制气溶胶散射强弱
// 数值越大，雾感、泛白感、太阳周围光晕越明显
float _MieScatteringScale;


// Mie 各向异性参数
// 通常对应 Henyey-Greenstein 相函数中的 g 值
// g 越接近 1，前向散射越强，太阳附近会更亮
// g = 0 表示各向同性散射
// g < 0 表示后向散射更强，但大气中一般较少使用
float _MieAnisotropy;


// Mie 散射标高
// 控制 Mie 粒子密度随高度衰减的速度
// 由于尘埃、水汽、气溶胶主要集中在低空，Mie 标高通常比 Rayleigh 更小
float _MieScatteringScalarHeight;


// ------------------------------------------------------------
// Ozone 臭氧吸收参数
// 臭氧吸收会影响天空在黄昏、日出、日落时的颜色变化
// 它主要吸收部分波段的光，使大气颜色更加真实
// ------------------------------------------------------------


// 臭氧吸收强度缩放
// 控制臭氧层对光线吸收的强度
// 数值越大，臭氧吸收对天空颜色的影响越明显
float _OzoneAbsorptionScale;


// 臭氧层中心高度
// 表示臭氧密度分布的中心位置
// 通常臭氧不是均匀分布，而是在某个高度附近最强
float _OzoneLevelCenterHeight;


// 臭氧层宽度
// 控制臭氧密度分布在高度方向上的扩散范围
// 宽度越大，臭氧影响的高度范围越宽
float _OzoneLevelWidth;


// 引入 Scattering.hlsl
// 该文件中通常定义了 AtmosphereParameter 结构体
// 也可能包含 Rayleigh、Mie、Ozone 等散射和吸收计算函数
#include "Scattering.hlsl"


// 构造并返回 AtmosphereParameter 结构体
// 作用是把上面所有独立的全局 Shader 参数打包成一个统一结构体
// 后续函数只需要传入 param，而不用传入十几个单独参数
AtmosphereParameter GetAtmosphereParameter()
{
    // 声明一个 AtmosphereParameter 类型的变量
    // 该结构体的具体字段定义应该位于 Scattering.hlsl 中
    AtmosphereParameter param;


    // 把全局海平面高度参数写入结构体
    // 后续计算相机高度、地表高度、大气层位置时会使用
    param.SeaLevel = _SeaLevel;


    // 把全局星球半径参数写入结构体
    // 用于球形大气边界、射线与星球 / 大气层求交等计算
    param.PlanetRadius = _PlanetRadius;


    // 把全局大气高度参数写入结构体
    // 大气层外半径通常为 PlanetRadius + AtmosphereHeight
    param.AtmosphereHeight = _AtmosphereHeight;


    // 把太阳光强度写入结构体
    // 后续散射积分时会作为入射光能量的一部分
    param.SunLightIntensity = _SunLightIntensity;


    // 把太阳光颜色写入结构体
    // 后续 Rayleigh、Mie 散射结果会乘上太阳光颜色
    param.SunLightColor = _SunLightColor;


    // 把太阳圆盘角度写入结构体
    // 后续如果渲染太阳盘或太阳附近高亮，可以使用这个参数控制太阳视角大小
    param.SunDiskAngle = _SunDiskAngle;


    // 把 Rayleigh 散射强度缩放写入结构体
    // 用于控制空气分子散射的整体强度
    param.RayleighScatteringScale = _RayleighScatteringScale;


    // 把 Rayleigh 散射标高写入结构体
    // 用于计算 Rayleigh 密度随高度的指数衰减
    param.RayleighScatteringScalarHeight = _RayleighScatteringScalarHeight;


    // 把 Mie 散射强度缩放写入结构体
    // 用于控制气溶胶散射、雾霾感和太阳光晕强度
    param.MieScatteringScale = _MieScatteringScale;


    // 把 Mie 各向异性参数写入结构体
    // 后续通常用于 Mie 相函数，控制前向散射强弱
    param.MieAnisotropy = _MieAnisotropy;


    // 把 Mie 散射标高写入结构体
    // 用于计算 Mie 粒子密度随高度的指数衰减
    param.MieScatteringScalarHeight = _MieScatteringScalarHeight;


    // 把臭氧吸收强度写入结构体
    // 用于控制臭氧对不同波段光线的吸收影响
    param.OzoneAbsorptionScale = _OzoneAbsorptionScale;


    // 把臭氧层中心高度写入结构体
    // 用于计算臭氧密度在高度方向上的分布中心
    param.OzoneLevelCenterHeight = _OzoneLevelCenterHeight;


    // 把臭氧层宽度写入结构体
    // 用于控制臭氧层在高度方向上的影响范围
    param.OzoneLevelWidth = _OzoneLevelWidth;


    // 返回已经填充完整的大气参数结构体
    // 后续大气散射函数可以统一使用这个 param 作为输入
    return param;
}


// 结束 include guard
// 与最开始的 #ifndef __ATMOSPHERE_PARAMETER__ 对应
#endif