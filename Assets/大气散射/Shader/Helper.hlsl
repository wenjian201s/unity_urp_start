// 防止头文件被重复包含
// 如果 __ATMOSPHERE_HELPER__ 没有被定义过，则继续编译该文件内容
#ifndef __ATMOSPHERE_HELPER__

// 定义 __ATMOSPHERE_HELPER__ 宏
// 后续如果其他 HLSL 文件再次 include 本文件，就不会重复编译这里的代码
#define __ATMOSPHERE_HELPER__


// 如果 PI 没有被定义过，则定义 PI
// 这样可以避免和其他文件中的 PI 定义冲突
#ifndef PI

// 定义圆周率常量
// 大气散射中经常需要球面坐标、角度转换和相函数计算，因此 PI 是常用常量
#define PI 3.14159265359

// 结束 PI 的条件编译判断
#endif


// ------------------------------------------------------------
// 函数：UVToViewDir
// 作用：把二维 UV 坐标转换成三维单位方向向量
//
// 技术原理：
// 使用球面坐标系进行转换。
// uv.x 控制水平方向角 phi
// uv.y 控制垂直方向角 theta
//
// 常用于：
// 1. 根据 Sky View LUT 的 UV 还原天空方向
// 2. 根据 LUT 坐标得到一条视线方向
// 3. 将二维纹理坐标映射到球面方向
// ------------------------------------------------------------
float3 UVToViewDir(float2 uv)
{
    // 根据 uv.y 计算极角 theta
    // uv.y = 0 时，theta = PI，对应球面底部方向
    // uv.y = 1 时，theta = 0，对应球面顶部方向
    // 这里使用 1.0 - uv.y 是为了让 UV 的上方对应天空上方
    float theta = (1.0 - uv.y) * PI;

    // 根据 uv.x 计算方位角 phi
    // uv.x 从 [0, 1] 映射到 [-PI, PI]
    // 也就是水平环绕一整圈
    float phi = (uv.x * 2 - 1) * PI;
    
    // 球面坐标转笛卡尔坐标的 x 分量
    // sin(theta) 表示水平方向半径
    // cos(phi) 表示在 x 轴方向的投影
    float x = sin(theta) * cos(phi);

    // 球面坐标转笛卡尔坐标的 z 分量
    // sin(theta) 表示水平方向半径
    // sin(phi) 表示在 z 轴方向的投影
    float z = sin(theta) * sin(phi);

    // 球面坐标转笛卡尔坐标的 y 分量
    // cos(theta) 表示竖直方向高度
    // theta = 0 时 y = 1，表示正上方
    // theta = PI 时 y = -1，表示正下方
    float y = cos(theta);

    // 返回三维方向向量
    // 由于球面坐标公式本身生成的是单位球面上的点，因此该方向理论上长度为 1
    return float3(x, y, z);
}


// ------------------------------------------------------------
// 函数：ViewDirToUV
// 作用：把三维方向向量转换成二维 UV 坐标
//
// 技术原理：
// 这是 UVToViewDir 的反向过程。
// 使用 atan2 得到水平角度 phi。
// 使用 asin 得到垂直角度。
// 然后把角度范围归一化到 [0, 1]。
//
// 常用于：
// 1. 根据视线方向查询 Sky View LUT
// 2. 根据太阳方向查询某些方向性 LUT
// 3. 把单位球方向压缩到二维纹理坐标
// ------------------------------------------------------------
float2 ViewDirToUV(float3 v)
{
    // 根据三维方向计算球面角度
    // atan2(v.z, v.x) 得到水平角 phi，范围通常是 [-PI, PI]
    // asin(v.y) 得到垂直角，范围是 [-PI/2, PI/2]
    float2 uv = float2(atan2(v.z, v.x), asin(v.y));

    // 把角度缩放到归一化范围
    // x 除以 2PI，把水平一整圈映射到 [-0.5, 0.5]
    // y 除以 PI，把垂直半圈映射到 [-0.5, 0.5]
    uv /= float2(2.0 * PI, PI);

    // 把 [-0.5, 0.5] 平移到 [0, 1]
    // 这样就可以作为普通纹理 UV 使用
    uv += float2(0.5, 0.5);

    // 返回二维 UV 坐标
    return uv; 
}


