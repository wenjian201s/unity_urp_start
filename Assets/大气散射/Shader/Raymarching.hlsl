// 防止该头文件被重复 include
// 如果 __ATMOSPHERE_RAYMARCHING__ 没有被定义过，则继续编译本文件
#ifndef __ATMOSPHERE_RAYMARCHING__

// 定义 __ATMOSPHERE_RAYMARCHING__ 宏
// 后续其他文件再次 include 本文件时，会因为该宏已存在而跳过，避免重复定义函数
#define __ATMOSPHERE_RAYMARCHING__


// 引入大气辅助函数文件
// 里面通常包含 PI、射线与球体求交、Transmittance LUT 坐标映射等函数
#include "Helper.hlsl"

// 引入散射计算文件
// 里面通常包含 RayleighCoefficient、MieCoefficient、OzoneAbsorption、Scattering 等函数
#include "Scattering.hlsl"

// 引入大气参数封装文件
// 里面提供 AtmosphereParameter 结构体参数的构造函数 GetAtmosphereParameter()
#include "AtmosphereParameter.hlsl"


// ------------------------------------------------------------
// 函数：TransmittanceToAtmosphere
// 作用：通过查表方式，计算任意点 p 沿任意方向 dir 到大气层边缘的 transmittance
//
// 技术原理：
// Transmittance LUT 已经预计算了不同高度 r、不同方向夹角 mu 下，
// 光线从当前位置传播到大气外边界时的透射率。
// 这里根据 p 和 dir 计算出 r 与 mu，再转换成 LUT 的 uv 进行采样。
// ------------------------------------------------------------
float3 TransmittanceToAtmosphere(in AtmosphereParameter param, float3 p, float3 dir, Texture2D lut, SamplerState spl)
{
    // 大气底部半径，也就是星球半径
    // 对应地表或海平面所在球面
    float bottomRadius = param.PlanetRadius;

    // 大气顶部半径
    // 等于星球半径 + 大气层高度
    float topRadius = param.PlanetRadius + param.AtmosphereHeight;

    // 计算当前位置 p 的局部向上方向
    // 因为大气模型是球形的，所以从星球中心指向 p 的方向就是局部上方向
    float3 upVector = normalize(p);

    // 计算视线方向 dir 与局部上方向 upVector 的夹角余弦
    // cos_theta = 1 表示向上看
    // cos_theta = 0 表示水平看
    // cos_theta = -1 表示向下看
    float cos_theta = dot(upVector, dir);

    // 计算当前位置 p 到星球中心的距离
    // 这个距离 r 用于描述当前点在大气层中的高度
    float r = length(p);

    // 根据物理参数 bottomRadius、topRadius、cos_theta、r
    // 计算用于采样 Transmittance LUT 的二维 UV
    float2 uv = GetTransmittanceLutUv(bottomRadius, topRadius, cos_theta, r);

    // 从透射率 LUT 中采样 RGB 透射率
    // SampleLevel(..., 0) 表示采样 mip 0，避免 mipmap 影响物理精度
    return lut.SampleLevel(spl, uv, 0).rgb;
}


