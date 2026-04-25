// 防止该头文件被重复 include
// 如果 __ATMOSPHERE_SCATTERING__ 没有定义过，则继续编译本文件
#ifndef __ATMOSPHERE_SCATTERING__

// 定义 __ATMOSPHERE_SCATTERING__ 宏
// 后续其他文件再次 include 本文件时，会跳过本文件内容，避免结构体和函数重复定义
#define __ATMOSPHERE_SCATTERING__


// 如果 PI 没有被定义过，则定义 PI
// 这样可以避免和 Helper.hlsl 或其他文件中的 PI 定义冲突
#ifndef PI

// 定义圆周率常量
// 散射相函数中会频繁使用 4π、8π、16π 等球面积分相关常量
#define PI 3.14159265359

// 结束 PI 的条件编译
#endif


// ------------------------------------------------------------
// 大气参数结构体
// 该结构体把 C# / Unity Shader 全局变量封装成统一参数对象
// 后续所有散射、吸收、ray marching 函数都通过它读取大气参数
// ------------------------------------------------------------
struct AtmosphereParameter
{
    // 海平面高度
    // 用作世界空间高度到大气模型高度的参考基准
    float SeaLevel;

    // 星球半径
    // 用于球形大气模型中计算高度、球体求交、大气边界等
    float PlanetRadius;

    // 大气层高度
    // 大气顶部半径通常等于 PlanetRadius + AtmosphereHeight
    float AtmosphereHeight;

    // 太阳光强度
    // 控制太阳入射光的整体能量大小
    float SunLightIntensity;

    // 太阳光颜色
    // RGB 三通道表示太阳光颜色，后续会乘到散射结果上
    float3 SunLightColor;

    // 太阳圆盘角度
    // 可用于太阳盘渲染或太阳附近高亮区域控制
    // 当前这个文件中没有直接使用
    float SunDiskAngle;

    // Rayleigh 散射强度缩放参数
    // 理论上用于控制分子散射整体强度
    // 注意：当前 RayleighCoefficient() 中没有使用这个 scale
    float RayleighScatteringScale;

    // Rayleigh 散射标高
    // 控制空气分子密度随高度指数衰减的速度
    float RayleighScatteringScalarHeight;

    // Mie 散射强度缩放参数
    // 理论上用于控制气溶胶、水汽、尘埃等大粒子散射强度
    // 注意：当前 MieCoefficient() 中没有使用这个 scale
    float MieScatteringScale;

    // Mie 各向异性参数 g
    // 用于 Mie 相函数，控制前向散射强度
    float MieAnisotropy;

    // Mie 散射标高
    // 控制气溶胶密度随高度指数衰减的速度
    float MieScatteringScalarHeight;

    // 臭氧吸收强度缩放参数
    // 理论上用于控制臭氧吸收整体强度
    // 注意：当前 OzoneAbsorption() 中没有使用这个 scale
    float OzoneAbsorptionScale;

    // 臭氧层中心高度
    // 用于描述臭氧密度分布最高的位置
    float OzoneLevelCenterHeight;

    // 臭氧层宽度
    // 用于描述臭氧密度在高度方向上的分布范围
    float OzoneLevelWidth;
};


// 分隔注释
// 下面开始是 Rayleigh、Mie、Ozone 的具体物理函数
// ------------------------------------------------------------------------- //


// ------------------------------------------------------------
// 函数：RayleighCoefficient
// 作用：计算当前高度 h 处的 Rayleigh 散射系数
//
// 技术原理：
// Rayleigh 散射来自空气分子。
// 它对短波长蓝光更强，因此天空呈蓝色。
// 密度通常随高度按指数衰减：
// density = exp(-h / H_R)
//
// 返回值是 RGB 三通道散射系数。
// 蓝色通道最大，红色通道最小。
// ------------------------------------------------------------
float3 RayleighCoefficient(in AtmosphereParameter param, float h)
{
    h = max(h, 0.0);
    // Rayleigh 海平面散射系数
    // 单位通常可以理解为 1 / meter 或类似尺度
    // RGB 分别表示不同波长下的散射强度
    // 蓝光 B = 33.1 最大，绿光 G = 13.558 次之，红光 R = 5.802 最小
    // 所以 Rayleigh 散射会让天空偏蓝
    const float3 sigma = float3(5.802, 13.558, 33.1) * 1e-6;

    // 读取 Rayleigh 散射标高
    // H_R 越大，分子密度随高度衰减越慢
    float H_R = param.RayleighScatteringScalarHeight;

    // 根据高度 h 计算 Rayleigh 密度衰减
    // h 越高，rho_h 越小，表示高空空气分子密度降低
    float rho_h = exp(-(h / H_R));

    // 返回当前高度处的 Rayleigh 散射系数
    // 海平面系数 sigma 乘以高度密度 rho_h
    return sigma * rho_h * param.RayleighScatteringScale;
}