// ------------------------------------------------------------
// 函数：RayIntersectSphere
// 作用：计算射线与球体的交点距离
//
// 参数：
// center   球心位置
// radius   球体半径
// rayStart 射线起点
// rayDir   射线方向，通常要求是单位向量
//
// 返回：
// 返回射线从 rayStart 出发，沿 rayDir 方向命中球面的距离 t。
// 如果没有命中球体，返回 -1。
//
// 技术原理：
// 使用几何法求射线和球体交点。
// OS = 球心到射线起点的距离
// SH = 球心向射线方向的投影距离
// OH = 球心到射线的最近距离
// PH = 半弦长
// t1 / t2 = 两个交点距离
//
// 常用于：
// 1. 判断视线是否进入大气层
// 2. 判断视线是否击中星球地表
// 3. 计算 ray marching 的最大积分距离
// ------------------------------------------------------------
float RayIntersectSphere(float3 center, float radius, float3 rayStart, float3 rayDir)
{
    float3 centerToRayStart = center - rayStart;
    float OS2 = dot(centerToRayStart, centerToRayStart);

    // 计算球心方向在射线方向上的投影长度
    // dot(center - rayStart, rayDir) 表示从射线起点看，球心在射线方向上的前后位置
    // 注意：这里默认 rayDir 是归一化方向，否则投影距离不准确
    float SH = dot(centerToRayStart, rayDir);

    // 计算球心到射线的垂直距离
    // 根据直角三角形：OH^2 = OS^2 - SH^2
    // OH 是判断射线是否穿过球体的关键
    float OH2 = max(0.0, OS2 - SH * SH);
    float radius2 = radius * radius;

    // ray miss sphere
    // 如果球心到射线的最近距离 OH 大于球半径，说明射线没有碰到球
    // 返回 -1 表示没有交点
    if(OH2 > radius2) return -1;

    // 计算射线穿过球体时，从最近点 H 到交点 P 的半弦长
    // 根据直角三角形：PH^2 = radius^2 - OH^2
    float PH = sqrt(max(0.0, radius2 - OH2));

    // use min distance
    // 计算射线进入球体的第一个交点距离
    // t1 是靠近射线起点的交点
    float t1 = SH - PH;

    // 计算射线离开球体的第二个交点距离
    // t2 是远离射线起点的交点
    float t2 = SH + PH;

    // 如果 t1 小于 0，说明第一个交点在射线起点后方
    // 这种情况通常表示射线起点在球体内部，或者靠近球体内部
    // 此时选择 t2，表示射线离开球体的交点
    // 否则选择 t1，表示射线进入球体的交点
    float t = (t1 < 0) ? t2 : t1;

    // 返回最终交点距离
    // 外部可以通过 rayStart + rayDir * t 得到交点世界坐标
    return t;
}


// ------------------------------------------------------------
// 函数：UvToTransmittanceLutParams
// 作用：把 Transmittance LUT 的二维 UV 坐标转换成物理参数 mu 和 r
//
// 参数：
// bottomRadius 星球半径，也就是大气底部半径
// topRadius    大气层顶部半径，通常是 PlanetRadius + AtmosphereHeight
// uv           当前 Transmittance LUT 的纹理坐标
// mu           输出参数，表示视线方向和局部竖直方向的夹角余弦
// r            输出参数，表示当前采样点到星球中心的距离
//
// 技术原理：
// Transmittance LUT 通常不是简单线性存储高度和角度。
// 为了更均匀地分配采样精度，它使用一种基于几何距离的参数化方式。
// 这套映射方式常见于物理大气散射 LUT，例如 Bruneton 风格的预计算大气模型。
// ------------------------------------------------------------
void UvToTransmittanceLutParams(float bottomRadius, float topRadius, float2 uv, out float mu, out float r)
{
    // 取 uv.x 作为角度相关参数
    // 它不是直接的 mu，而是经过非线性映射后的 x_mu
    float x_mu = uv.x;

    // 取 uv.y 作为高度相关参数
    // 它不是直接的高度，而是经过非线性映射后的 x_r
    float x_r = uv.y;

    // 计算大气层几何高度 H
    // H = sqrt(topRadius^2 - bottomRadius^2)
    //
    // 几何意义：
    // 从地表切线方向到大气顶边界的最大距离相关量。
    // 这是 Transmittance LUT 参数化中的一个重要归一化尺度。
    //
    // max(0.0f, ...) 用于避免浮点误差导致 sqrt 输入为负数
    float H = sqrt(max(0.0f, topRadius * topRadius - bottomRadius * bottomRadius));

    // 根据 x_r 计算 rho
    // rho 是当前高度对应的辅助几何量
    // x_r 从 [0, 1] 映射到 [0, H]
    float rho = H * x_r;

    // 根据 rho 反推出当前点到星球中心的距离 r
    // r^2 = rho^2 + bottomRadius^2
    //
    // 当 x_r = 0 时，rho = 0，r = bottomRadius，表示地表附近
    // 当 x_r = 1 时，rho = H，r = topRadius，表示大气顶端
    r = sqrt(max(0.0f, rho * rho + bottomRadius * bottomRadius));

    // 计算从当前高度 r 沿垂直向上方向到大气顶部的最短距离
    // 也就是当前点到 topRadius 的径向距离
    float d_min = topRadius - r;

    // 计算从当前高度出发，沿接近切线方向到大气边界的最大距离
    // rho + H 是该参数化下的最大路径距离
    float d_max = rho + H;

    // 根据 x_mu 在 [d_min, d_max] 之间插值得到距离 d
    // d 可以理解为从当前点沿某个方向到大气顶边界的路径长度
    float d = d_min + x_mu * (d_max - d_min);

    // 根据几何关系从 d 反推 mu
    //
    // mu 表示：
    // 视线方向和当前位置局部竖直向上方向之间夹角的余弦值。
    //
    // mu = 1  表示向上看
    // mu = 0  表示水平看
    // mu = -1 表示向下看
    //
    // 如果 d == 0，说明当前点已经在大气顶端，并且没有传播距离，
    // 此时直接令 mu = 1，避免除以 0
    mu = d == 0.0f ? 1.0f : (H * H - rho * rho - d * d) / (2.0f * r * d);

    // 把 mu 限制在 [-1, 1] 范围
    // 防止浮点误差导致 acos、几何计算或 LUT 查询出现非法值
    mu = clamp(mu, -1.0f, 1.0f);
}