// ------------------------------------------------------------
// 函数：Transmittance
// 作用：直接通过积分方式，计算任意两点 p1、p2 之间的 transmittance
//
// 技术原理：
// 透射率公式：
// T = exp(-∫ extinction ds)
//
// extinction = scattering + absorption
//
// 这里沿 p1 到 p2 的线段做 32 次采样，累积消光系数，
// 最后用 exp(-sum) 得到光线穿过这段路径后的剩余比例。
// ------------------------------------------------------------
float3 Transmittance(in AtmosphereParameter param, float3 p1, float3 p2)
{
    // 设置积分采样步数
    // 采样数越高越准确，但性能开销越大
    const int N_SAMPLE = 32;

    // 计算 p1 到 p2 的距离
    float3 delta = p2 - p1;
    float distance = length(delta);

    if(distance <= 0.001)
        return 1.0.xxx;

    // 计算从 p1 指向 p2 的单位方向
    float3 dir = delta / distance;

    // 计算每一步 ray marching 的步长
    float ds = distance / float(N_SAMPLE);

    // 初始化消光积分累积值
    // RGB 分别代表不同波长通道的累计 optical depth
    float3 sum = 0.0;

    // 将第一个采样点放在第一个步长的中点
    // 中点采样比端点采样更加稳定，也更接近数值积分中的 midpoint rule
    float3 p = p1 + (dir * ds) * 0.5;

    // 沿 p1 到 p2 的路径进行 N_SAMPLE 次采样
    for(int i=0; i<N_SAMPLE; i++)
    {
        // 计算当前采样点相对星球表面的高度
        // length(p) 是采样点到星球中心的距离
        // 减去 PlanetRadius 后得到海拔高度
        float h = length(p) - param.PlanetRadius;

        // 计算当前高度处的散射系数
        // RayleighCoefficient 表示空气分子散射
        // MieCoefficient 表示气溶胶 / 水汽 / 尘埃散射
        float3 scattering = RayleighCoefficient(param, h) + MieCoefficient(param, h);

        // 计算当前高度处的吸收系数
        // OzoneAbsorption 表示臭氧吸收
        // MieAbsorption 表示 Mie 粒子的吸收项
        float3 absorption = OzoneAbsorption(param, h) + MieAbsorption(param, h);

        // 消光系数 extinction = scattering + absorption
        // 它表示光线在传播过程中因为散射和吸收而损失的总比例
        float3 extinction = scattering + absorption;

        // 累积 optical depth
        // 每段贡献为 extinction * ds
        sum += extinction * ds;

        // 沿射线方向推进到下一个采样点
        p += dir * ds;
    }

    // 根据 Beer-Lambert 定律计算透射率
    // T = exp(-opticalDepth)
    return exp(-sum);
}