// ------------------------------------------------------------
// 函数：RayleiPhase
// 作用：计算 Rayleigh 散射相函数
//
// 技术原理：
// 相函数描述光从 lightDir 被散射到 viewDir 的方向分布。
// Rayleigh 相函数形式为：
// P_R(cosθ) = 3 / (16π) * (1 + cos²θ)
//
// 它关于前向和后向基本对称，侧向较弱。
// ------------------------------------------------------------
float RayleiPhase(in AtmosphereParameter param, float cos_theta)
{
    // 返回 Rayleigh 相函数值
    // cos_theta 是入射光方向和观察方向夹角的余弦
    // 1 + cos_theta^2 表示前向和后向散射较强，90 度方向较弱
    return (3.0 / (16.0 * PI)) * (1.0 + cos_theta * cos_theta);
}


// ------------------------------------------------------------
// 函数：MieCoefficient
// 作用：计算当前高度 h 处的 Mie 散射系数
//
// 技术原理：
// Mie 散射来自气溶胶、水汽、尘埃等较大粒子。
// 它对 RGB 的波长差异通常没有 Rayleigh 那么强，
// 所以这里使用三个通道相同的灰度散射系数。
// Mie 粒子主要集中在低空，因此也使用指数高度衰减。
// ------------------------------------------------------------
float3 MieCoefficient(in AtmosphereParameter param, float h)
{
    h = max(h, 0.0);
    // Mie 海平面散射系数
    // .xxx 表示把一个 float 扩展成 float3
    // 即 float3(3.996e-6, 3.996e-6, 3.996e-6)
    // 三通道相同，表示近似灰色散射
    const float3 sigma = (3.996 * 1e-6).xxx;

    // 读取 Mie 散射标高
    // 一般 Mie 标高比 Rayleigh 小，因为气溶胶、水汽更多集中在低空
    float H_M = param.MieScatteringScalarHeight;

    // 根据高度 h 计算 Mie 密度衰减
    // 高度越高，气溶胶密度越低
    float rho_h = exp(-(h / H_M));

    // 返回当前高度处的 Mie 散射系数
    return sigma * rho_h * param.MieScatteringScale;
}


// ------------------------------------------------------------
// 函数：MiePhase
// 作用：计算 Mie 散射相函数
//
// 技术原理：
// Mie 散射具有明显的方向性，通常以前向散射为主。
// 这里使用的是一种改写过的 Cornette-Shanks / Henyey-Greenstein 风格相函数。
// g 是各向异性参数：
// g = 0   表示近似各向同性
// g > 0   表示前向散射增强
// g 越接近 1，太阳附近光晕越集中、越强
// ------------------------------------------------------------
float MiePhase(in AtmosphereParameter param, float cos_theta)
{
    // 读取 Mie 各向异性参数 g
    // 该参数决定 Mie 散射向前方向集中的程度
    float g = param.MieAnisotropy;

    // 相函数归一化系数的一部分
    // 3 / 8π 是该 Mie 相函数形式中的常数项
    float a = 3.0 / (8.0 * PI);

    // 根据 g 构造能量归一化相关项
    // g 越大，散射越集中，归一化因子用于保持整体能量合理
    float b = (1.0 - g*g) / (2.0 + g*g);

    // 角度项
    // 与 Rayleigh 类似，也包含 1 + cos²θ
    float c = 1.0 + cos_theta*cos_theta;

    // 前向散射控制项
    // 当 cos_theta 接近 1 且 g 较大时，分母变小，Mie 相函数变大
    // 这会产生太阳附近明显的光晕和前向散射增强
    float d = pow(1.0 + g*g - 2*g*cos_theta, 1.5);
    
    // 返回最终 Mie 相函数
    // a、b 是归一化相关项
    // c / d 控制角度分布
    return a * b * (c / d);
}