// ------------------------------------------------------------
// 函数：GetTransmittanceLutUv
// 作用：把物理参数 mu 和 r 转换成 Transmittance LUT 的二维 UV
//
// 参数：
// bottomRadius 星球半径，也就是大气底部半径
// topRadius    大气层顶部半径
// mu           视线方向和局部竖直向上方向的夹角余弦
// r            当前点到星球中心的距离
//
// 返回：
// 返回用于采样 Transmittance LUT 的二维 UV 坐标
//
// 技术原理：
// 这是 UvToTransmittanceLutParams 的反向映射。
// 输入物理空间参数 r 和 mu，计算出对应的 LUT 坐标。
// ------------------------------------------------------------
float2 GetTransmittanceLutUv(float bottomRadius, float topRadius, float mu, float r)
{
    // 计算大气层几何高度 H
    // H = sqrt(topRadius^2 - bottomRadius^2)
    // 用作高度参数化和距离参数化的归一化尺度
    float H = sqrt(max(0.0f, topRadius * topRadius - bottomRadius * bottomRadius));

    // 根据当前半径 r 计算 rho
    // rho = sqrt(r^2 - bottomRadius^2)
    //
    // 当 r = bottomRadius 时，rho = 0，表示地表
    // 当 r = topRadius 时，rho = H，表示大气顶部
    float rho = sqrt(max(0.0f, r * r - bottomRadius * bottomRadius));

    // 计算射线从当前点沿方向 mu 到达大气顶边界的二次方程判别式
    //
    // 几何背景：
    // 射线位置为：
    // p(t) = p0 + t * dir
    //
    // 大气顶边界为球：
    // |p(t)|^2 = topRadius^2
    //
    // 解这个二次方程可以得到从当前点到大气顶边界的距离 d
    float discriminant = r * r * (mu * mu - 1.0f) + topRadius * topRadius;

    // 计算从当前点沿给定方向到大气顶部的距离 d
    //
    // 公式来源于射线与大气顶球体求交：
    // d = -r * mu + sqrt(discriminant)
    //
    // max(0.0f, ...) 防止数值误差产生负距离
	float d = max(0.0f, (-r * mu + sqrt(discriminant)));

    // 计算当前高度沿竖直向上方向到大气顶端的最短距离
    float d_min = topRadius - r;

    // 计算当前高度对应的最大参数化距离
    // 通常对应接近切线方向的最长大气路径
    float d_max = rho + H;

    // 把真实路径距离 d 映射到 [0, 1] 的 x_mu
    // 这个 x_mu 就是 Transmittance LUT 的横向 UV
    float x_mu = (d - d_min) / (d_max - d_min);

    // 把高度辅助参数 rho 映射到 [0, 1]
    // 这个 x_r 就是 Transmittance LUT 的纵向 UV
    float x_r = rho / H;

    // 返回 Transmittance LUT 的采样坐标
    // x 表示方向 / 路径距离参数
    // y 表示高度参数
    return float2(x_mu, x_r);
}


// 结束 include guard
// 与最开始的 #ifndef __ATMOSPHERE_HELPER__ 对应
#endif