// ------------------------------------------------------------
// 函数：IntegralMultiScattering
// 作用：积分计算多重散射 LUT 中某个 texel 对应的多重散射结果
//
// 技术原理：
// 多重散射近似通常会在当前采样点 samplePoint 周围的整个球面方向上采样。
// 对每个方向进行 ray marching，累积二次散射源项 G_2 和散射反馈项 f_ms。
// 最终使用类似几何级数的形式：
// G_ALL = G_2 / (1 - f_ms)
//
// 这相当于把二次、三次、四次……更高阶散射用一个闭式近似合并。
// ------------------------------------------------------------
float3 IntegralMultiScattering(
    // 大气参数
    in AtmosphereParameter param,

    // 当前多重散射采样点
    float3 samplePoint,

    // 太阳光方向
    float3 lightDir,

    // 预计算好的透射率 LUT
    Texture2D _transmittanceLut,

    // 用于采样 LUT 的线性 Clamp 采样器
    SamplerState samplerLinearClamp)
{
    // 球面方向采样数量
    // 每个方向都要做一次 ray marching，数量越高结果越稳定，但性能越贵
    const int N_DIRECTION = 64;

    // 每个方向上的步进采样数量
    const int N_SAMPLE = 32;

    // 预定义的 64 个球面随机采样方向
    // 用于近似对整个球面 4π 立体角做积分
    float3 RandomSphereSamples[64] = {

        // 第 0 个球面采样方向
        float3(-0.7838,-0.620933,0.00996137),

        // 第 1 个球面采样方向
        float3(0.106751,0.965982,0.235549),

        // 第 2 个球面采样方向
        float3(-0.215177,-0.687115,-0.693954),

        // 第 3 个球面采样方向
        float3(0.318002,0.0640084,-0.945927),

        // 第 4 个球面采样方向
        float3(0.357396,0.555673,0.750664),

        // 第 5 个球面采样方向
        float3(0.866397,-0.19756,0.458613),

        // 第 6 个球面采样方向
        float3(0.130216,0.232736,-0.963783),

        // 第 7 个球面采样方向
        float3(-0.00174431,0.376657,0.926351),

        // 第 8 个球面采样方向
        float3(0.663478,0.704806,-0.251089),

        // 第 9 个球面采样方向
        float3(0.0327851,0.110534,-0.993331),

        // 第 10 个球面采样方向
        float3(0.0561973,0.0234288,0.998145),

        // 第 11 个球面采样方向
        float3(0.0905264,-0.169771,0.981317),

        // 第 12 个球面采样方向
        float3(0.26694,0.95222,-0.148393),

        // 第 13 个球面采样方向
        float3(-0.812874,-0.559051,-0.163393),

        // 第 14 个球面采样方向
        float3(-0.323378,-0.25855,-0.910263),

        // 第 15 个球面采样方向
        float3(-0.1333,0.591356,-0.795317),

        // 第 16 个球面采样方向
        float3(0.480876,0.408711,0.775702),

        // 第 17 个球面采样方向
        float3(-0.332263,-0.533895,-0.777533),

        // 第 18 个球面采样方向
        float3(-0.0392473,-0.704457,-0.708661),

        // 第 19 个球面采样方向
        float3(0.427015,0.239811,0.871865),

        // 第 20 个球面采样方向
        float3(-0.416624,-0.563856,0.713085),

        // 第 21 个球面采样方向
        float3(0.12793,0.334479,-0.933679),

        // 第 22 个球面采样方向
        float3(-0.0343373,-0.160593,-0.986423),

        // 第 23 个球面采样方向
        float3(0.580614,0.0692947,0.811225),

        // 第 24 个球面采样方向
        float3(-0.459187,0.43944,0.772036),

        // 第 25 个球面采样方向
        float3(0.215474,-0.539436,-0.81399),

        // 第 26 个球面采样方向
        float3(-0.378969,-0.31988,-0.868366),

        // 第 27 个球面采样方向
        float3(-0.279978,-0.0109692,0.959944),

        // 第 28 个球面采样方向
        float3(0.692547,0.690058,0.210234),

        // 第 29 个球面采样方向
        float3(0.53227,-0.123044,-0.837585),

        // 第 30 个球面采样方向
        float3(-0.772313,-0.283334,-0.568555),

        // 第 31 个球面采样方向
        float3(-0.0311218,0.995988,-0.0838977),

        // 第 32 个球面采样方向
        float3(-0.366931,-0.276531,-0.888196),

        // 第 33 个球面采样方向
        float3(0.488778,0.367878,-0.791051),

        // 第 34 个球面采样方向
        float3(-0.885561,-0.453445,0.100842),

        // 第 35 个球面采样方向
        float3(0.71656,0.443635,0.538265),

        // 第 36 个球面采样方向
        float3(0.645383,-0.152576,-0.748466),

        // 第 37 个球面采样方向
        float3(-0.171259,0.91907,0.354939),

        // 第 38 个球面采样方向
        float3(-0.0031122,0.9457,0.325026),

        // 第 39 个球面采样方向
        float3(0.731503,0.623089,-0.276881),

        // 第 40 个球面采样方向
        float3(-0.91466,0.186904,0.358419),

        // 第 41 个球面采样方向
        float3(0.15595,0.828193,-0.538309),

        // 第 42 个球面采样方向
        float3(0.175396,0.584732,0.792038),

        // 第 43 个球面采样方向
        float3(-0.0838381,-0.943461,0.320707),

        // 第 44 个球面采样方向
        float3(0.305876,0.727604,0.614029),

        // 第 45 个球面采样方向
        float3(0.754642,-0.197903,-0.62558),

        // 第 46 个球面采样方向
        float3(0.217255,-0.0177771,-0.975953),

        // 第 47 个球面采样方向
        float3(0.140412,-0.844826,0.516287),

        // 第 48 个球面采样方向
        float3(-0.549042,0.574859,-0.606705),

        // 第 49 个球面采样方向
        float3(0.570057,0.17459,0.802841),

        // 第 50 个球面采样方向
        float3(-0.0330304,0.775077,0.631003),

        // 第 51 个球面采样方向
        float3(-0.938091,0.138937,0.317304),

        // 第 52 个球面采样方向
        float3(0.483197,-0.726405,-0.48873),

        // 第 53 个球面采样方向
        float3(0.485263,0.52926,0.695991),

        // 第 54 个球面采样方向
        float3(0.224189,0.742282,-0.631472),

        // 第 55 个球面采样方向
        float3(-0.322429,0.662214,-0.676396),

        // 第 56 个球面采样方向
        float3(0.625577,-0.12711,0.769738),

        // 第 57 个球面采样方向
        float3(-0.714032,-0.584461,-0.385439),

        // 第 58 个球面采样方向
        float3(-0.0652053,-0.892579,-0.446151),

        // 第 59 个球面采样方向
        float3(0.408421,-0.912487,0.0236566),

        // 第 60 个球面采样方向
        float3(0.0900381,0.319983,0.943135),

        // 第 61 个球面采样方向
        float3(-0.708553,0.483646,0.513847),

        // 第 62 个球面采样方向
        float3(0.803855,-0.0902273,0.587942),

        // 第 63 个球面采样方向
        float3(-0.0555802,-0.374602,-0.925519),
    };

    // 均匀相函数
    // 1 / 4π 表示各向同性散射，即向所有方向均匀散射
    const float uniform_phase = 1.0 / (4.0 * PI);

    // 每个随机方向代表的球面立体角权重
    // 整个球面立体角是 4π，均分给 N_DIRECTION 个方向
    const float sphereSolidAngle = 4.0 * PI / float(N_DIRECTION);
    
    // G_2 表示二次散射源项
    // 可以理解为太阳光经过一次散射后，再散射到当前点附近产生的间接光贡献
    float3 G_2 = float3(0, 0, 0);

    // f_ms 表示多重散射反馈比例
    // 用于估计三次、四次以及更高阶散射的能量放大项
    float3 f_ms = float3(0, 0, 0);


    // 遍历球面上的 64 个随机方向
    // 用离散采样近似整个球面方向积分
    for(int i=0; i<N_DIRECTION; i++)
    {
        // 从预定义数组中取一个球面采样方向
        // 这个方向代表从 samplePoint 出发的一条积分射线
        float3 viewDir = RandomSphereSamples[i];

        // 计算当前采样方向与大气层外球的交点距离
        // 得到这条射线在大气中的最大传播距离
        float dis = RayIntersectSphere(float3(0,0,0), param.PlanetRadius + param.AtmosphereHeight, samplePoint, viewDir);

        // 计算当前采样方向与星球地表球体的交点距离
        // 如果射线打到地面，则积分应该在地面处终止
        float d = RayIntersectSphere(float3(0,0,0), param.PlanetRadius, samplePoint, viewDir);

        // 如果射线会碰到地表，则取大气边界距离和地表距离中更近的那个
        // 这样可以避免积分穿过地面进入星球内部
        if(d > 0) dis = min(dis, d);

        // 计算当前方向上的步进长度
        float ds = dis / float(N_SAMPLE);

        // 当前方向的第一个采样点，放在第一个步长的中点
        // 中点采样可以降低数值积分偏差
        float3 p = samplePoint + (viewDir * ds) * 0.5;

        // 初始化从 samplePoint 到当前采样点之间的累计 optical depth
        // opticalDepth 越大，透射率 exp(-opticalDepth) 越低
        float3 opticalDepth = float3(0, 0, 0);


        // 沿当前球面采样方向进行 ray marching
        for(int j=0; j<N_SAMPLE; j++)
        {
            // 计算当前采样点的海拔高度
            float h = length(p) - param.PlanetRadius;

            // 计算当前高度处的散射系数 sigma_s
            // RayleighCoefficient 是分子散射
            // MieCoefficient 是气溶胶散射
            float3 sigma_s = RayleighCoefficient(param, h) + MieCoefficient(param, h);  // scattering

            // 计算当前高度处的吸收系数 sigma_a
            // OzoneAbsorption 是臭氧吸收
            // MieAbsorption 是气溶胶吸收
            float3 sigma_a = OzoneAbsorption(param, h) + MieAbsorption(param, h);       // absorption

            // 计算总消光系数 sigma_t
            // 消光 = 散射 + 吸收
            float3 sigma_t = sigma_s + sigma_a;                                         // extinction

            // 沿当前方向累积 optical depth
            // 这表示 samplePoint 到当前 p 之间的介质消光积分
            opticalDepth += sigma_t * ds;

            // 查询太阳光从当前采样点 p 沿 lightDir 方向到大气边界的透射率
            // 用来描述太阳光到达 p 时被大气削弱了多少
            float3 t1 = TransmittanceToAtmosphere(param, p, lightDir, _transmittanceLut, samplerLinearClamp);

            // 计算当前点 p 处，太阳光 lightDir 被散射到 viewDir 方向的散射项
            // 内部通常包含 Rayleigh / Mie 系数和相函数
            float3 s  = Scattering(param, p, lightDir, viewDir);

            // 计算从 samplePoint 到当前采样点 p 的视线路径透射率
            // 由 opticalDepth 通过 Beer-Lambert 定律转换而来
            float3 t2 = exp(-opticalDepth);
            
            // 累积二次散射项 G_2
            //
            // t1：太阳光到 p 的透射率
            // s ：p 点处太阳光向 viewDir 方向的一次散射
            // t2：p 到 samplePoint 的透射率
            // uniform_phase：假设二次散射后向各方向均匀分布
            // ds：当前积分段长度
            //
            // 这里用 1.0 代替太阳光颜色，因为太阳光颜色和强度会在后续统一乘上
            G_2  += t1 * s * t2 * uniform_phase * ds * 1.0;  

            // 累积多重散射反馈项 f_ms
            //
            // t2：从 p 回到 samplePoint 的透射率
            // sigma_s：当前点散射系数
            // uniform_phase：各向同性多重散射近似
            // ds：积分长度
            //
            // f_ms 表示光在大气中再次被散射的比例，用于后面 1 / (1 - f_ms)
            f_ms += t2 * sigma_s * uniform_phase * ds;

            // 推进到下一个采样点
            p += viewDir * ds;
        }
    }

    // 将方向积分结果乘以每个方向代表的立体角权重
    // 离散求和变成近似球面积分
    G_2 *= sphereSolidAngle;

    // 同样把反馈项转换成球面积分结果
    f_ms *= sphereSolidAngle;

    // 返回多重散射近似结果
    //
    // G_2 是二次散射贡献
    // 1 / (1 - f_ms) 用几何级数近似累积更高阶散射
    //
    // 物理含义类似：
    // G_ALL = G_2 + G_2*f_ms + G_2*f_ms^2 + ...
    //       = G_2 / (1 - f_ms)
    return G_2 * (1.0 / (1.0 - f_ms));
}