// ------------------------------------------------------------
// 函数：MieAbsorption
// 作用：计算当前高度 h 处的 Mie 吸收系数
//
// 技术原理：
// Mie 粒子不仅会散射光，也可能吸收部分光能。
// 吸收项会进入 extinction：
// extinction = scattering + absorption
//
// 当前实现使用 RGB 相同的吸收系数，并按 Mie 高度密度指数衰减。
// ------------------------------------------------------------
float3 MieAbsorption(in AtmosphereParameter param, float h)
{
    h = max(h, 0.0);
    // Mie 吸收系数
    // 三通道相同，表示近似灰色吸收
    const float3 sigma = (4.4 * 1e-6).xxx;

    // 读取 Mie 标高
    // 吸收粒子的高度分布与 Mie 散射粒子使用同一个标高
    float H_M = param.MieScatteringScalarHeight;

    // 计算随高度变化的 Mie 粒子密度
    float rho_h = exp(-(h / H_M));

    // 返回当前高度处的 Mie 吸收系数
    return sigma * rho_h * param.MieScatteringScale;
}


// ------------------------------------------------------------
// 函数：OzoneAbsorption
// 作用：计算当前高度 h 处的臭氧吸收系数
//
// 技术原理：
// 臭氧层主要分布在某个高度附近，而不是从地面开始指数衰减。
// 这里使用一个三角形 / 帐篷函数分布：
// rho = max(0, 1 - abs(h - center) / width)
//
// 当 h = center 时，臭氧密度最大。
// 当 h 离 center 超过 width 时，臭氧密度为 0。
// ------------------------------------------------------------
float3 OzoneAbsorption(in AtmosphereParameter param, float h)
{
    h = max(h, 0.0);
    // 定义臭氧对 RGB 三个通道的吸收系数
    // 绿色通道吸收最强，红色次之，蓝色最弱
    // 这会影响日出日落和高空天空颜色
    #define sigma_lambda (float3(0.650f, 1.881f, 0.085f)) * 1e-6

    // 读取臭氧层中心高度
    // 臭氧吸收在该高度附近最强
    float center = param.OzoneLevelCenterHeight;

    // 读取臭氧层宽度
    // 控制臭氧层在高度方向上的厚度范围
    float width = param.OzoneLevelWidth;

    // 计算臭氧密度分布
    // abs(h - center) 表示当前高度离臭氧中心层有多远
    // 距离越远，rho 越低
    // max(0, ...) 保证密度不会小于 0
    float rho = max(0, 1.0 - (abs(h - center) / width));

    // 返回当前高度处的臭氧吸收系数
    // 臭氧吸收系数乘以高度密度分布
    return sigma_lambda * rho * param.OzoneAbsorptionScale;
}


// 分隔注释
// 下面开始组合 Rayleigh 和 Mie，得到真正用于单次散射积分的散射源项
// ------------------------------------------------------------------------- //


// ------------------------------------------------------------
// 函数：Scattering
// 作用：计算当前点 p 处，太阳光沿 lightDir 入射后，
//      被大气散射到 viewDir 方向上的单次散射强度
//
// 技术原理：
// 单次散射源项通常可以写成：
// scattering = β_R(h) * P_R(cosθ) + β_M(h) * P_M(cosθ)
//
// 其中：
// β_R 是 Rayleigh 散射系数
// P_R 是 Rayleigh 相函数
// β_M 是 Mie 散射系数
// P_M 是 Mie 相函数
//
// 这个函数只计算“当前点的局部散射项”。
// 完整天空颜色还需要在 Raymarching 中乘：
// 1. 太阳到当前点的透射率
// 2. 当前点到相机的透射率
// 3. 积分步长 ds
// 4. 太阳颜色和强度
// ------------------------------------------------------------
float3 Scattering(in AtmosphereParameter param, float3 p, float3 lightDir, float3 viewDir)
{
    // 计算太阳光方向和观察方向之间夹角的余弦
    // cos_theta 越接近 1，表示 viewDir 越接近 lightDir
    // 对 Mie 散射来说，这通常会产生强烈前向散射
    float cos_theta = dot(lightDir, viewDir);

    // 计算当前点 p 的海拔高度
    // length(p) 是点到星球中心的距离
    // 减去 PlanetRadius 得到距离地表的高度
    float h = length(p) - param.PlanetRadius;

    // 计算 Rayleigh 单次散射项
    // RayleighCoefficient 给出当前高度的分子散射系数
    // RayleiPhase 给出当前角度下的方向分布权重
    float3 rayleigh = RayleighCoefficient(param, h) * RayleiPhase(param, cos_theta);

    // 计算 Mie 单次散射项
    // MieCoefficient 给出当前高度的气溶胶散射系数
    // MiePhase 给出当前角度下的方向分布权重
    float3 mie = MieCoefficient(param, h) * MiePhase(param, cos_theta);

    // 返回当前点的总单次散射源项
    // 后续在 GetSkyView() 中会乘透射率、太阳亮度和步长后累积
    return rayleigh + mie;
}


// 结束 include guard
#endif