// ------------------------------------------------------------
// 函数：GetMultiScattering
// 作用：读取多重散射查找表，并结合当前位置的散射系数得到多重散射贡献
//
// 技术原理：
// MultiScattering LUT 通常以高度 h 和太阳天顶角 cosSunZenithAngle 为二维坐标。
// LUT 中存的是当前条件下的高阶散射近似结果 G_ALL。
// 最终乘以当前位置的散射系数 sigma_s，得到该点的多重散射源项。
// ------------------------------------------------------------
float3 GetMultiScattering(in AtmosphereParameter param, float3 p, float3 lightDir, Texture2D lut, SamplerState spl)
{
    // 计算当前点相对地表的高度
    float h = length(p) - param.PlanetRadius;

    // 计算当前高度处的总散射系数
    // 多重散射贡献需要乘以当前介质的散射能力
    float3 sigma_s = RayleighCoefficient(param, h) + MieCoefficient(param, h); 
    
    // 计算太阳方向与当前位置局部上方向之间的夹角余弦
    // normalize(p) 是球形大气中的局部上方向
    float cosSunZenithAngle = dot(normalize(p), lightDir);

    // 构造多重散射 LUT 的采样 UV
    //
    // uv.x：把 cosSunZenithAngle 从 [-1, 1] 映射到 [0, 1]
    // uv.y：把高度 h 从 [0, AtmosphereHeight] 映射到 [0, 1]
    float2 uv = float2(cosSunZenithAngle * 0.5 + 0.5, h / param.AtmosphereHeight);

    // 从 MultiScattering LUT 中读取高阶散射近似值
    float3 G_ALL = lut.SampleLevel(spl, uv, 0).rgb;
    
    // 乘以当前点的散射系数，得到当前采样点的多重散射贡献
    return G_ALL * sigma_s;
}


// ------------------------------------------------------------
// 函数：GetSkyView
// 作用：计算从 eyePos 沿 viewDir 方向看到的天空 / 大气颜色
//
// 参数：
// param                 大气参数
// eyePos                观察点，也就是相机在大气模型中的位置
// viewDir               视线方向
// lightDir              太阳光方向
// maxDis                最大积分距离，用于 Aerial Perspective 限制积分长度
// _transmittanceLut     透射率 LUT
// _multiScatteringLut   多重散射 LUT
// samplerLinearClamp    LUT 采样器
//
// 技术原理：
// 沿视线方向做 ray marching。
// 每个采样点累积：
// 1. 太阳光到采样点的透射率
// 2. 采样点向相机方向散射的单次散射
// 3. 采样点到相机的透射率
// 4. 多重散射 LUT 提供的高阶散射补偿
//
// 最终得到天空颜色或一段视线距离内的大气内散射。
// ------------------------------------------------------------
float3 GetSkyView(
    // 大气参数
    in AtmosphereParameter param,

    // 相机或观察点在大气模型中的位置
    float3 eyePos,

    // 从相机出发的视线方向
    float3 viewDir,

    // 太阳光方向
    float3 lightDir,

    // 最大积分距离
    // 如果大于 0，则限制积分到 maxDis
    // 如果为 0 或小于 0，则积分到大气边界或地面
    float maxDis, 

    // 透射率 LUT
    Texture2D _transmittanceLut,

    // 多重散射 LUT
    Texture2D _multiScatteringLut,

    // 线性 Clamp 采样器
    SamplerState samplerLinearClamp)
{
    // 设置视线方向上的积分采样步数
    const int N_SAMPLE = 32;

    // 初始化天空颜色累积结果
    float3 color = float3(0, 0, 0);

    // ------------------------------------------------------------
    // 计算视线与大气层、星球地表的交点
    // ------------------------------------------------------------

    // 计算视线与大气层外球的交点距离
    // 这决定天空积分的最远距离
    float dis = RayIntersectSphere(float3(0,0,0), param.PlanetRadius + param.AtmosphereHeight, eyePos, viewDir);

    // 计算视线与星球地表球体的交点距离
    // 如果射线打到地面，则大气积分应该在地面前结束
    float d = RayIntersectSphere(float3(0,0,0), param.PlanetRadius, eyePos, viewDir);

    // 如果视线没有击中大气层，则没有可积累的大气颜色，直接返回黑色
    if(dis < 0) return color; 

    // 如果视线会打到星球地表，则用地表交点限制积分距离
    // 防止 ray marching 穿入星球内部
    if(d > 0) dis = min(dis, d);

    // 如果外部传入了最大距离 maxDis，则进一步限制积分距离
    // 这使同一个函数可以复用于 Aerial Perspective LUT：
    // 只积分相机到某个距离 slice 之间的大气贡献
    if(maxDis > 0) dis = min(dis, maxDis);  // 带最长距离 maxDis 限制, 方便 aerial perspective lut 部分复用代码

    // 计算每一步的步长
    float ds = dis / float(N_SAMPLE);

    // 设置第一个采样点为第一段路径的中点
    // 使用 midpoint rule 可以提升积分稳定性
    float3 p = eyePos + (viewDir * ds) * 0.5;

    // 计算太阳光亮度
    // 太阳颜色乘太阳强度，作为最终散射光能量
    float3 sunLuminance = param.SunLightColor * param.SunLightIntensity;

    // 初始化视线方向上的累计 optical depth
    // 用于计算采样点到相机之间的透射率
    float3 opticalDepth = float3(0, 0, 0);


    // 沿视线方向进行 ray marching 积分
    for(int i=0; i<N_SAMPLE; i++)
    {
        // 积累沿途的湮灭系数
        // 当前采样点到星球表面的高度
        float h = length(p) - param.PlanetRadius;

        // 计算当前点的总消光系数
        // Rayleigh + Mie 是散射
        // Ozone + MieAbsorption 是吸收
        // 总消光决定光线在介质中损失多少
        float3 extinction = RayleighCoefficient(param, h) + MieCoefficient(param, h) +  // scattering
                            OzoneAbsorption(param, h) + MieAbsorption(param, h);        // absorption

        // 累积当前步长造成的 optical depth
        opticalDepth += extinction * ds;

        // 查询太阳光从采样点 p 沿 lightDir 到大气边缘的透射率
        // 代表太阳光到达当前采样点时还剩多少能量
        float3 t1 = TransmittanceToAtmosphere(param, p, lightDir, _transmittanceLut, samplerLinearClamp);

        // 计算当前采样点处，太阳光被散射进视线方向 viewDir 的散射强度
        // Scattering 内部通常包含 Rayleigh / Mie 散射系数和相函数
        float3 s  = Scattering(param, p, lightDir, viewDir);

        // 计算从相机到当前采样点这一段路径上的透射率
        // opticalDepth 是沿 viewDir 从 eyePos 到 p 的累积消光
        float3 t2 = exp(-opticalDepth);
        
        // ------------------------------------------------------------
        // 单次散射
        // ------------------------------------------------------------

        // 单次散射贡献：
        // t1：太阳光到采样点的透射率
        // s ：采样点处太阳光散射到视线方向的强度
        // t2：采样点到相机之间的透射率
        // ds：当前积分步长
        // sunLuminance：太阳颜色和强度
        float3 inScattering = t1 * s * t2 * ds * sunLuminance;

        // 把当前采样点的单次散射贡献累加到最终天空颜色
        color += inScattering;

        // ------------------------------------------------------------
        // 多重散射
        // ------------------------------------------------------------

        // 从 MultiScattering LUT 中读取当前点的多重散射近似贡献
        // 用于补偿二次及更高阶散射，让天空不会过暗
        float3 multiScattering = GetMultiScattering(param, p, lightDir, _multiScatteringLut, samplerLinearClamp);

        // 累积多重散射贡献
        //
        // multiScattering：当前点的高阶散射源项
        // t2：当前点到相机的透射率
        // ds：当前步长
        // sunLuminance：太阳光颜色和强度
        color += multiScattering * t2 * ds * sunLuminance;

        // 推进到下一个视线采样点
        p += viewDir * ds;
    }

    // 返回最终积分得到的天空颜色 / 大气内散射颜色
    return color;
}


// 结束 include guard
#endif
