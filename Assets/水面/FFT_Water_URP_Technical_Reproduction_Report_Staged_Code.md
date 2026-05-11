# FFT 水面渲染 URP 技术复现实验文档：分阶段代码实现版

> 本文档按照实际执行顺序编写：先解释 `FFTWater.compute` 的 GPU 频谱与 FFT 计算，再解释 `FFTWaterURP.shader` 的 URP 渲染流程，最后解释 `FFTWater.cs` 如何在 Unity 中创建资源、调度 ComputeShader 并把结果传给 URP Shader。  
> 注意：你之前口述的“FTT”在本文按代码真实含义统一写为 **FFT**。

---

# 0. 实验目标

本实验要复现的是一个基于频域海洋模型的实时水面系统。它不是简单的 Gerstner Wave 叠加，而是通过 GPU ComputeShader 生成海浪频谱，再通过二维逆 FFT 得到空间域位移、斜率和泡沫数据，最后在 URP 前向渲染中完成水面细分、顶点位移和 PBR/菲涅尔水面着色。

整体流程如下：

```mermaid
flowchart TD
    A[Inspector: 风速/风向/fetch/泡沫/PBR参数] --> B[FFTWater.cs]
    B --> C[创建 Mesh / Material / RenderTexture2DArray / ComputeBuffer]
    C --> D[CS_InitializeSpectrum: 生成初始频谱 h0]
    D --> E[CS_PackSpectrumConjugate: 打包 h0 和 h0*(-k)]
    E --> F[CS_UpdateSpectrumForFFT: 生成 h(k,t)]
    F --> G[CS_HorizontalFFT: 行方向逆FFT]
    G --> H[CS_VerticalFFT: 列方向逆FFT]
    H --> I[CS_AssembleMaps: 位移/斜率/泡沫/浮力贴图]
    I --> J[FFTWaterURP.shader]
    J --> K[曲面细分 + 顶点位移 + 法线恢复 + 水面光照]
```

---

# 1. 总体数学模型

水面高度场可写成频域叠加：

$$
\eta(\mathbf{x},t)=\sum_{\mathbf{k}}\tilde{h}(\mathbf{k},t)e^{i\mathbf{k}\cdot\mathbf{x}}
$$

其中 $\mathbf{x}=(x,z)$ 是水面平面坐标，$\mathbf{k}=(k_x,k_z)$ 是波数向量，$\tilde{h}(\mathbf{k},t)$ 是复数频谱。当前代码采用的时间演化形式为：

$$
\tilde{h}(\mathbf{k},t)=h_0(\mathbf{k})e^{i\omega t}+h_0^*(-\mathbf{k})e^{-i\omega t}
$$

为了保证逆 FFT 后得到真实可渲染的实数高度场，频谱需要满足共轭对称：

$$
H(-\mathbf{k})=H^*(\mathbf{k})
$$

水平位移使用线性波理论近似：

$$
D_x=i\frac{k_x}{|\mathbf{k}|}\tilde{h}(\mathbf{k},t),\qquad
D_z=i\frac{k_z}{|\mathbf{k}|}\tilde{h}(\mathbf{k},t)
$$

斜率用于恢复片元法线：

$$
\partial_x\eta=i k_x\tilde{h}(\mathbf{k},t),\qquad
\partial_z\eta=i k_z\tilde{h}(\mathbf{k},t)
$$

最终通过二维逆 FFT 得到空间域贴图：

$$
\mathbf{D}(x,z)=\mathcal{F}^{-1}\{\mathbf{D}(\mathbf{k})\}
$$

---

# 第一部分：`FFTWater.compute` —— GPU 频谱、逆 FFT 与贴图生成

ComputeShader 本身不属于 Built-in 或 URP 的光栅化 Pass，因此迁移 URP 时它的大部分物理计算逻辑可以保留。它负责把频域海浪模型转换成 URP Shader 可采样的 `Texture2DArray`。

## 2. ComputeShader 入口、纹理和全局参数声明

### 原理与公式

ComputeShader 通过 `#pragma kernel` 声明多个 GPU 入口函数。当前代码将流程拆成初始化频谱、打包共轭频谱、更新时间频谱、水平逆 FFT、垂直逆 FFT、组装贴图和泡沫扩展七个阶段。

四个不同的长度尺度使用 `Texture2DArray` 存储。设 layer 为 $l$，则位移贴图可表示为：

$$
T_D(x,z,l)=\{D_x,D_y,D_z,foam\}
$$

斜率贴图可表示为：

$$
T_S(x,z,l)=\{\partial_x\eta,\partial_z\eta\}
$$

### 对应代码

```hlsl
// FFTWater.compute
// 说明：ComputeShader不属于Built-in或URP的光栅化渲染Pass，它直接在GPU计算队列中运行。
// 因此从默认渲染管线迁移到URP时，ComputeShader主体通常不需要改写；
// C#脚本负责把它生成的Texture2DArray传给URP水面Shader，URP Shader负责采样这些贴图完成最终渲染。

// 初始化频谱内核 - 基于Tessendorf的海洋模拟方法
#pragma kernel CS_InitializeSpectrum  // 标记Compute Shader入口：初始化海浪谱  
#pragma kernel CS_PackSpectrumConjugate // 标记Compute Shader入口：打包谱的共轭值 打包共轭对称频谱内核 - 用于FFT的共轭对称性优化
#pragma kernel CS_UpdateSpectrumForFFT // 标记Compute Shader入口：更新谱数据适配FFT 更新频谱用于FFT变换内核 - 应用时间演化
#pragma kernel CS_HorizontalFFT // 标记Compute Shader入口：执行水平方向FFT 平方向FFT内核 - 计算水平方向的快速傅里叶变换
#pragma kernel CS_VerticalFFT  // 标记Compute Shader入口：执行垂直方向FFT 垂直方向FFT内核 - 计算垂直方向的快速傅里叶变换
#pragma kernel CS_AssembleMaps  // 标记Compute Shader入口：组装位移/斜率/泡沫贴图 组装贴图内核 - 将FFT结果转换为位移和法线贴图
#pragma kernel CS_AccumulateFoam // 标记Compute Shader入口：泡沫累积（预留功能） 累积泡沫内核 - 计算泡沫效果

#define PI 3.14159265358979323846  // 定义圆周率常量，用于三角函数/波相关计算

Texture2D<float2> _PingTex; //输入的Ping贴图，用于迭代计算（通常为上一帧结果）
// 可读写的频谱纹理数组：当前频谱、初始频谱、位移贴图
// 1. _SpectrumTextures：存储时变频谱（位移/斜率分量）
// 2. _InitialSpectrumTextures：存储初始频谱h₀(k)及共轭值
// 3. _DisplacementTextures：存储最终位移（xyz）+ 泡沫值（a通道）
// 使用Texture2DArray存储4个层级的海洋细节
RWTexture2DArray<float4> _SpectrumTextures, _InitialSpectrumTextures, _DisplacementTextures;
RWTexture2DArray<float2> _SlopeTextures; // 可读写的坡度纹理数组 - 存储法线信息 斜率数据
RWTexture2D<half> _BuoyancyData; // 可读写的浮力数据贴图 - 用于浮力计算


// 全局参数（由CPU端传入）：
// 浮点变量：帧时间/时间增量/振幅系数/重力/重复周期/阻尼/水深/波数截止范围
float _FrameTime, _DeltaTime, _A, _Gravity, _RepeatTime, _Damping, _Depth, _LowCutoff, _HighCutoff;
int _Seed;   // 整型变量：随机种子（用于谱初始化的随机性）
float2 _Wind, _Lambda, _NormalStrength; // 二维浮点变量：风向风速/缩放因子/法线强度
uint _N, _LengthScale0, _LengthScale1, _LengthScale2, _LengthScale3;  // 无符号整型：FFT尺寸/4个长度尺度（对应不同波长）
float _FoamBias, _FoamDecayRate, _FoamAdd, _FoamThreshold;// 浮点变量：泡沫偏置/衰减率/添加量/阈值
```

### 代码作用说明

这段代码定义了全部 Kernel 和全局 GPU 资源。`_InitialSpectrumTextures` 保存初始频谱，`_SpectrumTextures` 保存时间演化和 FFT 中间结果，`_DisplacementTextures` 与 `_SlopeTextures` 是最后传给 URP 水面 Shader 的贴图。`_LengthScale0~3` 对应四层海浪尺度，`_LowCutoff/_HighCutoff` 用来裁剪无效波数。

## 3. 复数运算、欧拉公式和高斯随机数

### 原理与公式

FFT 海面模拟需要处理复数。代码把复数 $a+ib$ 存成 `float2(a,b)`。复数乘法为：

$$
(a_r+ia_i)(b_r+ib_i)=(a_rb_r-a_ib_i)+i(a_rb_i+a_ib_r)
$$

时间相位使用欧拉公式：

$$
e^{i\theta}=\cos\theta+i\sin\theta
$$

初始频谱需要高斯随机扰动。Box-Muller 变换为：

$$
R=\sqrt{-2\ln u_1},\quad \theta=2\pi u_2
$$

$$
Z_1=R\cos\theta,\quad Z_2=R\sin\theta
$$

### 对应代码

```hlsl
// 复数乘法函数：输入a=(a_r,a_i), b=(b_r,b_i) 输入a=(实部a.x, 虚部a.y)，b=(实部b.x, 虚部b.y)
// 公式：(a_r + i*a_i)(b_r + i*b_i) = (a_r*b_r - a_i*b_i) + i(a_r*b_i + a_i*b_r)
float2 ComplexMult(float2 a, float2 b) { // 复数乘法函数：输入a=(a_r,a_i), b=(b_r,b_i)
    return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

// 欧拉公式实现：e^(ix) = cos(x) + i*sin(x)
// 用于波浪的时间演化相位计算
float2 EulerFormula(float x) { 
    return float2(cos(x), sin(x));
}
// 整数哈希函数（Hugo Elias算法）：将整数映射到[0,1)的伪随机浮点数
// 用途：为Box-Muller变换生成均匀分布随机数
float hash(uint n) {
    // integer hash copied from Hugo Elias
    n = (n << 13U) ^ n;// 位运算打乱：左移13位后异或自身
    n = n * (n * n * 15731U + 0x789221U) + 0x1376312589U;// 乘法+加法进一步打乱数值
    // 取低31位（避免负数），转换为[0,1)浮点数
    return float(n & uint(0x7fffffffU)) / float(0x7fffffff);
}
// Box-Muller变换：将两个均匀分布随机数(u1,u2∈[0,1))转换为标准正态分布随机数 为高斯分布
// 数学公式：
// R = √(-2lnu1), θ=2πu2
// Z₁ = Rcosθ, Z₂ = Rsinθ（两个独立的标准正态分布）
// 用于生成符合高斯分布的初始波浪振幅
// 文献链接：https://doi.org/10.1214/aoms/1177706645
float2 UniformToGaussian(float u1, float u2) {
    float R = sqrt(-2.0f * log(u1));// 极坐标半径
    float theta = 2.0f * PI * u2; // 极坐标角度

    return float2(R * cos(theta), R * sin(theta));// 返回二维高斯分布随机数
}
```

### 代码作用说明

`ComplexMult` 实现复数乘法，`EulerFormula` 生成频谱时间推进所需的相位，`hash` 与 `UniformToGaussian` 为每个频域采样点生成可复现的高斯随机数。相同 `seed` 下水面形状稳定，不同 `seed` 下初始波形不同。

## 4. JONSWAP 能谱、方向谱、TMA 修正和色散关系

### 原理与公式

色散关系决定波数和角频率之间的关系。有限水深下：

$$
\omega(k)=\sqrt{gk\tanh(kd)}
$$

JONSWAP 能谱描述风浪能量随频率的分布：

$$
S(\omega)=\alpha g^2\omega^{-5}\exp\left[-1.25\left(\frac{\omega_p}{\omega}\right)^4\right]\gamma^r C_{TMA}(\omega)
$$

其中：

$$
r=\exp\left[-\frac{(\omega-\omega_p)^2}{2\sigma^2\omega_p^2}\right]
$$

$$
\sigma=\begin{cases}
0.07,&\omega\le\omega_p\\
0.09,&\omega>\omega_p
\end{cases}
$$

TMA 修正用于有限水深：

$$
C_{TMA}(\omega)=
\begin{cases}
0.5\omega_h^2,&\omega_h\le1\\
1-0.5(2-\omega_h)^2,&1<\omega_h<2\\
1,&\omega_h\ge2
\end{cases}
$$

方向谱控制能量围绕风向分布的方式，代码中用 `DirectionSpectrum` 混合余弦方向谱和 `Cosine2s` 模型。

### 对应代码

```hlsl
// 海浪谱参数结构体：存储JONSWAP能谱+方向谱的核心参数
// FFT and JONSWAP Implementation largely referenced from https://github.com/gasgiant/FFT-Ocean/
struct SpectrumParameters {
	float scale;  // 谱整体缩放因子（控制海浪振幅）
	float angle;// 主波方向角（与风向一致）
	float spreadBlend;// 方向谱混合权重（DonelanBanner ↔ Cosine2s）
	float swell;// 涌浪强度（增强长波方向的集中性）
	float alpha; // JONSWAP谱的Phillips常数（控制谱的整体能量）
	float peakOmega; // JONSWAP谱的峰频ωp（能量最高的频率）
	float gamma;// JONSWAP谱的峰值增强因子（γ越大，谱峰越尖锐）
	float shortWavesFade;// 短波衰减系数（抑制高频噪声）
};
// 结构化缓冲区：存储多组（8组，对应4个尺度×2层）海浪谱参数
StructuredBuffer<SpectrumParameters> _Spectrums;

// 色散关系函数：计算角频率ω（有限水深）
// 数学公式：ω = √(g*k*tanh(kd)) 
// g=重力加速度，k=波数模长，d=水深，tanh(kd)为双曲正切（浅水波修正）
float Dispersion(float kMag) {
    // 限制kd≤20避免tanh数值溢出（tanh(20)≈1，深水区近似）
    return sqrt(_Gravity * kMag * tanh(min(kMag * _Depth, 20)));
}
// 色散关系对波数的导数：dω/dk（用于初始频谱幅值计算）
// 数学推导：dω/dk = g/(2ω) * (kd/cosh²(kd) + tanh(kd))
float DispersionDerivative(float kMag) {
    float th = tanh(min(kMag * _Depth, 20));// tanh(kd)（限制kd≤20）
    float ch = cosh(kMag * _Depth); // cosh(kd)（双曲余弦）
    return _Gravity * (_Depth * kMag / ch / ch + th) / Dispersion(kMag) / 2.0f;
}
// 余弦2s次方方向谱的归一化因子（经验拟合公式）
// 用途：保证方向谱在全角度积分结果为1（能量守恒）
float NormalizationFactor(float s) {
    float s2 = s * s; // s²
    float s3 = s2 * s;// s³
    float s4 = s3 * s;// s⁴
    // 分段拟合：s<5时用低阶拟合，s≥5时用高阶拟合
    if (s < 5) return -0.000564f * s4 + 0.00776f * s3 - 0.044f * s2 + 0.192f * s + 0.163f;
    else return -4.80e-08f * s4 + 1.07e-05f * s3 - 9.53e-04f * s2 + 5.90e-02f * s + 3.93e-01f;
}
// DonelanBanner方向谱的β参数（分段函数）
// 数学原理：DonelanBanner方向谱的核心参数，随ω/ωp变化
// 文献链接：https://doi.org/10.1016/0304-3800(85)90082-1
// 用于计算波陡相关参数，影响波浪破碎
float DonelanBannerBeta(float x) {
	if (x < 0.95f) return 2.61f * pow(abs(x), 1.3f); // x<0.95：β=2.61|x|^1.3
	if (x < 1.6f) return 2.28f * pow(abs(x), -1.3f);// 0.95≤x<1.6：β=2.28|x|^-1.3
    // x≥1.6：经验公式计算β
	float p = -0.4f + 0.8393f * exp(-0.567f * log(x * x));
	return pow(10.0f, p);
}

// DonelanBanner方向谱计算：描述海浪能量在不同方向的分布
// 数学公式：D(θ) = β/(2tanh(βπ)) * sech²(βθ)，其中sech=1/cosh
// 用于短波方向分布建模
float DonelanBanner(float theta, float omega, float peakOmega) {
	float beta = DonelanBannerBeta(omega / peakOmega); // 计算β（基于ω/ωp）
	float sech = 1.0f / cosh(beta * theta);// 双曲正割
	return beta / 2.0f / tanh(beta * 3.1416f) * sech * sech;// DonelanBanner方向谱值  // 归一化
}
// 余弦2s次方方向谱：另一种经典方向谱模型
// 数学公式：D(θ) = N(s) * |cos(θ/2)|^(2s)，N(s)为归一化因子
float Cosine2s(float theta, float s) {
	return NormalizationFactor(s) * pow(abs(cos(0.5f * theta)), 2.0f * s);
}
// 方向谱的扩展幂次s（经验公式）：控制方向谱的集中程度
// ω>ωp时s减小（能量分散），ω≤ωp时s增大（能量集中）
float SpreadPower(float omega, float peakOmega) {
	if (omega > peakOmega)
		return 9.77f * pow(abs(omega / peakOmega), -2.5f);
	else
		return 6.97f * pow(abs(omega / peakOmega), 5.0f);
}
// 混合方向谱：线性插值DonelanBanner和Cosine2s模型
// 数学公式：D(θ) = lerp(2/π cos²θ, Cosine2s(θ-θ₀,s), blend)
float DirectionSpectrum(float theta, float omega, SpectrumParameters spectrum) {
    // 计算扩展幂次s（含涌浪修正）
	float s = SpreadPower(omega, spectrum.peakOmega) + 16 * tanh(min(omega / spectrum.peakOmega, 20)) * spectrum.swell * spectrum.swell;
    // 线性混合两种方向谱
	return lerp(2.0f / 3.1415f * cos(theta) * cos(theta), Cosine2s(theta - spectrum.angle, s), spectrum.spreadBlend);
}
// TMA修正：有限水深对JONSWAP谱的浅化修正（保证浅水波能量守恒）
// 数学原理：TMA谱（Tromp-Maeda-Arsloe）修正因子，随无量纲频率ω√(d/g)变化
// 文献链接：https://doi.org/10.1016/0304-3800(85)90059-5
// 公式：C(ω) = { 0.5*(ω√(h/g))²          (ω√(h/g)≤1)
//              { 1-0.5*(2-ω√(h/g))²    (1<ω√(h/g)<2)
//              { 1                      (ω√(h/g)≥2)
float TMACorrection(float omega) {
	float omegaH = omega * sqrt(_Depth); // _Gravity);// 无量纲频率：ω√(d/g)
	if (omegaH <= 1.0f)
		return 0.5f * omegaH * omegaH ;// ω√(d/g)≤1：修正因子=0.5(ω√(d/g))²
	if (omegaH < 2.0f)
		return 1.0f - 0.5f * (2.0f - omegaH) * (2.0f - omegaH);// 1<ω√(d/g)<2：线性过渡

	return 1.0f;// ω√(d/g)≥2：深水区，修正因子=1
}
// JONSWAP能谱计算：描述海浪能量在不同频率的分布
// 数学公式（核心）：
// S(ω) = αg²ω^-5 * exp(-1.25(ωp/ω)^4) * γ^exp(-(ω-ωp)²/(2σ²ωp²)) * TMA(ω)
// 其中σ=0.07(ω≤ωp)，σ=0.09(ω>ωp)
// 文献链接：https://doi.org/10.1016/0304-3800(76)90001-8
float JONSWAP(float omega, SpectrumParameters spectrum) {
    // 谱峰两侧的σ值（控制谱的形状）
	float sigma = (omega <= spectrum.peakOmega) ? 0.07f : 0.09f;
    // 指数项r：控制γ的衰减
	float r = exp(-(omega - spectrum.peakOmega) * (omega - spectrum.peakOmega) / 2.0f / sigma / sigma / spectrum.peakOmega / spectrum.peakOmega);
    // 简化计算：1/ω
	float oneOverOmega = 1.0f / omega;
    // 简化计算：ωp/ω
	float peakOmegaOverOmega = spectrum.peakOmega / omega;
    // 完整JONSWAP公式（含缩放、TMA修正）
	return spectrum.scale * TMACorrection(omega) * spectrum.alpha * _Gravity * _Gravity
		* oneOverOmega * oneOverOmega * oneOverOmega * oneOverOmega * oneOverOmega
		* exp(-1.25f * peakOmegaOverOmega * peakOmegaOverOmega * peakOmegaOverOmega * peakOmegaOverOmega)
		* pow(abs(spectrum.gamma), r);// γ^r（峰值增强）
}
// 短波衰减函数：抑制高频（短波）噪声，避免视觉闪烁
// 数学公式：exp(-(k·shortWavesFade)²)
float ShortWavesFade(float kLength, SpectrumParameters spectrum) {
	return exp(-spectrum.shortWavesFade * spectrum.shortWavesFade * kLength * kLength);
}
```

### 代码作用说明

`SpectrumParameters` 是 GPU 端频谱参数结构体。`Dispersion` 和 `DispersionDerivative` 根据 $k$ 得到 $\omega$ 和 $d\omega/dk$。`JONSWAP` 计算频率能量，`DirectionSpectrum` 计算方向权重，`ShortWavesFade` 抑制过高频短波。它们共同决定初始频谱的能量分布。

## 5. 初始化初始频谱 `CS_InitializeSpectrum`

### 原理与公式

每个频域像素对应一个波数 $\mathbf{k}$。初始频谱可写为：

$$
h_0(\mathbf{k})=(\xi_r+i\xi_i)\sqrt{2S(\mathbf{k})\left|\frac{d\omega}{dk}\right|\frac{\Delta k^2}{|\mathbf{k}|}}
$$

其中 $\xi_r,\xi_i$ 是独立高斯随机数，$\Delta k=2\pi/L$，$L$ 为当前海浪层的物理长度尺度。

### 对应代码

```hlsl
// 初始化频谱内核：生成4个尺度的初始频谱h₀(k)
// 线程组尺寸：8x8x1（每个线程处理一个频谱像素） 共64线程
[numthreads(8,8,1)]
void CS_InitializeSpectrum(uint3 id : SV_DISPATCHTHREADID) {

    // 初始化随机种子（基于线程ID+FFT尺寸，保证每个像素种子唯一）
    uint seed = id.x + _N * id.y + _N;
    seed += _Seed; // 叠加用户定义的种子，控制全局随机性

    // 4个长度尺度（对应4个海浪层级）
    float lengthScales[4] = { _LengthScale0, _LengthScale1, _LengthScale2, _LengthScale3 };

    for (uint i = 0; i < 4; ++i) { // 遍历4个长度尺度
            float halfN = _N / 2.0f;// FFT尺寸的一半（波数坐标系中心）

        // 波数间隔：Δk = 2π/L（L为当前尺度的长度）
        float deltaK = 2.0f * PI / lengthScales[i];
        // 波数向量：K=(kx,ky)，中心在(N/2,N/2)，范围[-π/L*N/2, π/L*N/2]
        float2 K = (id.xy - halfN) * deltaK;
        // 波数模长：|K| = √(kx²+ky²)
        float kLength = length(K);

        // 更新随机种子（引入哈希扰动，保证随机性）
        seed += i + hash(seed) * 10;
        // 生成4个均匀分布随机数（用于Box-Muller变换）
        float4 uniformRandSamples = float4(hash(seed), hash(seed * 2), hash(seed * 3), hash(seed * 4));
        // 转换为两组高斯分布随机数
        float2 gauss1 = UniformToGaussian(uniformRandSamples.x, uniformRandSamples.y);
        float2 gauss2 = UniformToGaussian(uniformRandSamples.z, uniformRandSamples.w);
        // 仅处理有效波数范围（过滤过低/过高波数，减少计算量）
        if (_LowCutoff <= kLength && kLength <= _HighCutoff) {
            float kAngle = atan2(K.y, K.x); // 波数方向角：θ=atan2(ky,kx)（与x轴的夹角）
            float omega = Dispersion(kLength);// 色散关系计算角频率ω

            float dOmegadk = DispersionDerivative(kLength);// 计算dω/dk（色散导数）
            // 计算总能谱：JONSWAP × 方向谱 × 短波衰减（第一组谱参数）
            float spectrum = JONSWAP(omega, _Spectrums[i * 2]) * DirectionSpectrum(kAngle, omega, _Spectrums[i * 2]) * ShortWavesFade(kLength, _Spectrums[i * 2]);
            // 叠加第二组谱参数（若存在）
            if (_Spectrums[i * 2 + 1].scale > 0)
                spectrum += JONSWAP(omega, _Spectrums[i * 2 + 1]) * DirectionSpectrum(kAngle, omega, _Spectrums[i * 2 + 1]) * ShortWavesFade(kLength, _Spectrums[i * 2 + 1]);
            // 初始频谱h₀(k)计算：
            // 数学公式：h₀(k) = (Z₁ + iZ₂) × √(2S(k) |dω/dk| Δk² / |k|)
            // Z₁/Z₂为高斯随机数，保证频谱的正态分布特性
            _InitialSpectrumTextures[uint3(id.xy, i)] = float4(float2(gauss2.x, gauss1.y) * sqrt(2 * spectrum * abs(dOmegadk) / kLength * deltaK * deltaK), 0.0f, 0.0f);
        } else {
            // 无效波数范围：频谱设为0
            _InitialSpectrumTextures[uint3(id.xy, i)] = 0.0f;
        }
    }
}
```

### 代码作用说明

该 Kernel 对每个 `id.xy` 计算四个不同 `lengthScale` 的初始频谱。代码先将像素坐标转换为以频谱中心为原点的波数坐标，再计算 JONSWAP 能谱、方向谱、短波衰减和高斯随机幅值，最后写入 `_InitialSpectrumTextures`。

## 6. 打包共轭频谱 `CS_PackSpectrumConjugate`

### 原理与公式

为了让逆 FFT 后的水面高度为实数，频谱需要满足：

$$
h(-\mathbf{k})=h^*(\mathbf{k})
$$

当前代码把 $h_0(k)$ 存在 `rg`，把 $h_0^*(-k)$ 存在 `ba`。

### 对应代码

```hlsl
// 打包共轭对称频谱内核：利用FFT实数信号的共轭对称性优化存储
// 线程组尺寸：8x8x1
[numthreads(8,8,1)]
void CS_PackSpectrumConjugate(uint3 id : SV_DISPATCHTHREADID) {
    for (uint i = 0; i < 4; ++i) { // 遍历4个长度尺度
        // 读取当前波数k的初始频谱h₀(k)
        float2 h0 = _InitialSpectrumTextures[uint3(id.xy, i)].rg;
        // 读取波数-k的初始频谱h₀(-k)（共轭对称位置）
        float2 h0conj = _InitialSpectrumTextures[uint3((_N - id.x ) % _N, (_N - id.y) % _N, i)].rg;
        // 存储h₀(k)和h₀*(-k)（共轭值，虚部取反）
        // 数学原理：实数信号的FFT满足H(-k) = H*(k)，仅需存储一半数据
        _InitialSpectrumTextures[uint3(id.xy, i)] = float4(h0, h0conj.x, -h0conj.y);
    }
}
```

### 代码作用说明

`(_N-id.x)%_N` 和 `(_N-id.y)%_N` 用来找到负波数位置。虚部取反表示共轭。之后每个频谱像素都同时拥有正波数和负波数的信息，便于下一阶段直接计算 $\tilde{h}(k,t)$。

## 7. 更新时间频谱 `CS_UpdateSpectrumForFFT`

### 原理与公式

时间演化公式为：

$$
\tilde{h}(k,t)=h_0(k)e^{i\omega t}+h_0^*(-k)e^{-i\omega t}
$$

水平位移谱为：

$$
D_x(k)=i\frac{k_x}{|k|}\tilde{h}(k,t),\qquad
D_z(k)=i\frac{k_z}{|k|}\tilde{h}(k,t)
$$

斜率谱为：

$$
\partial_x\eta=i k_x\tilde{h}(k,t),\qquad
\partial_z\eta=i k_z\tilde{h}(k,t)
$$

### 对应代码

```hlsl
// 更新频谱用于FFT内核：生成时变频谱h̃(k,t)，并计算位移/斜率谱分量
// 线程组尺寸：8x8x1
[numthreads(8, 8, 1)]
void CS_UpdateSpectrumForFFT(uint3 id : SV_DISPATCHTHREADID) {
    // 4个长度尺度数组
    float lengthScales[4] = { _LengthScale0, _LengthScale1, _LengthScale2, _LengthScale3 };
    // 遍历4个长度尺度
    for (int i = 0; i < 4; ++i) {
        // 读取初始频谱+共轭值
        float4 initialSignal = _InitialSpectrumTextures[uint3(id.xy, i)];
        float2 h0 = initialSignal.xy; // h₀(k)
        float2 h0conj = initialSignal.zw;// h₀*(-k)

        float halfN = _N / 2.0f;// FFT尺寸的一半
        float2 K = (id.xy - halfN) * 2.0f * PI / lengthScales[i];// 波数向量K=(kx,ky)
        float kMag = length(K);// 波数模长|K|
        float kMagRcp = rcp(kMag);// |K|的快速倒数（GPU内置函数，比1/kMag快）

        if (kMag < 0.0001f) { // 避免除零（波数接近0时，倒数设为1）
            kMagRcp = 1.0f;
        }

        float w_0 = 2.0f * PI / _RepeatTime;// 基频：ω₀=2π/T（T为重复周期）
        // 色散相位：floor(√(gk)/ω₀) × ω₀ × 帧时间（量化到基频倍数，保证周期性）
        float dispersion = floor(sqrt(_Gravity * kMag) / w_0) * w_0 * _FrameTime;

        float2 exponent = EulerFormula(dispersion);// 欧拉公式计算e^(i×色散相位)
        
        // 时变频谱h̃(k,t)计算：
        // 数学公式：h̃(k,t) = h₀(k)e^(iωt) + h₀*(-k)e^(-iωt)
        float2 htilde = ComplexMult(h0, exponent) + ComplexMult(h0conj, float2(exponent.x, -exponent.y));
        // 计算i×h̃(k,t)（虚数乘法：i*(a+bi) = -b + ai）
        float2 ih = float2(-htilde.y, htilde.x);

        // 位移谱分量计算（线性波理论）：
        float2 displacementX = ih * K.x * kMagRcp;// x方向位移谱
        float2 displacementY = htilde;               // y方向（垂直）位移谱
        float2 displacementZ = ih * K.y * kMagRcp; // z方向位移谱

        // 斜率/二阶导数谱分量计算（法线/泡沫用）：
        float2 displacementX_dx = -htilde * K.x * K.x * kMagRcp;// x位移的x偏导数
        float2 displacementY_dx = ih * K.x;                     // y位移的x偏导数（斜率x）
        float2 displacementZ_dx = -htilde * K.x * K.y * kMagRcp;// z位移的x偏导数

        float2 displacementY_dz = ih * K.y;                     // y位移的z偏导数（斜率z）
        float2 displacementZ_dz = -htilde * K.y * K.y * kMagRcp; // z位移的z偏导数

        // 组合位移谱分量（修正虚部交叉项）
        float2 htildeDisplacementX = float2(displacementX.x - displacementZ.y, displacementX.y + displacementZ.x);
        float2 htildeDisplacementZ = float2(displacementY.x - displacementZ_dx.y, displacementY.y + displacementZ_dx.x);
        // 组合斜率谱分量
        float2 htildeSlopeX = float2(displacementY_dx.x - displacementY_dz.y, displacementY_dx.y + displacementY_dz.x);
        float2 htildeSlopeZ = float2(displacementX_dx.x - displacementZ_dz.y, displacementX_dx.y + displacementZ_dz.x);
        // 存储位移谱（i*2通道）和斜率谱（i*2+1通道）
        _SpectrumTextures[uint3(id.xy, i * 2)] = float4(htildeDisplacementX, htildeDisplacementZ);
        _SpectrumTextures[uint3(id.xy, i * 2 + 1)] = float4(htildeSlopeX, htildeSlopeZ);
    }
}
```

### 代码作用说明

该 Kernel 每帧执行。它读取初始谱和共轭谱，用欧拉公式推进相位，然后计算位移谱和斜率谱。`_SpectrumTextures` 的 8 个 layer 中，每个水面尺度占两个 layer：偶数 layer 保存位移相关谱，奇数 layer 保存斜率/导数相关谱。

## 8. 二维逆 FFT：共享内存、蝶形计算、水平和垂直变换

### 原理与公式

二维逆 FFT 可以拆解为两个一维逆 FFT：

$$
\mathcal{F}^{-1}_{2D}\{H(k_x,k_z)\}=\mathcal{F}^{-1}_{z}\left(\mathcal{F}^{-1}_{x}\{H(k_x,k_z)\}\right)
$$

基 2 FFT 的核心蝶形形式为：

$$
X'=A+W_N^rB
$$

其中旋转因子：

$$
W_N^r=e^{-2\pi i r/N}
$$

代码通过修改旋转因子虚部方向实现逆 FFT。

### 对应代码

```hlsl
// 复数指数函数：计算e^(a.x + i*a.y) = e^a.x * (cos(a.y) + i*sin(a.y))
// 用途：FFT旋转因子计算
float2 ComplexExp(float2 a) {
    return float2(cos(a.y), sin(a.y) * exp(a.x));
}
// FFT临时缓冲区（Ping-Pong用，当前代码未实际使用）
RWTexture2D<float4> _Buffer0, _Buffer1, _Buffer2, _Buffer3;
uint _Step;
// 计算FFT旋转因子和输入索引（当前代码未实际使用，预留扩展）
float4 ComputeTwiddleFactorAndInputIndices(uint2 id) {
    uint b = _N >> (id.x + 1);// 蝶形步长：b = N / 2^(id.x+1)
    float2 mult = 2 * PI * float2(0.0f, 1.0f) / _N; // 2πi/N
    uint i = (2 * b * (id.y / b) + id.y % b) % _N; // 计算输入索引i（蝶形运算的第一个输入）
    float2 twiddle = ComplexExp(-mult * ((id.y / b) * b));// 计算旋转因子W_N^r = e^(-2πir/N)
    // 返回旋转因子 + 两个输入索引
    return float4(twiddle, i, i + b);
}

#define SIZE 1024// FFT尺寸（1024点，需为2的幂）
#define LOG_SIZE 10// log2(SIZE) = 10（FFT迭代次数）

RWTexture2DArray<float4> _FourierTarget;// FFT目标纹理（输入/输出频谱）
bool _Direction;// FFT方向（当前代码未使用）
// 分组共享内存：存储FFT蝶形运算的中间结果（GPU共享内存，加速访问）
groupshared float4 fftGroupBuffer[2][SIZE];

// 计算FFT蝶形运算的参数：索引+旋转因子
// 数学原理：基2FFT蝶形运算，核心公式X_k = X_k + W_N^r X_{k+b}
// 文献链接：https://en.wikipedia.org/wiki/Cooley%E2%80%93Tukey_FFT_algorithm
void ButterflyValues(uint step, uint index, out uint2 indices, out float2 twiddle) {
    const float twoPi = 6.28318530718; // 2π常量
    uint b = SIZE >> (step + 1);       // 蝶形步长：b = SIZE / 2^(step+1)
    uint w = b * (index / b);          // 旋转因子指数r
    uint i = (w + index) % SIZE;       // 输入索引i
    // 计算旋转因子cos/sin：cos(-2πw/SIZE)、sin(-2πw/SIZE)
    sincos(-twoPi / SIZE * w, twiddle.y, twiddle.x);
    //This is what makes it the inverse FFT
    twiddle.y = -twiddle.y; // 虚部取反：将正FFT转为逆FFT（IDFT）
    indices = uint2(i, i + b); // 蝶形运算的两个输入索引（i, i+b）
}

// 基2逆FFT蝶形运算（分组共享内存优化）
// 输入：线程索引 + 频谱数据；输出：逆FFT后的空间域数据
float4 FFT(uint threadIndex, float4 input) {
    // 将输入写入共享内存（所有线程并行写入）
    fftGroupBuffer[0][threadIndex] = input;
    // 组内存屏障：确保所有线程完成写入后再继续
    GroupMemoryBarrierWithGroupSync();
    bool flag = false; // 缓冲区切换标志（双缓冲）

    [unroll] // 循环展开（编译器优化，加速FFT）
    for (uint step = 0; step < LOG_SIZE; ++step) {
        uint2 inputsIndices; // 蝶形输入索引
        float2 twiddle;      // 旋转因子
        // 获取当前步骤的蝶形参数
        ButterflyValues(step, threadIndex, inputsIndices, twiddle);

        // 读取第二个输入值V = fftGroupBuffer[flag][i+b]
        float4 v = fftGroupBuffer[flag][inputsIndices.y];
        // 蝶形运算：X = A + W*V（A为第一个输入，W为旋转因子）
        fftGroupBuffer[!flag][threadIndex] = fftGroupBuffer[flag][inputsIndices.x] + float4(ComplexMult(twiddle, v.xy), ComplexMult(twiddle, v.zw));

        flag = !flag; // 切换缓冲区
        GroupMemoryBarrierWithGroupSync(); // 组内存屏障
    }

    // 返回逆FFT结果
    return fftGroupBuffer[flag][threadIndex];
}

// 水平方向FFT内核：对每行执行逆FFT
// 线程组尺寸：SIZE×1×1（每个线程处理一行的一个元素）
[numthreads(SIZE, 1, 1)]
void CS_HorizontalFFT(uint3 id : SV_DISPATCHTHREADID) {
    // 遍历8个谱通道（4个尺度×位移/斜率）
    for (int i = 0; i < 8; ++i) {
        // 对当前像素执行FFT，结果写回目标纹理
        _FourierTarget[uint3(id.xy, i)] = FFT(id.x, _FourierTarget[uint3(id.xy, i)]);
    }
}

// 垂直方向FFT内核：对每列执行逆FFT（通过转置id.yx实现）
// 线程组尺寸：SIZE×1×1
[numthreads(SIZE, 1, 1)]
void CS_VerticalFFT(uint3 id : SV_DISPATCHTHREADID) {
    // 遍历8个谱通道
    for (int i = 0; i < 8; ++i) {
        // 转置id.yx，实现列方向FFT
        _FourierTarget[uint3(id.yx, i)] = FFT(id.x, _FourierTarget[uint3(id.yx, i)]);
    }
}
```

### 代码作用说明

`groupshared` 数组把同一行或同一列的 1024 个复数暂存在组共享内存中，避免频繁访问显存。`CS_HorizontalFFT` 对每行做逆 FFT，`CS_VerticalFFT` 通过 `id.yx` 转置访问完成列方向逆 FFT。注意 ComputeShader 中 `SIZE=1024`，所以 C# 的 `N` 必须也是 1024。

## 9. 组装位移、斜率、泡沫和浮力贴图 `CS_AssembleMaps`

### 原理与公式

逆 FFT 后需要把空间域数据整理成渲染贴图。泡沫依据雅可比行列式生成：

$$
J=(1+\lambda_xd_{xx})(1+\lambda_yd_{zz})-\lambda_x\lambda_y d_{xz}^2
$$

当 $J$ 低于阈值时，局部水面发生压缩或折叠，容易产生泡沫。泡沫更新近似为：

$$
foam_t=foam_{t-1}e^{-decay}+add\cdot\max(0,-(J-bias))
$$

### 对应代码

```hlsl
// 置换函数：修正FFT共轭对称后的相位偏差
// 原理：基于线程ID的奇偶性取反，抵消FFT的相位偏移
float4 Permute(float4 data, float3 id) {
    return data * (1.0f - 2.0f * ((id.x + id.y) % 2));
}

// 组装贴图内核：将FFT结果转换为位移、斜率、泡沫贴图
// 线程组尺寸：8x8x1
[numthreads(8, 8, 1)]
void CS_AssembleMaps(uint3 id : SV_DISPATCHTHREADID) {
    // 遍历4个长度尺度
    for (int i = 0; i < 4; ++i) {
        // 置换位移谱（修正相位）
        float4 htildeDisplacement = Permute(_SpectrumTextures[uint3(id.xy, i * 2)], id);
        // 置换斜率谱（修正相位）
        float4 htildeSlope = Permute(_SpectrumTextures[uint3(id.xy, i * 2 + 1)], id);

        // 提取位移/斜率分量（实部为有效数据）
        float2 dxdz = htildeDisplacement.rg;      // x/z位移
        float2 dydxz = htildeDisplacement.ba;    // y位移
        float2 dyxdyz = htildeSlope.rg;          // x/z斜率
        float2 dxxdzz = htildeSlope.ba;          // 二阶导数
        
        // 计算雅可比行列式：描述海浪表面的拉伸程度（泡沫生成的核心依据）
        // 数学公式：J = (1+λx·dxx)(1+λy·dzz) - λxλy·(dydz)²
        // J<0表示表面拉伸，易产生泡沫
        float jacobian = (1.0f + _Lambda.x * dxxdzz.x) * (1.0f + _Lambda.y * dxxdzz.y) - _Lambda.x * _Lambda.y * dydxz.y * dydxz.y;

        // 最终位移计算（应用缩放因子）
        float3 displacement = float3(_Lambda.x * dxdz.x, dydxz.x, _Lambda.y * dxdz.y);

        // 最终斜率计算（归一化，避免过度拉伸）
        float2 slopes = dyxdyz.xy / (1 + abs(dxxdzz * _Lambda));
        float covariance = slopes.x * slopes.y; // 斜率协方差（当前未使用）

        // 泡沫计算：
        float foam = _DisplacementTextures[uint3(id.xy, i)].a; // 读取历史泡沫值
        foam *= exp(-_FoamDecayRate); // 泡沫指数衰减（模拟自然消失）
        foam = saturate(foam);        // 限制泡沫值在[0,1]

        // 偏置雅可比行列式：仅保留J < FoamBias的部分（拉伸区域）
        float biasedJacobian = max(0.0f, -(jacobian - _FoamBias));
        // 超过阈值时添加泡沫
        if (biasedJacobian > _FoamThreshold)
            foam += _FoamAdd * biasedJacobian;

        // 存储位移（xyz）+ 泡沫（a）
        _DisplacementTextures[uint3(id.xy, i)] = float4(displacement, foam);
        // 存储斜率（用于法线计算）
        _SlopeTextures[uint3(id.xy, i)] = float2(slopes);

        // 第一个尺度的垂直位移存入浮力数据贴图
        if (i == 0) {
            _BuoyancyData[id.xy] = displacement.y;
        }
    }
}
```

### 代码作用说明

`Permute` 使用奇偶取反修正 FFT 输出相位。`CS_AssembleMaps` 将结果写入 `_DisplacementTextures` 和 `_SlopeTextures`。位移贴图 `rgb` 保存顶点偏移，`a` 保存泡沫；斜率贴图 `rg` 用于恢复法线。第一层的垂直位移还写入 `_BuoyancyData`，可供浮力系统使用。

## 10. 预留泡沫扩展 Kernel

### 原理与公式

这一段不是当前主流程必需，但为后续泡沫扩散、泡沫平滑或历史反馈保留接口。高斯核可用于局部模糊：

$$
G(x,y)=\frac{1}{\sqrt{2\pi\sigma^2}}\exp\left(-\frac{x^2+y^2}{2\sigma^2}\right)
$$

### 对应代码

```hlsl
// 高斯滤波核函数：二维高斯分布（预留泡沫平滑用，当前未使用）
// 数学公式：G(x,y) = 1/√(2πσ²) * exp(-(x²+y²)/(2σ²))
float gaussian(int x, int y) {
    float _Spread = 0.5f;          // 高斯核标准差σ
    float sigmaSqu = _Spread * _Spread; // σ²
    return (1 / sqrt(2 * PI * sigmaSqu)) * exp(-((x * x) + (y * y)) / (2 * sigmaSqu));
}

// 采样器：线性过滤 + 重复模式（预留纹理采样用）
SamplerState linear_repeat_sampler;

// 泡沫累积内核：当前仅清零频谱纹理的第二个通道（预留扩展）
// 线程组尺寸：8x8x1
[numthreads(8, 8, 1)]
void CS_AccumulateFoam(uint3 id : SV_DISPATCHTHREADID) {
    _SpectrumTextures[uint3(id.xy, 1)] = 0;
}
```

### 代码作用说明

`gaussian` 是二维高斯函数，`CS_AccumulateFoam` 当前只清空 `_SpectrumTextures` 的一个 layer。它不影响当前水面主流程，但保留了泡沫后处理扩展点。

---

# 第二部分：`FFTWaterURP.shader` —— URP 水面图形渲染

URP Shader 的职责是读取 ComputeShader 输出的位移与斜率贴图，在 URP 前向渲染 Pass 中完成曲面细分、顶点位移、片元法线、水面反射、散射和泡沫合成。

## 11. Shader 属性、URP Include 与曲面细分辅助函数

### 原理与公式

Built-in 到 URP 的核心转换包括：`CGPROGRAM` 改为 `HLSLPROGRAM`，`ForwardBase` 改为 `UniversalForward`，Built-in 的 include 改为 URP 的 `Core.hlsl` 和 `Lighting.hlsl`。

曲面细分因子使用边长和视距估算：

$$
T=\frac{L_{edge}\cdot H_{screen}}{L_{target}\cdot(0.5d_{view})^{1.2}}
$$

边越长、越靠近相机，细分越密；越远离相机，细分越少。

### 对应代码

```hlsl
Shader "Custom/FFTWaterURP" { //着色器名
		
		Properties {
			[Enum(Off, 0, On, 1)] _ZWrite ("Z Write", Float) = 1 //是否开启深度写入 控制像素是否写入到深度里
		}

	HLSLINCLUDE
		// URP核心库：提供_WorldSpaceCameraPos、_ScreenParams、TransformObjectToHClip等SRP下的基础变量和空间变换函数。
		#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl" //cg代码区域在多个pass中共享  该部分皆为曲面细分部分
        #define _TessellationEdgeLength 10 //定义曲面细分的边缘长度阈值（控制细分程度）
		#define NEW_LIGHTING //宏定义 启用新的PBR光照模型

		//曲面细分因子结构体（存储三角形3条边和内部的细分程度）
        struct TessellationFactors {
            float edge[3] : SV_TESSFACTOR; // 三角形三个边缘条边的细分因子数组
            float inside : SV_INSIDETESSFACTOR; // 三角形内部的细分因子
        };

		// 曲面细分启发式函数，根据边缘长度和距离计算细分因子程度  基于距离的自适应细分
		//用公式：细分因子 = (边长度 × 屏幕高度) / (基准长度 × 视角距离^1.2)
        float TessellationHeuristic(float3 cp0, float3 cp1) { //给定三角形一边的两个顶点位置
            float edgeLength = distance(cp0, cp1); //计算两点之间的距离 使用 欧氏距离：√[(x1-x0)²+(y1-y0)²+(z1-z0)²] 公式
            float3 edgeCenter = (cp0 + cp1) * 0.5; //// 计算两点的中点坐标
            float viewDistance = distance(edgeCenter, _WorldSpaceCameraPos); //计算边缘中点到相机的距离
			//// 细分因子公式：边缘长度 * 屏幕高度 / (细分阈值 * 视角距离^1.2)
			///距离越远，细分因子越小，减少远处几何体复杂度 距离相机越近、边缘越长，细分越密集（平衡性能与细节）
            return edgeLength * _ScreenParams.y / (_TessellationEdgeLength * (pow(viewDistance * 0.5f, 1.2f)));
        }

		// 判断三角形的部分像素是否完全在位于裁剪屏幕平面之外（用于裁剪不可见三角形，优化性能）
        bool TriangleIsBelowClipPlane(float3 p0, float3 p1, float3 p2, int planeIndex, float bias) {
            float4 plane = unity_CameraWorldClipPlanes[planeIndex]; // 获取相机裁剪平面（齐次平面方程：ax+by+cz+d=0） 根据planeIndex获取视锥体的拆分部分平面

        	 // 点到平面的距离：dot(plane, float4(p,1))，若所有点距离<bias则在表示在平面外  返回true
            return dot(float4(p0, 1), plane) < bias && dot(float4(p1, 1), plane) < bias && dot(float4(p2, 1), plane) < bias;
        }

		// // 判断三角形是否需要被裁剪（在任意一个裁剪平面后方则裁剪） 检查三角形是否整个在所有裁剪平面之外 如果三角形有部分在视锥体内也渲染
        bool cullTriangle(float3 p0, float3 p1, float3 p2, float bias) { //// 检查三角形是否在任意一个裁剪平面（左、右、下、上）之外
            return TriangleIsBelowClipPlane(p0, p1, p2, 0, bias) || //传入三角形传入到判断是否在外函数进行判断 将顶点与摄像机的视锥体每个平面进行判断 当有一个为true时这三角形有部分在视锥体外需要裁剪
                   TriangleIsBelowClipPlane(p0, p1, p2, 1, bias) ||
                   TriangleIsBelowClipPlane(p0, p1, p2, 2, bias) ||
                   TriangleIsBelowClipPlane(p0, p1, p2, 3, bias);
        }
    ENDHLSL
```

### 代码作用说明

`HLSLINCLUDE` 中的代码会被后续 Pass 共享。`TessellationHeuristic` 计算细分强度，`TriangleIsBelowClipPlane` 与 `cullTriangle` 用视锥体平面剔除完全不可见的三角形，减少屏幕外水面的细分开销。

## 12. SubShader、Pass 与 URP 前向渲染入口

### 原理与公式

URP Shader 必须声明：

```hlsl
"RenderPipeline" = "UniversalPipeline"
```

URP 前向渲染 Pass 使用：

```hlsl
Tags { "LightMode" = "UniversalForward" }
```

这就是从 Built-in `ForwardBase` 迁移到 URP 的关键之一。

### 对应代码

```hlsl
	SubShader {
		Tags {
			"RenderPipeline" = "UniversalPipeline" // 指定该SubShader只在URP中使用，避免Built-in管线错误匹配。
			"RenderType" = "Opaque" // 水面按不透明物体参与URP前向渲染；当前片元输出alpha固定为1。
			"Queue" = "Geometry" // 渲染队列使用Geometry，保证正常写入/测试深度。
		}
		

		Pass {
			Name "ForwardLit" // URP前向光照Pass名称，便于Frame Debugger识别。
			Tags { "LightMode" = "UniversalForward" } // URP使用UniversalForward作为前向渲染Pass标签，替代Built-in的ForwardBase。
			ZWrite [_ZWrite] // 使用属性控制深度写入。
			
			
			
			HLSLPROGRAM



			#pragma vertex dummyvp //顶点着色器为
			#pragma hull hp		   //外壳着色器 用于曲面细分控制
			#pragma domain dp	   //域着色器曲面细分后的顶点处理 细分插值
			#pragma geometry gp	   //几何着色器处理图元
			#pragma fragment fp    //片段着色器
			#pragma target 5.0     // 曲面细分Hull/Domain和Geometry Shader需要较高Shader Model，DX11/Metal等平台才支持。
			


			// URP核心库：替代Built-in管线的UnityPBSLighting.cginc / AutoLight.cginc。
			// Core.hlsl提供空间变换、矩阵、深度线性化等函数；Lighting.hlsl提供GetMainLight等URP光照接口。
			#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
```

### 代码作用说明

这个 Pass 使用 vertex、hull、domain、geometry、fragment 五个阶段，因此要求 `#pragma target 5.0`。桌面 DX11/DX12 通常可运行；如果目标是移动端或不支持曲面细分的平台，需要移除 hull/domain/geometry，改写为普通顶点位移 Shader。

## 13. URP 数据结构、材质参数和贴图声明

### 原理与公式

URP/SRP 推荐使用 `TEXTURE2D_ARRAY`、`SAMPLER`、`SAMPLE_TEXTURE2D_ARRAY` 等宏声明和采样纹理。当前水面渲染依赖两类贴图：

$$
T_D=\{D_x,D_y,D_z,foam\}
$$

$$
T_S=\{s_x,s_z\}
$$

四层贴图通过 array layer 区分。

### 对应代码

```hlsl
			struct TessellationControlPoint {  /// 曲面细分控制点结构体
                float4 vertex : INTERNALTESSPOS;  //顶点位置 （内部曲面细分位置语义
                float2 uv : TEXCOORD0; //采样坐标v
            };

			struct VertexData { // 原始顶点数据结构体（从模型输入）
				float4 vertex : POSITION; 
                float2 uv : TEXCOORD0;
			};
			// 顶点着色器到几何着色器的数据结构体
			struct v2g {
				float4 pos : SV_POSITION;  //顶点位置
                float2 uv : TEXCOORD0; //uv
				float3 worldPos : TEXCOORD1; //世界空间顶点位置
				float depth : TEXCOORD2; //顶点在屏幕空间像素深度  深度衰减因子
			};


			#define PI 3.14159265358979323846

			float DotClamped(float3 a, float3 b) {
				return saturate(dot(a, b)); // URP中不再依赖UnityPBSLighting.cginc，因此手动实现DotClamped：点乘后限制到0-1。
			}

			float hash(uint n) {  // 整数哈希函数（用于随机数生成，基于Hugo Elias的算法）
				// integer hash copied from Hugo Elias
				n = (n << 13U) ^ n;  // 位运算混淆
				n = n * (n * n * 15731U + 0x789221U) + 0x1376312589U;   // 乘法混淆
				return float(n & uint(0x7fffffffU)) / float(0x7fffffff);  // 返回0-1之间的随机浮点数
			}

			// 以下是大量的材质参数声明

			float3 _SunDirection, _SunColor; // 太阳方向和颜色

			float _NormalStrength, _FresnelNormalStrength, _SpecularNormalStrength; // 法线强度、Fresnel法线强度、镜面法线强度
				TEXTURECUBE(_EnvironmentMap); // URP/HLSL风格环境立方体贴图声明，替代Built-in的samplerCUBE。
				SAMPLER(sampler_EnvironmentMap); // 环境贴图采样器，SAMPLE_TEXTURECUBE会使用它执行采样。
				int _UseEnvironmentMap; // 是否使用环境贴图

			float3 _Ambient, _DiffuseReflectance, _SpecularReflectance, _FresnelColor, _TipColor; // 环境光、漫反射率、镜面反射率、Fresnel颜色、尖端颜色
			float _Shininess, _FresnelBias, _FresnelStrength, _FresnelShininess, _TipAttenuation; // 光泽度、Fresnel偏移、Fresnel强度、Fresnel光泽度、尖端衰减
			float _Roughness, _FoamRoughnessModifier; // 粗糙度、泡沫粗糙度修饰符
			float _Tile0, _Tile1, _Tile2, _Tile3; // 四层纹理的平铺系数
			float3 _SunIrradiance, _ScatterColor, _BubbleColor, _FoamColor; // 太阳辐射、散射颜色、气泡颜色、泡沫颜色
			float _HeightModifier, _BubbleDensity; // 高度修饰符、气泡密度
			float _DisplacementDepthAttenuation, _FoamDepthAttenuation, _NormalDepthAttenuation; // 位移深度衰减、泡沫深度衰减、法线深度衰减
			float _WavePeakScatterStrength, _ScatterStrength, _ScatterShadowStrength, _EnvironmentLightStrength; // 波峰散射强度、散射强度、散射阴影强度、环境光强度

			int _DebugTile0, _DebugTile1, _DebugTile2, _DebugTile3; // 调试模式开关（各层纹理）
			int _ContributeDisplacement0, _ContributeDisplacement1, _ContributeDisplacement2, _ContributeDisplacement3; // 各层纹理是否贡献到位移
			int _DebugLayer0, _DebugLayer1, _DebugLayer2, _DebugLayer3; // 各层调试模式开关
			float _FoamSubtract0, _FoamSubtract1, _FoamSubtract2, _FoamSubtract3; // 各层泡沫减法系数

			float4x4 _CameraInvViewProjection; // 相机逆视图投影矩阵
				TEXTURE2D(_CameraDepthTexture); // URP深度纹理声明。当前Shader主要用顶点自身深度衰减，保留该变量便于扩展屏幕空间水深效果。
				SAMPLER(sampler_CameraDepthTexture); // 深度纹理采样器。
            TEXTURE2D_ARRAY(_DisplacementTextures); // URP/HLSL风格位移纹理数组声明（包含高度和泡沫信息）。
            SAMPLER(sampler_DisplacementTextures); // 位移纹理数组采样器。
            TEXTURE2D_ARRAY(_SlopeTextures); // URP/HLSL风格斜率纹理数组声明（包含法线信息）。
            SAMPLER(sampler_SlopeTextures); // 斜率纹理数组采样器。
            SamplerState point_repeat_sampler, linear_repeat_sampler, trilinear_repeat_sampler; // 不同采样状态的采样器，保留原声明以便后续扩展自定义采样。

            float _Tile;// 全局平铺系数
```

### 代码作用说明

`_DisplacementTextures` 和 `_SlopeTextures` 的名字必须与 C# 中 `SetTexture` 的名字完全一致。`_DebugLayer0~3`、`_ContributeDisplacement0~3` 和 `_FoamSubtract0~3` 由 C# 每帧同步，用于控制每个频率层是否显示、是否贡献位移，以及泡沫强弱。

## 14. 顶点位移流程

### 原理与公式

四层位移叠加公式为：

$$
\mathbf{D}_{total}=\sum_{l=0}^{3}\mathbf{D}_l(xz\cdot tile_l)
$$

为了降低远处水面跳动，代码按照深度衰减位移：

$$
\mathbf{D}'=lerp(0,\mathbf{D}_{total},depth^{falloff})
$$

### 对应代码

```hlsl
			//执行流程先根据虚拟顶点着色器计算正常顶点传递到-》外壳着色器（细分控制器） 用于曲面细分控制计算曲面细分因子 -》 域着色器（细分计算着色器）执行曲面细分后的顶点处理 细分插值 细分后的三角形所有顶点执行真实顶点着色器计算处顶点的偏移 传递-》
			//-》几何着色器 -》片段着色器

			TessellationControlPoint dummyvp(VertexData v) { // 虚拟顶点着色器函数（实际未使用）  为曲面细分准备阶段提供数据
				TessellationControlPoint p;  //声明曲面细分控制点结构体 对象 用于保持曲面细分前的顶点位置
				p.vertex = v.vertex; //设置曲面细分着色器 当前顶点
				p.uv = v.uv; //当前坐标

				return p;
			}

			v2g vp(VertexData v) { // 实际的顶点处理函数，应用位移和转换
				v2g g; //声明传给几何着色器的结构体对象
				v.uv = 0; // 重置UV（后续使用世界坐标计算）
                g.worldPos = TransformObjectToWorld(v.vertex.xyz);  // 模型空间转世界空间（矩阵乘法）

				 // 使用当前世界坐标顶点的xz轴的值进行采样 采样4层位移纹理（xyz为位移，w为泡沫数据），并根据调试开关和贡献开关控制是否启用
                float3 displacement1 = SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures, g.worldPos.xz * _Tile0, 0, 0).xyz * _DebugLayer0 * _ContributeDisplacement0;
                float3 displacement2 = SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures, g.worldPos.xz * _Tile1, 1, 0).xyz * _DebugLayer1 * _ContributeDisplacement1;
                float3 displacement3 = SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures, g.worldPos.xz * _Tile2, 2, 0).xyz * _DebugLayer2 * _ContributeDisplacement2;
                float3 displacement4 = SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures, g.worldPos.xz * _Tile3, 3, 0).xyz * _DebugLayer3 * _ContributeDisplacement3;
				float3 displacement = displacement1 + displacement2 + displacement3 + displacement4; //叠加总位移结果

				float4 clipPos = TransformObjectToHClip(v.vertex.xyz); //计算顶点在剪空间位置
				float depth = 1 - Linear01Depth(clipPos.z / clipPos.w, _ZBufferParams); // 线性深度归一化 / 计算线性深度值：1表示近平面，0表示远平面 将当前的z轴深度值进行透视操作执行dx图形api的 转换到0到1的范围 并取反


				// 基于看到的深度进行衰减位移（远处位移衰减为0，优化性能和视觉效果）
				// 公式：lerp(0, displacement, depth^衰减系数)，pow确保非线性衰减  顶点距离摄像机越远则偏移编号越小
				displacement = lerp(0.0f, displacement, pow(saturate(depth), _DisplacementDepthAttenuation));

				v.vertex.xyz += TransformWorldToObjectDir(displacement.xyz, false); //将偏移后点的世界空间顶点坐标位置转换到对象空间
				
                g.pos = TransformObjectToHClip(v.vertex.xyz); //  // 计算最终裁剪空间位置
                g.uv = g.worldPos.xz; //使用世界空间XZ坐标作为UV（用于后续纹理采样）
                g.worldPos = TransformObjectToWorld(v.vertex.xyz); //重新计算偏移后的世界空间顶点位置
				g.depth = depth; // 存储深度值
				return g;
			}
```

### 代码作用说明

`dummyvp` 只是把原始控制点传给曲面细分阶段。真正做位移的是 `vp`：它用世界空间 `xz` 坐标采样位移贴图，将四层位移叠加后转换回对象空间，再更新顶点位置。这样水面波浪基于世界坐标连续采样，不依赖模型自身 UV。

## 15. Hull、Domain、Geometry 几何阶段

### 原理与公式

曲面细分流程为：Hull Shader 决定细分因子，硬件 Tessellator 生成新顶点，Domain Shader 用重心坐标插值属性。插值公式为：

$$
P=P_0b_0+P_1b_1+P_2b_2,\qquad b_0+b_1+b_2=1
$$

### 对应代码

```hlsl
			struct g2f { // 几何着色器到片段着色器的传输数据
				v2g data;  //继承v2g 顶点传给几何着色器的结构体的数据
				float2 barycentricCoordinates : TEXCOORD9; // 重心坐标（用于插值）
			};

			// Hull着色器的补丁函数（计算曲面细分因子）
			TessellationFactors PatchFunction(InputPatch<TessellationControlPoint, 3> patch) { //输入虚拟顶点着色器输出的3个顶点的曲面细分控制点结构体 数据
				//将三个顶点转换到世界坐标
                float3 p0 = TransformObjectToWorld(patch[0].vertex.xyz); 
                float3 p1 = TransformObjectToWorld(patch[1].vertex.xyz);
                float3 p2 = TransformObjectToWorld(patch[2].vertex.xyz);

                TessellationFactors f; //定义曲面细分因子结构体（存储三角形3条边和内部的细分程度） 对象
                float bias = -0.5 * 100;   // 裁剪偏置值
                if (cullTriangle(p0, p1, p2, bias)) {  // 执行视锥体剔除 若三角形被裁剪，细分因子设为0（不细分） 不为0执行细分
                    f.edge[0] = f.edge[1] = f.edge[2] = f.inside = 0; //三角形有被裁剪 不执行细分 三角形细分和内部细分为0
                } else {
                    f.edge[0] = TessellationHeuristic(p1, p2); // 边0（p1-p2）的细分因子
                    f.edge[1] = TessellationHeuristic(p2, p0); // 边1（p2-p0）的细分因子
                    f.edge[2] = TessellationHeuristic(p0, p1); // 边2（p0-p1）的细分因子
                	//内部三角形的细分 内部细分因子为三边平均值
                    f.inside = (TessellationHeuristic(p1, p2) +
                                TessellationHeuristic(p2, p0) +
                                TessellationHeuristic(p1, p2)) * (1 / 3.0);
                }
                return f;
            }
			// Hull着色器（定义曲面细分模式并传递控制点） 类似opengl曲面细分控制着色器
            [domain("tri")]  // 域类型：三角形
            [outputcontrolpoints(3)]  // 输出控制点数量：3（三角形） 
            [outputtopology("triangle_cw")] // 输出拓扑：顺时针三角形
            [partitioning("integer")]  // 细分分区模式：整数
            [patchconstantfunc("PatchFunction")] // 补丁函数：PatchFunction 计算边缘的曲面细分因子
            TessellationControlPoint hp(InputPatch<TessellationControlPoint, 3> patch, uint id : SV_OUTPUTCONTROLPOINTID) { //输入虚拟顶点着色器输出的3个顶点的曲面细分控制点结构体 数据
				//传到PatchFunction补丁函数（计算曲面细分因子） 进行计算 细分 将计算好
                return patch[id];  // 直接传递输出曲面细分顶点点控制点
            }

			//// 几何着色器（处理三角形图元，传递重心坐标）
            [maxvertexcount(3)]   // 最大输出顶点数：3（三角形）
            void gp(triangle v2g g[3], inout TriangleStream<g2f> stream) { //输入细分后三个顶点构成的三角形位置
                g2f g0, g1, g2; //生成几何着色器到片段着色器的传输数据 存储每个顶点自带的存储数据（顶点位置 uv 世界坐标位置 深度 ）
                g0.data = g[0]; 
                g1.data = g[1];
                g2.data = g[2];

                g0.barycentricCoordinates = float2(1, 0);  //存储每个顶点的重心坐标
                g1.barycentricCoordinates = float2(0, 1);
                g2.barycentricCoordinates = float2(0, 0);

                stream.Append(g0); //存储到数据流输出的数组
                stream.Append(g1);
                stream.Append(g2);
            }
			
			 // 宏定义：基于重心坐标插值顶点数据（x+y+z=1，z=1-x-y）
            #define DP_INTERPOLATE(fieldName) data.fieldName = \
                data.fieldName = patch[0].fieldName * barycentricCoordinates.x + \
                                 patch[1].fieldName * barycentricCoordinates.y + \
                                 patch[2].fieldName * barycentricCoordinates.z;               

            [domain("tri")]  // Domain着色器（曲面细分后插值顶点数据） (类似opengl1的细分计算着色器)   // 域类型：三角形
            v2g dp(TessellationFactors factors, OutputPatch<TessellationControlPoint, 3> patch, float3 barycentricCoordinates : SV_DOMAINLOCATION) {
				//domain着色器传入 曲面细分因子结构体对象 和曲面细分控制点结构体对象 以及重心坐标  （将两者 数据对象传递给细分图元生成 因为细分图元生成器无法访问  细分图元生成器自动计算细分后的三角形图元 并在细分计算着色器 计算生成细分后每个顶点） 
				//细分图元生成后的三角形每一条边都具有细分后的顶点位置重心坐标 根据细分图元后的一条边的重心坐标生成细分后的顶点
                VertexData data; //声明顶点着色器结构体对象
                DP_INTERPOLATE(vertex)//执行宏定义将基于重心坐标和（根据曲面控制器计算处理的三角形边缘的曲面细分因子）计算插值顶点数据 传递到 顶点着色器结构体对象data
                DP_INTERPOLATE(uv) //执行宏定义将基于重心坐标插值顶点UV数据传递到 顶点着色器结构体对象data

                return vp(data); //将曲面细分后的顶点数据传递到真实顶点着色器计算细分后顶点偏移
            }
```

### 代码作用说明

`PatchFunction` 计算三角形三条边和内部的细分因子。`hp` 直接传递控制点，`dp` 根据重心坐标生成细分后的顶点，并调用 `vp(data)` 完成水面位移。`gp` 给三角形附加重心坐标，可用于线框或边缘调试扩展。

## 16. 菲涅尔、Smith-Beckmann 与微表面 BRDF 函数

### 原理与公式

水面反射强烈依赖视角。Schlick 菲涅尔近似为：

$$
F=F_0+(1-F_0)(1-\mathbf{n}\cdot\mathbf{v})^5
$$

Beckmann 法线分布函数近似为：

$$
D(h)=\frac{\exp\left(\frac{(n\cdot h)^2-1}{\alpha^2(n\cdot h)^2}\right)}{\pi\alpha^2(n\cdot h)^4}
$$

### 对应代码

```hlsl
			float SchlickFresnel(float3 normal, float3 viewDir) {
				// 0.02f comes from the reflectivity bias of water kinda idk it's from a paper somewhere i'm not gonna link it tho lmaooo
				return 0.02f + (1 - 0.02f) * (pow(1 - DotClamped(normal, viewDir), 5.0f));
			}

			float SmithMaskingBeckmann(float3 H, float3 S, float roughness) { //BRDF的 几何遮蔽  Smith模型 传入半程向量  视角或者光方向 粗糙度  Smith遮蔽函数（Beckmann分布的近似，计算微表面的自遮蔽）
				//公式：G1(v) = (2 / (1 + √(1 + α² tan²θv)))，其中α是粗糙度，θv是视线与法线夹角
				// 此处使用拟合近似：(1 - 1.259a + 0.396a²) / (3.535a + 2.181a²)，a = cosθ / (α sinθ)
				float hdots = max(0.001f, DotClamped(H, S));  //半程向量与方向的点乘 
				float a = hdots / (roughness * sqrt(1 - hdots * hdots)); //半程向量与方向点乘的结果除以（粗糙度乘（半程向量与方向点乘的结果的平方取方的开根））  // 转换为角度相关参数
				float a2 = a * a; //做二次方
				//	// 拟合公式（当a < 1.6时有效，否则返回0）
				return a < 1.6f ? (1.0f - 1.259f * a + 0.396f * a2) / (3.535f * a + 2.181 * a2) : 0.0f;
			}
			//	// Beckmann微表面分布函数（描述法线分布概率）  // 公式：D(m) = exp(-tan²θ/α²) / (π * α² * cos⁴θ)   // 其中θ是微表面法线与宏表面法线的夹角，α是粗糙度
			float Beckmann(float ndoth, float roughness) {  //PBR的法线分布函数  传入法线与半程向量的夹角 和粗糙值
				float exp_arg = (ndoth * ndoth - 1) / (roughness * roughness * ndoth * ndoth);

				return exp(exp_arg) / (PI * roughness * roughness * ndoth * ndoth * ndoth * ndoth);
			}
```

### 代码作用说明

`SchlickFresnel` 计算视角相关反射率。`SmithMaskingBeckmann` 是几何遮蔽项近似，`Beckmann` 是法线分布项。它们共同构成后续 PBR 水面高光计算的基础。

## 17. 片元阶段采样位移、泡沫和斜率

### 原理与公式

片元法线由斜率贴图恢复：

$$
\mathbf{n}=normalize(-s_x,1,-s_z)
$$

泡沫按深度衰减：

$$
foam'=lerp(0,foam,depth^{foamFalloff})
$$

### 对应代码

```hlsl
			float4 fp(g2f f) : SV_TARGET {  //片段着色器
				// URP主光源数据。原Built-in版本依赖外部传入太阳方向；URP版在没有Atmosphere脚本时自动回退到GetMainLight。
				Light mainLight = GetMainLight(); // 从URP Lighting.hlsl获取主方向光，包含direction和color。
                float3 lightDir = dot(_SunDirection, _SunDirection) > 0.0001f ? -normalize(_SunDirection) : normalize(mainLight.direction);  //光方向向量：优先使用大气系统太阳方向，否则使用URP主光。
				float3 lightColor = dot(_SunColor, _SunColor) > 0.0001f ? _SunColor : mainLight.color; // 光源颜色：优先使用大气系统太阳色，否则使用URP主光颜色。
				float3 sunIrradiance = dot(_SunIrradiance, _SunIrradiance) > 0.0001f ? _SunIrradiance : lightColor; // PBR分支使用的太阳辐照度，为黑色时自动退回主光颜色。
                float3 viewDir = normalize(_WorldSpaceCameraPos - f.data.worldPos); //细分顶点位置指向摄像机的方向向量
                float3 halfwayDir = normalize(lightDir + viewDir); //计算半程向量
				float depth = f.data.depth; //获取当前片段的深度
				float LdotH = DotClamped(lightDir, halfwayDir);// // 光线与半程向量的点积（ clamped to [0,1]）
				float VdotH = DotClamped(viewDir, halfwayDir);// 视线与半程向量的点积
				
				// 采样四个频率层的位移和泡沫纹理 // 每层包含RGB位移和A通道泡沫信息
                float4 displacementFoam1 = SAMPLE_TEXTURE2D_ARRAY(_DisplacementTextures, sampler_DisplacementTextures, f.data.uv * _Tile0, 0) * _DebugLayer0;
				displacementFoam1.a += _FoamSubtract0;  //引用个层泡沫减去的系数各层泡沫减法系数 
                float4 displacementFoam2 = SAMPLE_TEXTURE2D_ARRAY(_DisplacementTextures, sampler_DisplacementTextures, f.data.uv * _Tile1, 1) * _DebugLayer1;
				displacementFoam2.a += _FoamSubtract1;
                float4 displacementFoam3 = SAMPLE_TEXTURE2D_ARRAY(_DisplacementTextures, sampler_DisplacementTextures, f.data.uv * _Tile2, 2) * _DebugLayer2;
				displacementFoam3.a += _FoamSubtract2;
                float4 displacementFoam4 = SAMPLE_TEXTURE2D_ARRAY(_DisplacementTextures, sampler_DisplacementTextures, f.data.uv * _Tile3, 3) * _DebugLayer3;
				displacementFoam4.a += _FoamSubtract3;
                float4 displacementFoam = displacementFoam1 + displacementFoam2 + displacementFoam3 + displacementFoam4; // 合并所有层的位移和泡沫信息

						//   // 采样四个频率层的斜率纹理采样4层斜率纹理（斜率用于计算水面法线）
				float2 slopes1 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures, f.data.uv * _Tile0, 0).xy * _DebugLayer0;
				float2 slopes2 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures, f.data.uv * _Tile1, 1).xy * _DebugLayer1;
				float2 slopes3 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures, f.data.uv * _Tile2, 2).xy * _DebugLayer2;
				float2 slopes4 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures, f.data.uv * _Tile3, 3).xy * _DebugLayer3;
				float2 slopes = slopes1 + slopes2 + slopes3 + slopes4; // 合并所有层的斜率信息 总斜率方向信息

				
				slopes *= _NormalStrength; // 应用缩放斜率强度（控制法线起伏）
					// 计算泡沫强度（基于深度衰减，远处泡沫消失）
				float foam = lerp(0.0f, saturate(displacementFoam.a), pow(depth, _FoamDepthAttenuation)); //更具深度与泡沫深度衰减的次方做为系数插值 无泡沫效果到A通道泡沫面积效果的插值
```

### 代码作用说明

片元阶段再次采样四层位移贴图，取 `a` 通道累加泡沫；同时采样四层斜率贴图并累加法线扰动。由于顶点位移和片元法线来自同一组 FFT 输出，水面形状与光照细节能够保持一致。

## 18. PBR 水面散射、环境反射和泡沫混合

### 原理与公式

PBR 分支的最终颜色为：

$$
C=(1-F)C_{scatter}+C_{specular}+F C_{env}
$$

水的基础反射率可由折射率 $\eta=1.33$ 得到：

$$
F_0=\left(\frac{\eta-1}{\eta+1}\right)^2
$$

泡沫最终混合为：

$$
C_{final}=lerp(C,C_{foam},foam)
$$

### 对应代码

```hlsl
				#ifdef NEW_LIGHTING // 使用新PBR光照模型
				float3 macroNormal = float3(0, 1, 0); // 宏观法线（平静水面的法线）宏观水面的上方向法线 整体片段的宏观方向
				// 从斜率计算微观法线：slopes.xy是dx/dy和dz/dy，法线为(-dx, 1, -dz) 斜率(-slopes.x, -slopes.y)对应法线的XZ分量 利用斜率改变当前像素片段的法线方向
				float3 mesoNormal = normalize(float3(-slopes.x, 1.0f, -slopes.y));
				// 基于深度衰减法线（远处法线趋近于宏观法线）  根据深度与法线深度系数计算的次方做为摄像机到水面的距离系数 越远水面越平坦 越近水面法线越偏移
				mesoNormal = normalize(lerp(float3(0, 1, 0), mesoNormal, pow(saturate(depth), _NormalDepthAttenuation)));
				mesoNormal = normalize(TransformObjectToWorldNormal(normalize(mesoNormal))); //将计算号的偏移法线转换到世界坐标空间 做为法线

				float NdotL = DotClamped(mesoNormal, lightDir); //新法线与光方向点乘并钳制到0到1区间  // 法线与光线的点积（漫反射因子）  // 计算兰伯特项

				
				float a = _Roughness + foam * _FoamRoughnessModifier; // 计算有效粗糙度（考虑泡沫影响） // 泡沫区域通常更粗糙 基础的粗糙度加上泡沫的粗糙度
				float ndoth = max(0.0001f, dot(mesoNormal, halfwayDir)); // 法线与半程向量的点积

				// 计算Smith遮蔽因子（视线和光线方向） 计算几何遮蔽项（Smith模型 类似opengl 里的写法）
				float viewMask = SmithMaskingBeckmann(halfwayDir, viewDir, a); //传入半程向量 视角方向 粗糙度
				float lightMask = SmithMaskingBeckmann(halfwayDir, lightDir, a); //传入半程向量 光方向 粗糙度
				 // 整体遮蔽因子（1/(1 + G1(v) + G1(l))）
				float G = rcp(1 + viewMask + lightMask); //BRDF的几何项

				// 菲涅尔效应（基于IOR计算基础反射率）
				float eta = 1.33f;  // 水的折射率（相对空气）
				float R = ((eta - 1) * (eta - 1)) / ((eta + 1) * (eta + 1));   // 垂直入射时的反射率
				float thetaV = acos(viewDir.y);  // 视线与法线的夹角

				// 修正的菲涅尔公式（考虑粗糙度影响）
				float numerator = pow(1 - dot(mesoNormal, viewDir), 5 * exp(-2.69 * a));//使用修改后带有粗糙度的涅斐尔方程计算 该部分为涅斐尔（1-（h*v））^5的改版带粗糙度
				float F = R + (1 - R) * numerator / (1.0f + 22.7f * pow(a, 1.5f)); //涅斐尔计算
				F = saturate(F); //// 确保在[0,1]范围内

				// 高光计算（基于Beckmann分布的PBR公式） // BRDF = (F * D * G) / (4 * (n·l) * (n·v))
				float3 specular = sunIrradiance * F * G * Beckmann(ndoth, a); //将几何函数 涅斐尔范畴 法线分布函数 乘太阳辐射度
				specular /= 4.0f * max(0.001f, DotClamped(macroNormal, lightDir)); //  // 分母项 标准BRDF的计算
				specular *= DotClamped(mesoNormal, lightDir); //乘法线与光方向的点乘 添加漫反射项

				// 环境反射（从立方体贴图采样）
				float3 envReflection = SAMPLE_TEXTURECUBE(_EnvironmentMap, sampler_EnvironmentMap, reflect(-viewDir, mesoNormal)).rgb;  //采样环境立方体贴图
				envReflection *= _EnvironmentLightStrength;// 缩放环境光强度

				// 水面高度（用于散射计算） 散射效果计算
				float H = max(0.0f, displacementFoam.y) * _HeightModifier;  // 波高 偏移纹理的高度乘 高度修饰符
				float3 scatterColor = _ScatterColor; // 散射基础颜色
				float3 bubbleColor = _BubbleColor; // 气泡颜色
				float bubbleDensity = _BubbleDensity;  // 气泡密度

				// 散射系数计算（基于波峰、视角、光线方向）
				// k1：波峰散射（与波高、光线-视线夹角、光线-法线夹角相关） 波峰散射强度 乘 波高乘（光方向与视角方向的夹角的4次方）乘（光方向与法线的点乘系数半值-0.5系数的3次方）
				float k1 = _WavePeakScatterStrength * H * pow(DotClamped(lightDir, -viewDir), 4.0f) * pow(0.5f - 0.5f * dot(lightDir, mesoNormal), 3.0f);
				// k2：视角相关散射（与视线-法线夹角平方相关）
				float k2 = _ScatterStrength * pow(DotClamped(viewDir, mesoNormal), 2.0f);//散射强度乘 （视角反向与法线的点乘）的2次方
				// k3: 散射阴影 - 与漫反射相关
				float k3 = _ScatterShadowStrength * NdotL;//散射阴影强度乘法线与光方向的点乘
				// k4: 气泡散射 - 恒定密度贡献
				float k4 = bubbleDensity;
				//// 组合散射效果 波峰散射和视角相关散射叠加运用散射基础颜色*（1 + lightMask）的取反
				float3 scatter = (k1 + k2) * scatterColor * sunIrradiance * rcp(1 + lightMask);
				scatter += k3 * scatterColor * sunIrradiance + k4 * bubbleColor * sunIrradiance; //叠加散射阴影 和气泡散射（乘太阳光辐射度） 

				// 最终颜色合成
                // 公式：输出 = (1 - F) * 散射 + 镜面反射 + F * 环境反射 f为涅斐尔效果
				float3 output = (1 - F) * scatter + specular + F * envReflection; 
				output = max(0.0f, output);   // 确保颜色非负
				output = lerp(output, _FoamColor, saturate(foam)); // 泡沫颜色混合
```

### 代码作用说明

该分支优先使用大气系统传入的太阳方向和颜色，没有时回退到 URP `GetMainLight()`。高光来自微表面模型，散射由波峰高度、视角、光照方向和气泡密度共同控制，环境反射来自 Cubemap，最后用泡沫强度混合 `_FoamColor`。

## 19. 备用光照分支与调试显示

### 原理与公式

备用分支使用更传统的漫反射、Blinn-Phong 高光和 Fresnel：

$$
C=C_{ambient}+C_{diffuse}+C_{specular}+C_{fresnel}
$$

调试模式使用余弦图案显示各层 tile 采样密度。

### 对应代码

```hlsl
				#else
				slopes *= _NormalStrength;
				float3 normal = normalize(float3(-slopes.x, 1.0f, -slopes.y));
                normal = normalize(TransformObjectToWorldNormal(normalize(normal)));

				float ndotl = DotClamped(lightDir, normal);

				float3 diffuseReflectance = _DiffuseReflectance / PI;
                float3 diffuse = lightColor * ndotl * diffuseReflectance;

				// Schlick Fresnel
				float3 fresnelNormal = normal;
				fresnelNormal.xz *= _FresnelNormalStrength;
				fresnelNormal = normalize(fresnelNormal);
				float base = 1 - dot(viewDir, fresnelNormal);
				float exponential = pow(base, _FresnelShininess);
				float R = exponential + _FresnelBias * (1.0f - exponential);
				R *= _FresnelStrength;
				
				float3 fresnel = _FresnelColor * R;
                
				if (_UseEnvironmentMap) {
					float3 reflectedDir = reflect(-viewDir, normal);
					float3 skyCol = SAMPLE_TEXTURECUBE(_EnvironmentMap, sampler_EnvironmentMap, reflectedDir).rgb;
					float3 sun = lightColor * pow(max(0.0f, DotClamped(reflectedDir, lightDir)), 500.0f); // 使用URP主光/大气太阳颜色生成太阳高光。

					fresnel = skyCol.rgb * R;
					fresnel += sun * R;
				}


				float3 specularReflectance = _SpecularReflectance;
				float3 specNormal = normal;
				specNormal.xz *= _SpecularNormalStrength;
				specNormal = normalize(specNormal);
				float spec = pow(DotClamped(specNormal, halfwayDir), _Shininess) * ndotl;
                float3 specular = lightColor * specularReflectance * spec;

				// Schlick Fresnel but again for specular
				base = 1 - DotClamped(viewDir, halfwayDir);
				exponential = pow(base, 5.0f);
				R = exponential + _FresnelBias * (1.0f - exponential);

				specular *= R;
				

				float3 output = _Ambient + diffuse + specular + fresnel;
				output = lerp(output, _TipColor, saturate(foam));
				#endif

				 // 调试显示模式 - 显示不同频率层的波浪图案
				if (_DebugTile0) {
					// 使用余弦函数生成网格图案显示平铺0
					output = cos(f.data.uv.x * _Tile0 * PI) * cos(f.data.uv.y * _Tile0 * PI);
				}

				if (_DebugTile1) {
					// 高频余弦图案显示平铺1
					output = cos(f.data.uv.x * _Tile1) * 1024 * cos(f.data.uv.y * _Tile1) * 1024;
				}

				if (_DebugTile2) {
					// 高频余弦图案显示平铺2
					output = cos(f.data.uv.x * _Tile2) * 1024 * cos(f.data.uv.y * _Tile2) * 1024;
				}

				if (_DebugTile3) {
					// 高频余弦图案显示平铺3
					output = cos(f.data.uv.x * _Tile3) * 1024 * cos(f.data.uv.y * _Tile3) * 1024;
				}
				// 返回最终颜色（不透明）
				return float4(output, 1.0f);
			}

			ENDHLSL
		}
	}
}
```

### 代码作用说明

因为 Shader 顶部定义了 `NEW_LIGHTING`，默认使用 PBR 分支。如果注释该宏，代码会进入备用光照路径。`_DebugTile0~3` 可用来检查四层波浪的平铺是否正确。

---

# 第三部分：`FFTWater.cs` —— Unity/URP 运行时调度

C# 脚本是整个系统的控制中心。它不直接计算海浪形状，而是创建 GPU 资源、上传参数、按正确顺序 Dispatch ComputeShader，并把生成的贴图绑定给 URP 水面材质。

## 20. 类声明、URP 引用、核心资源和 Inspector 参数

### 原理与公式

脚本需要 `MeshFilter` 和 `MeshRenderer`：前者保存运行时水面网格，后者使用 URP 水面材质绘制。`SpectrumSettings` 是 GPU 使用的紧凑参数结构，`DisplaySpectrumSettings` 是 Inspector 暴露给用户调节的版本。

四个海浪层，每层两组频谱参数，总计八组谱：

$$
4\ layers\times2\ spectrums=8\ spectrum\ settings
$$

### 对应代码

```csharp
using System;
using System.Collections;
using System.Collections.Generic;
using static System.Runtime.InteropServices.Marshal;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal; // 引入URP相机扩展数据，用于在代码中请求深度纹理，保证水面Shader可访问_CameraDepthTexture

[RequireComponent(typeof(MeshFilter), typeof(MeshRenderer))] // 强制物体拥有MeshFilter和MeshRenderer：MeshFilter保存运行时生成的水面网格，MeshRenderer负责使用URP水面材质绘制
public class FFTWater : MonoBehaviour { // FFT海面主控制脚本：CPU负责创建网格/材质/贴图资源，ComputeShader负责生成频谱和FFT贴图，URP Shader负责最终渲染
    public Shader waterShader; // 水面渲染Shader：URP版本默认使用Custom/FFTWaterURP
    public ComputeShader fftComputeShader; // FFT计算着色器：不属于Built-in/URP管线，负责在GPU上生成频谱、位移、斜率、泡沫等贴图

    public Atmosphere atmosphere; // 大气散射脚本引用：用于读取太阳方向和太阳颜色，使水面光照与天空/大气保持一致

    public int planeLength = 10; // 程序化水面网格边长：数值越大，水面覆盖范围越大
    public int quadRes = 10; // 每单位长度的网格细分密度：越大基础顶点越多，配合曲面细分可提升近处精度

    private Camera cam; // 当前渲染相机缓存：用于计算逆视图投影矩阵，并在URP中请求深度纹理

    private Material waterMaterial; // 运行时创建的水面材质实例：避免直接修改项目资产中的共享材质
    private Mesh mesh; // 运行时生成的水面网格
    private Vector3[] vertices; // 水面网格顶点数组：用于创建规则平面
    private Vector3[] normals; // 水面网格初始法线数组：基础平面向上，最终细节法线主要来自斜率贴图

    public struct SpectrumSettings { // 传入ComputeShader的频谱参数结构体：对应JONSWAP能谱和方向谱参数
        public float scale;
        public float angle;
        public float spreadBlend;
        public float swell;
        public float alpha;
        public float peakOmega;
        public float gamma;
        public float shortWavesFade; 
    }

    SpectrumSettings[] spectrums = new SpectrumSettings[8]; // 8组频谱参数：4个尺度层，每层可混合2组风浪/涌浪参数

    [System.Serializable]
    public struct DisplaySpectrumSettings { // Inspector显示用频谱参数：更适合美术/调试修改，之后会转换为ComputeShader使用的SpectrumSettings
        [Range(0, 5)]
        public float scale;
        public float windSpeed;
        [Range(0.0f, 360.0f)]
        public float windDirection;
        public float fetch;
        [Range(0, 1)]
        public float spreadBlend;
        [Range(0, 1)]
        public float swell;
        public float peakEnhancement;
        public float shortWavesFade;
    }

    [Header("Spectrum Settings")]
    [Range(0, 100000)]
    public int seed = 0;

    [Range(0.0f, 0.1f)]
    public float lowCutoff = 0.0001f;

    [Range(0.1f, 9000.0f)]
    public float highCutoff = 9000.0f;

    [Range(0.0f, 20.0f)]
    public float gravity = 9.81f;

    [Range(2.0f, 20.0f)]
    public float depth = 20.0f;

    [Range(0.0f, 200.0f)]
    public float repeatTime = 200.0f;

    [Range(0.0f, 5.0f)]
    public float speed = 1.0f;

    public Vector2 lambda = new Vector2(1.0f, 1.0f);

    [Range(0.0f, 10.0f)]
    public float displacementDepthFalloff = 1.0f;

    public bool updateSpectrum = false;

    [Header("Layer One")]
    [Range(0, 2048)]
    public int lengthScale1 = 256;
    [Range(0.01f, 3.0f)]
    public float tile1 = 8.0f;
    public bool visualizeTile1 = false;
    public bool visualizeLayer1 = false;
    public bool contributeDisplacement1 = true;
    [SerializeField]
    public DisplaySpectrumSettings spectrum1;
    [SerializeField]
    public DisplaySpectrumSettings spectrum2;

    [Header("Layer Two")]
    [Range(0, 2048)]
    public int lengthScale2 = 256;
    [Range(0.01f, 3.0f)]
    public float tile2 = 8.0f;
    public bool visualizeTile2 = false;
    public bool visualizeLayer2 = false;
    public bool contributeDisplacement2 = true;
    [SerializeField]
    public DisplaySpectrumSettings spectrum3;
    [SerializeField]
    public DisplaySpectrumSettings spectrum4;

    [Header("Layer Three")]
    [Range(0, 2048)]
    public int lengthScale3 = 256;
    [Range(0.01f, 3.0f)]
    public float tile3 = 8.0f;
    public bool visualizeTile3 = false;
    public bool visualizeLayer3 = false;
    public bool contributeDisplacement3 = true;
    [SerializeField]
    public DisplaySpectrumSettings spectrum5;
    [SerializeField]
    public DisplaySpectrumSettings spectrum6;

    [Header("Layer Four")]
    [Range(0, 2048)]
    public int lengthScale4 = 256;
    [Range(0.01f, 3.0f)]
    public float tile4 = 8.0f;
    public bool visualizeTile4 = false;
    public bool visualizeLayer4 = false;
    public bool contributeDisplacement4 = true;
    [SerializeField]
    public DisplaySpectrumSettings spectrum7;
    [SerializeField]
    public DisplaySpectrumSettings spectrum8;

    [Header("Normal Settings")]
    [Range(0.0f, 20.0f)]
    public float normalStrength = 1;
    
    [Range(0.0f, 10.0f)]
    public float normalDepthFalloff = 1.0f;

    [Header("Material Settings")]
    [ColorUsageAttribute(false, true)]
    public Color ambient;

    [ColorUsageAttribute(false, true)]
    public Color diffuseReflectance;

    [ColorUsageAttribute(false, true)]
    public Color specularReflectance;

    [Range(0.0f, 10.0f)]
    public float shininess = 1.0f;

    [Range(0.0f, 5.0f)]
    public float specularNormalStrength = 1.0f;

    [ColorUsageAttribute(false, true)]
    public Color fresnelColor;

    public bool useTextureForFresnel = false;
    public Texture environmentTexture;

    [Range(0.0f, 1.0f)]
    public float fresnelBias = 0.0f;

    [Range(0.0f, 3.0f)]
    public float fresnelStrength = 1.0f;

    [Range(0.0f, 20.0f)]
    public float fresnelShininess = 5.0f;

    [Range(0.0f, 5.0f)]
    public float fresnelNormalStrength = 1.0f;

    [ColorUsageAttribute(false, true)]
    public Color tipColor;

    [Header("PBR Settings")]
    [ColorUsageAttribute(false, true)]
    public Color sunIrradiance;

    [ColorUsageAttribute(false, true)]
    public Color scatter;

    [ColorUsageAttribute(false, true)]
    public Color bubble;

    [Range(0.0f, 1.0f)]
    public float bubbleDensity = 1.0f;

    [Range(0.0f, 2.0f)]
    public float roughness = 0.1f;

    [Range(0.0f, 2.0f)]
    public float foamRoughnessModifier = 1.0f;

    [Range(0.0f, 10.0f)]
    public float heightModifier = 1.0f;

    [Range(0.0f, 10.0f)]
    public float wavePeakScatterStrength = 1.0f;
    
    [Range(0.0f, 10.0f)]
    public float scatterStrength = 1.0f;

    [Range(0.0f, 10.0f)]
    public float scatterShadowStrength = 1.0f;

    [Range(0.0f, 2.0f)]
    public float environmentLightStrength = 1.0f;

    [Header("Foam Settings")]
    [ColorUsageAttribute(false, true)]
    public Color foam;

    [Range(-2.0f, 2.0f)]
    public float foamBias = -0.5f;

    [Range(-10.0f, 10.0f)]
    public float foamThreshold = 0.0f;

    [Range(0.0f, 1.0f)]
    public float foamAdd = 0.5f;

    [Range(0.0f, 1.0f)]
    public float foamDecayRate = 0.05f;

    [Range(0.0f, 10.0f)]
    public float foamDepthFalloff = 1.0f;

    [Range(-2.0f, 2.0f)]
    public float foamSubtract1 = 0.0f;
    [Range(-2.0f, 2.0f)]
    public float foamSubtract2 = 0.0f;
    [Range(-2.0f, 2.0f)]
    public float foamSubtract3 = 0.0f;
    [Range(-2.0f, 2.0f)]
    public float foamSubtract4 = 0.0f;
```

### 代码作用说明

这部分定义了全部可调参数，包括频谱参数、四个海浪 layer、法线、材质、PBR、泡沫和调试开关。`using UnityEngine.Rendering.Universal` 是 URP 迁移新增内容，用于后面访问 `UniversalAdditionalCameraData` 并请求相机深度纹理。

## 21. GPU 资源句柄与外部访问接口

### 原理与公式

位移、斜率、频谱和浮力贴图都位于 GPU。提供 Getter 可以让其他系统复用这些结果，例如浮力、漂浮物或调试工具。

### 对应代码

```csharp
    private RenderTexture displacementTextures, 
                          slopeTextures, 
                          initialSpectrumTextures, 
                          pingPongTex, 
                          pingPongTex2, 
                          spectrumTextures,
                          buoyancyDataTex;

    private ComputeBuffer spectrumBuffer;

    private int N, logN, threadGroupsX, threadGroupsY;

    public RenderTexture GetDisplacementMap() {
        return displacementTextures;
    }

    public RenderTexture GetSlopeMap() {
        return slopeTextures;
    }

    public RenderTexture GetInitialSpectrum() {
        return initialSpectrumTextures;
    }

    public RenderTexture GetDisplacementSpectrum() {
        return spectrumTextures;
    }

    public RenderTexture GetBuoyancyData() {
        return buoyancyDataTex;
    }
```

### 代码作用说明

`displacementTextures`、`slopeTextures`、`initialSpectrumTextures` 和 `spectrumTextures` 在初始化时创建。`spectrumBuffer` 负责把八组频谱参数传入 ComputeShader。

## 22. 程序化创建水面网格

### 原理与公式

基础水面是规则网格。顶点数量为：

$$
N_v=(planeLength\cdot quadRes+1)^2
$$

索引数量为：

$$
N_i=(planeLength\cdot quadRes)^2\cdot6
$$

### 对应代码

```csharp
    private void CreateWaterPlane() {
        GetComponent<MeshFilter>().mesh = mesh = new Mesh();
        mesh.name = "Water";
        mesh.indexFormat = IndexFormat.UInt32;

        float halfLength = planeLength * 0.5f;
        int sideVertCount = planeLength * quadRes;

        vertices = new Vector3[(sideVertCount + 1) * (sideVertCount + 1)];
        Vector2[] uv = new Vector2[vertices.Length];
        Vector4[] tangents = new Vector4[vertices.Length];
        Vector4 tangent = new Vector4(1f, 0f, 0f, -1f);

        for (int i = 0, x = 0; x <= sideVertCount; ++x) {
            for (int z = 0; z <= sideVertCount; ++z, ++i) {
                vertices[i] = new Vector3(((float)x / sideVertCount * planeLength) - halfLength, 0, ((float)z / sideVertCount * planeLength) - halfLength);
                uv[i] = new Vector2((float)x / sideVertCount, (float)z / sideVertCount);
                tangents[i] = tangent;
            }
        }

        mesh.vertices = vertices;
        mesh.uv = uv;
        mesh.tangents = tangents;

        int[] triangles = new int[sideVertCount * sideVertCount * 6];

        for (int ti = 0, vi = 0, x = 0; x < sideVertCount; ++vi, ++x) {
            for (int z = 0; z < sideVertCount; ti += 6, ++vi, ++z) {
                triangles[ti] = vi;
                triangles[ti + 1] = vi + 1;
                triangles[ti + 2] = vi + sideVertCount + 2;
                triangles[ti + 3] = vi;
                triangles[ti + 4] = vi + sideVertCount + 2;
                triangles[ti + 5] = vi + sideVertCount + 1;
            }
        }

        mesh.triangles = triangles;
        mesh.RecalculateNormals();
        normals = mesh.normals;
    }
```

### 代码作用说明

`CreateWaterPlane` 在 XZ 平面生成水面网格。基础网格不需要极高密度，因为 URP Shader 中还会做曲面细分。`IndexFormat.UInt32` 避免高分辨率网格超过 65535 顶点后索引溢出。

## 23. 创建 URP 水面材质

### 原理与公式

材质必须使用 URP 版本 Shader：

```csharp
Shader.Find("Custom/FFTWaterURP")
```

否则后续 ComputeShader 生成的贴图即使存在，也不会被正确采样和渲染。

### 对应代码

```csharp
    void CreateMaterial() { // 创建URP水面材质：将Shader实例化后赋给MeshRenderer
        if (waterShader == null) { // 如果Inspector没有指定Shader，则自动查找URP转换后的Shader
            waterShader = Shader.Find("Custom/FFTWaterURP"); // URP版本Shader名，避免用户忘记手动拖拽导致材质为空
        }

        if (waterShader == null) { // 如果仍然找不到，说明Shader文件未导入或名称不匹配
            Debug.LogError("FFTWater: 找不到 Custom/FFTWaterURP Shader，请确认FFTWaterURP.shader已放入项目并成功编译。", this); // 输出明确错误，方便定位
            return; // 无Shader无法创建材质，停止执行
        }

        if (waterMaterial != null) { // 防止重复创建材质实例导致内存泄漏
            return;
        }

        waterMaterial = new Material(waterShader); // 创建材质实例，运行时参数全部写入该实例
        waterMaterial.name = "FFT Water URP Material (Runtime)"; // 给运行时材质命名，便于Frame Debugger/Inspector识别

        MeshRenderer renderer = GetComponent<MeshRenderer>(); // 获取当前物体的MeshRenderer组件
        renderer.sharedMaterial = waterMaterial; // 使用sharedMaterial绑定运行时材质，避免Unity自动再复制一份material实例
    }
```

### 代码作用说明

如果 Inspector 没有指定 Shader，脚本自动查找 `Custom/FFTWaterURP`。材质使用运行时实例，避免直接污染项目中的共享材质资产。

## 24. 上传 FFT 全局参数和 JONSWAP 参数

### 原理与公式

JONSWAP 参数由 fetch 和 wind speed 计算：

$$
\alpha=0.076\left(\frac{gF}{U^2}\right)^{-0.22}
$$

$$
\omega_p=22\left(\frac{UF}{g^2}\right)^{-0.33}
$$

其中 $F$ 为 fetch，$U$ 为风速。

### 对应代码

```csharp
    void SetFFTUniforms() {
        fftComputeShader.SetVector("_Lambda", lambda);
        fftComputeShader.SetFloat("_FrameTime", Time.time * speed);
        fftComputeShader.SetFloat("_DeltaTime", Time.deltaTime);
        fftComputeShader.SetFloat("_Gravity", gravity);
        fftComputeShader.SetFloat("_RepeatTime", repeatTime);
        fftComputeShader.SetInt("_N", N);
        fftComputeShader.SetInt("_Seed", seed);
        fftComputeShader.SetInt("_LengthScale0", lengthScale1);
        fftComputeShader.SetInt("_LengthScale1", lengthScale2);
        fftComputeShader.SetInt("_LengthScale2", lengthScale3);
        fftComputeShader.SetInt("_LengthScale3", lengthScale4);
        fftComputeShader.SetFloat("_NormalStrength", normalStrength);
        fftComputeShader.SetFloat("_FoamThreshold", foamThreshold);
        fftComputeShader.SetFloat("_Depth", depth);
        fftComputeShader.SetFloat("_LowCutoff", lowCutoff);
        fftComputeShader.SetFloat("_HighCutoff", highCutoff);
        fftComputeShader.SetFloat("_FoamBias", foamBias);
        fftComputeShader.SetFloat("_FoamDecayRate", foamDecayRate);
        fftComputeShader.SetFloat("_FoamThreshold", foamThreshold);
        fftComputeShader.SetFloat("_FoamAdd", foamAdd);
    }

    float JonswapAlpha(float fetch, float windSpeed) {
        return 0.076f * Mathf.Pow(gravity * fetch / windSpeed / windSpeed, -0.22f);
    }

    float JonswapPeakFrequency(float fetch, float windSpeed) {
        return 22 * Mathf.Pow(windSpeed * fetch / gravity / gravity, -0.33f);
    }

    void FillSpectrumStruct(DisplaySpectrumSettings displaySettings, ref SpectrumSettings computeSettings) {
        computeSettings.scale = displaySettings.scale;
        computeSettings.angle = displaySettings.windDirection / 180 * Mathf.PI;
        computeSettings.spreadBlend = displaySettings.spreadBlend;
        computeSettings.swell = Mathf.Clamp(displaySettings.swell, 0.01f, 1);
        computeSettings.alpha = JonswapAlpha(displaySettings.fetch, displaySettings.windSpeed);
        computeSettings.peakOmega = JonswapPeakFrequency(displaySettings.fetch, displaySettings.windSpeed);
        computeSettings.gamma = displaySettings.peakEnhancement;
        computeSettings.shortWavesFade = displaySettings.shortWavesFade;
    }

    void SetSpectrumBuffers() {
        FillSpectrumStruct(spectrum1, ref spectrums[0]);
        FillSpectrumStruct(spectrum2, ref spectrums[1]);
        FillSpectrumStruct(spectrum3, ref spectrums[2]);
        FillSpectrumStruct(spectrum4, ref spectrums[3]);
        FillSpectrumStruct(spectrum5, ref spectrums[4]);
        FillSpectrumStruct(spectrum6, ref spectrums[5]);
        FillSpectrumStruct(spectrum7, ref spectrums[6]);
        FillSpectrumStruct(spectrum8, ref spectrums[7]);

        spectrumBuffer.SetData(spectrums);
        fftComputeShader.SetBuffer(0, "_Spectrums", spectrumBuffer);
    }
```

### 代码作用说明

`SetFFTUniforms` 每帧同步时间、重力、水深、cutoff、泡沫等参数。`FillSpectrumStruct` 把 Inspector 参数转换为 GPU 参数，`SetSpectrumBuffers` 把八组谱写入 `ComputeBuffer` 并绑定到 `_Spectrums`。

## 25. 逆 FFT 调度和 RenderTexture 创建

### 原理与公式

二维逆 FFT 分为两次 Dispatch：先水平，再垂直。

```text
CS_HorizontalFFT -> CS_VerticalFFT
```

ComputeShader 写入 RenderTexture 时必须设置：

```csharp
enableRandomWrite = true
```

### 对应代码

```csharp
    void InverseFFT(RenderTexture spectrumTextures) {
        fftComputeShader.SetTexture(3, "_FourierTarget", spectrumTextures);
        fftComputeShader.Dispatch(3, 1, N, 1);
        fftComputeShader.SetTexture(4, "_FourierTarget", spectrumTextures);
        fftComputeShader.Dispatch(4, 1, N, 1);
    }

    RenderTexture CreateRenderTex(int width, int height, int depth, RenderTextureFormat format, bool useMips) {
        RenderTexture rt = new RenderTexture(width, height, 0, format, RenderTextureReadWrite.Linear);
        rt.dimension = UnityEngine.Rendering.TextureDimension.Tex2DArray;
        rt.filterMode = FilterMode.Bilinear;
        rt.wrapMode = TextureWrapMode.Repeat;
        rt.enableRandomWrite = true;
        rt.volumeDepth = depth;
        rt.useMipMap = useMips;
        rt.autoGenerateMips = false;
        rt.anisoLevel = 16;
        rt.Create();

        return rt;
    }

    RenderTexture CreateRenderTex(int width, int height, RenderTextureFormat format, bool useMips) {
        RenderTexture rt = new RenderTexture(width, height, 0, format, RenderTextureReadWrite.Linear);
        rt.filterMode = FilterMode.Bilinear;
        rt.wrapMode = TextureWrapMode.Repeat;
        rt.enableRandomWrite = true;
        rt.useMipMap = useMips;
        rt.autoGenerateMips = false;
        rt.anisoLevel = 16;
        rt.Create();

        return rt;
    }
```

### 代码作用说明

带 `depth` 的重载用于创建 `Texture2DArray`，例如 4 层位移贴图、4 层斜率贴图和 8 层频谱贴图。不带 `depth` 的重载用于普通二维贴图，例如浮力数据贴图。

## 26. URP 相机深度设置与初始化流程

### 原理与公式

URP 中 `_CameraDepthTexture` 并不总是默认生成，因此脚本主动请求深度纹理：

```csharp
cameraData.requiresDepthTexture = true;
cam.depthTextureMode |= DepthTextureMode.Depth;
```

初始化顺序是：创建网格、创建材质、查找相机、请求深度、创建纹理、创建 buffer、上传参数、初始化频谱、打包共轭频谱。

### 对应代码

```csharp
    private void SetupCameraForURPDepthTexture() { // URP相机深度设置：保证Shader中_CameraDepthTexture可以被URP生成和绑定
        if (cam == null) { // 如果没有相机，无法请求深度纹理，直接返回避免空引用
            return;
        }

        UniversalAdditionalCameraData cameraData = cam.GetComponent<UniversalAdditionalCameraData>(); // URP相机会带有该组件，里面保存URP专用渲染设置
        if (cameraData != null) { // 只有项目使用URP并且相机有URP附加数据时才会进入
            cameraData.requiresDepthTexture = true; // 请求URP为该相机生成_CameraDepthTexture，供水面深度衰减/后续岸边效果使用
        }

        cam.depthTextureMode |= DepthTextureMode.Depth; // 同时设置Unity通用深度标记，增强兼容性，避免部分版本未生成深度纹理
    }

    void OnEnable() { // 生命周期：脚本启用时初始化网格、材质、FFT贴图和初始频谱
        CreateWaterPlane(); // 创建规则平面网格：作为FFT海面位移的基础几何
        CreateMaterial(); // 创建URP材质并绑定到MeshRenderer
        cam = Camera.main; // 优先使用带MainCamera标签的相机，避免通过名字查找导致场景相机改名后空引用
        if (cam == null) {
            cam = FindObjectOfType<Camera>(); // 兜底查找任意相机，保证简单测试场景也能运行
        }
        SetupCameraForURPDepthTexture(); // URP下请求深度纹理，替代Built-in里默认可用的部分相机深度行为

        if (fftComputeShader == null) { // FFT计算着色器是水面贴图生成核心，缺失时不能继续初始化GPU频谱资源
            Debug.LogError("FFTWater: fftComputeShader未赋值，请把FFTWater.compute拖入脚本。", this); // 提示用户补齐ComputeShader引用
            return; // 终止后续ComputeShader资源绑定，避免空引用
        }

        N = 1024;
        logN = (int)Mathf.Log(N, 2.0f);
        threadGroupsX = Mathf.CeilToInt(N / 8.0f);
        threadGroupsY = Mathf.CeilToInt(N / 8.0f);

        initialSpectrumTextures = CreateRenderTex(N, N, 4, RenderTextureFormat.ARGBHalf, true);

        // pingPongTex = CreateRenderTex(N, N, RenderTextureFormat.ARGBHalf, false);
        // pingPongTex2 = CreateRenderTex(N, N, RenderTextureFormat.ARGBHalf, false);
        buoyancyDataTex = CreateRenderTex(N, N, RenderTextureFormat.RHalf, false);

        displacementTextures = CreateRenderTex(N, N, 4, RenderTextureFormat.ARGBHalf, true);

        slopeTextures = CreateRenderTex(N, N, 4, RenderTextureFormat.RGHalf, true);

        spectrumTextures = CreateRenderTex(N, N, 8, RenderTextureFormat.ARGBHalf, true);

        spectrumBuffer = new ComputeBuffer(8, 8 * sizeof(float));

        SetFFTUniforms();
        SetSpectrumBuffers();
        // Compute initial JONSWAP spectrum
        fftComputeShader.SetTexture(0, "_InitialSpectrumTextures", initialSpectrumTextures);
        fftComputeShader.Dispatch(0, threadGroupsX, threadGroupsY, 1);
        fftComputeShader.SetTexture(1, "_InitialSpectrumTextures", initialSpectrumTextures);
        fftComputeShader.Dispatch(1, threadGroupsX, threadGroupsY, 1);
    }
```

### 代码作用说明

`N=1024` 必须与 ComputeShader 里的 `SIZE=1024` 一致。`initialSpectrumTextures` 有 4 层，`spectrumTextures` 有 8 层。初始化时先 Dispatch Kernel 0 生成初始谱，再 Dispatch Kernel 1 打包共轭谱。

## 27. 每帧更新：材质同步、频谱演化、逆 FFT 和贴图绑定

### 原理与公式

每帧主流程为：

$$
Inspector\ Parameters\rightarrow GPU\ Uniforms\rightarrow \tilde{h}(k,t)\rightarrow IFFT\rightarrow Displacement/Slope/Foam\rightarrow URP\ Material
$$

Kernel 顺序为：

| Kernel 索引 | Kernel 名称 | 作用 |
|---:|---|---|
| 0 | `CS_InitializeSpectrum` | 初始化 JONSWAP 初始谱 |
| 1 | `CS_PackSpectrumConjugate` | 打包共轭谱 |
| 2 | `CS_UpdateSpectrumForFFT` | 当前帧频谱演化 |
| 3 | `CS_HorizontalFFT` | 水平方向逆 FFT |
| 4 | `CS_VerticalFFT` | 垂直方向逆 FFT |
| 5 | `CS_AssembleMaps` | 生成位移/斜率/浮力贴图 |

### 对应代码

```csharp
    void Update() { // 每帧更新：同步Inspector参数、执行频谱时间演化、FFT逆变换、生成贴图并传给URP材质
        if (waterMaterial == null || fftComputeShader == null) { // 材质或ComputeShader缺失时不能继续，避免空引用报错刷屏
            return;
        }

        waterMaterial.SetVector("_Ambient", ambient);
        waterMaterial.SetVector("_DiffuseReflectance", diffuseReflectance);
        waterMaterial.SetVector("_SpecularReflectance", specularReflectance);
        waterMaterial.SetVector("_TipColor", tipColor);
        waterMaterial.SetVector("_FresnelColor", fresnelColor);
        waterMaterial.SetFloat("_Shininess", shininess * 100);
        waterMaterial.SetFloat("_FresnelBias", fresnelBias);
        waterMaterial.SetFloat("_FresnelStrength", fresnelStrength);
        waterMaterial.SetFloat("_FresnelShininess", fresnelShininess);
        waterMaterial.SetFloat("_NormalStrength", normalStrength);
        waterMaterial.SetFloat("_FresnelNormalStrength", fresnelNormalStrength);
        waterMaterial.SetFloat("_SpecularNormalStrength", specularNormalStrength);
        waterMaterial.SetInt("_UseEnvironmentMap", useTextureForFresnel ? 1 : 0);
        waterMaterial.SetFloat("_Tile0", tile1);
        waterMaterial.SetFloat("_Tile1", tile2);
        waterMaterial.SetFloat("_Tile2", tile3);
        waterMaterial.SetFloat("_Tile3", tile4);
        waterMaterial.SetFloat("_Roughness", roughness);
        waterMaterial.SetFloat("_FoamRoughnessModifier", foamRoughnessModifier);
        waterMaterial.SetVector("_SunIrradiance", sunIrradiance);
        waterMaterial.SetVector("_BubbleColor", bubble);
        waterMaterial.SetVector("_ScatterColor", scatter);
        waterMaterial.SetVector("_FoamColor", foam);
        waterMaterial.SetFloat("_BubbleDensity", bubbleDensity);
        waterMaterial.SetFloat("_HeightModifier", heightModifier);
        waterMaterial.SetFloat("_DisplacementDepthAttenuation", displacementDepthFalloff);
        waterMaterial.SetFloat("_NormalDepthAttenuation", normalDepthFalloff);
        waterMaterial.SetFloat("_FoamDepthAttenuation", foamDepthFalloff);
        waterMaterial.SetFloat("_WavePeakScatterStrength", wavePeakScatterStrength);
        waterMaterial.SetFloat("_ScatterStrength", scatterStrength);
        waterMaterial.SetFloat("_ScatterShadowStrength", scatterShadowStrength);
        waterMaterial.SetFloat("_EnvironmentLightStrength", environmentLightStrength);

        waterMaterial.SetInt("_DebugTile0", visualizeTile1 ? 1 : 0);
        waterMaterial.SetInt("_DebugTile1", visualizeTile2 ? 1 : 0);
        waterMaterial.SetInt("_DebugTile2", visualizeTile3 ? 1 : 0);
        waterMaterial.SetInt("_DebugTile3", visualizeTile4 ? 1 : 0);

        waterMaterial.SetInt("_DebugLayer0", visualizeLayer1 ? 1 : 0);
        waterMaterial.SetInt("_DebugLayer1", visualizeLayer2 ? 1 : 0);
        waterMaterial.SetInt("_DebugLayer2", visualizeLayer3 ? 1 : 0);
        waterMaterial.SetInt("_DebugLayer3", visualizeLayer4 ? 1 : 0);

        waterMaterial.SetInt("_ContributeDisplacement0", contributeDisplacement1 ? 1 : 0);
        waterMaterial.SetInt("_ContributeDisplacement1", contributeDisplacement2 ? 1 : 0);
        waterMaterial.SetInt("_ContributeDisplacement2", contributeDisplacement3 ? 1 : 0);
        waterMaterial.SetInt("_ContributeDisplacement3", contributeDisplacement4 ? 1 : 0);

        waterMaterial.SetFloat("_FoamSubtract0", foamSubtract1);
        waterMaterial.SetFloat("_FoamSubtract1", foamSubtract2);
        waterMaterial.SetFloat("_FoamSubtract2", foamSubtract3);
        waterMaterial.SetFloat("_FoamSubtract3", foamSubtract4);

        SetFFTUniforms();
        if (updateSpectrum) {
            SetSpectrumBuffers();
            fftComputeShader.SetTexture(0, "_InitialSpectrumTextures", initialSpectrumTextures);
            fftComputeShader.Dispatch(0, threadGroupsX, threadGroupsY, 1);
            fftComputeShader.SetTexture(1, "_InitialSpectrumTextures", initialSpectrumTextures);
            fftComputeShader.Dispatch(1, threadGroupsX, threadGroupsY, 1);
        }
        
        // Progress Spectrum For FFT：根据初始频谱h0(k)和时间相位e^(iwt)生成当前帧频谱，用于后续逆FFT
        fftComputeShader.SetTexture(2, "_InitialSpectrumTextures", initialSpectrumTextures);
        fftComputeShader.SetTexture(2, "_SpectrumTextures", spectrumTextures);
        fftComputeShader.Dispatch(2, threadGroupsX, threadGroupsY, 1);

        // Compute FFT For Height：对频谱做二维逆FFT，将频域数据转换为空间域水面高度/位移
        InverseFFT(spectrumTextures);

        // Assemble maps：把逆FFT结果整理成位移贴图、斜率贴图和浮力数据贴图，供渲染和物理浮力使用
        fftComputeShader.SetTexture(5, "_DisplacementTextures", displacementTextures);
        fftComputeShader.SetTexture(5, "_SpectrumTextures", spectrumTextures);
        fftComputeShader.SetTexture(5, "_SlopeTextures", slopeTextures);
        fftComputeShader.SetTexture(5, "_BuoyancyData", buoyancyDataTex);
        fftComputeShader.Dispatch(5, threadGroupsX, threadGroupsY, 1);

        
        displacementTextures.GenerateMips();
        slopeTextures.GenerateMips();


        waterMaterial.SetTexture("_DisplacementTextures", displacementTextures);
        waterMaterial.SetTexture("_SlopeTextures", slopeTextures);

        if (useTextureForFresnel) {
            waterMaterial.SetTexture("_EnvironmentMap", environmentTexture);
        }

        if (atmosphere != null) {
            waterMaterial.SetVector("_SunDirection", atmosphere.GetSunDirection());
            waterMaterial.SetVector("_SunColor", atmosphere.GetSunColor());
        }

        if (cam != null) { // 相机存在时才计算逆视图投影矩阵，避免测试场景无相机时报错
            Matrix4x4 projMatrix = GL.GetGPUProjectionMatrix(cam.projectionMatrix, false); // 将Unity投影矩阵转换为当前图形API使用的GPU投影矩阵
            Matrix4x4 viewProjMatrix = projMatrix * cam.worldToCameraMatrix; // 视图投影矩阵 = 投影矩阵 × 世界到相机矩阵
            waterMaterial.SetMatrix("_CameraInvViewProjection", viewProjMatrix.inverse); // 传入逆VP矩阵，Shader可用它把屏幕深度重建为世界坐标
        }
    }
```

### 代码作用说明

`Update` 先同步所有材质参数，再更新 ComputeShader Uniform。若 `updateSpectrum` 为 true，会重新初始化频谱，适合调试风速、fetch、方向等参数。随后执行频谱演化、二维逆 FFT、组装贴图、生成 mip，并把位移和斜率贴图绑定给 URP 材质。

## 28. 资源释放和 Gizmos 调试

### 原理与公式

RenderTexture 和 ComputeBuffer 是 GPU 资源，需要在禁用时释放，否则反复 Play/Stop 会造成显存泄漏或 Unity 警告。

### 对应代码

```csharp
    void OnDisable() {
        if (waterMaterial != null) {
            Destroy(waterMaterial);
            waterMaterial = null;
        }

        if (mesh != null) {
            Destroy(mesh);
            mesh = null;
            vertices = null;
            normals = null;
        }

        if (displacementTextures != null) Destroy(displacementTextures); // 释放位移纹理数组，避免GPU显存泄漏
        if (slopeTextures != null) Destroy(slopeTextures); // 释放斜率纹理数组
        if (initialSpectrumTextures != null) Destroy(initialSpectrumTextures); // 释放初始频谱纹理数组
        if (spectrumTextures != null) Destroy(spectrumTextures); // 释放当前频谱纹理数组
        if (buoyancyDataTex != null) Destroy(buoyancyDataTex); // 释放浮力数据纹理
        if (pingPongTex != null) Destroy(pingPongTex); // 释放预留PingPong纹理
        if (pingPongTex2 != null) Destroy(pingPongTex2); // 释放预留PingPong纹理2

        if (spectrumBuffer != null) { // ComputeBuffer属于GPU资源，必须手动释放
            spectrumBuffer.Release(); // Release比Dispose更常见，作用是释放底层GPU缓冲
            spectrumBuffer = null; // 置空避免重复释放
        }
    }

    private void OnDrawGizmos() {
        /*
        if (vertices == null) return;

        for (int i = 0; i < vertices.Length; ++i) {
            Gizmos.color = Color.black;
            Gizmos.DrawSphere(transform.TransformPoint(displacedVertices[i]), 0.1f);
            Gizmos.color = Color.yellow;
            Gizmos.DrawRay(transform.TransformPoint(displacedVertices[i]), displacedNormals[i]);
        }
        */
    }
}
```

### 代码作用说明

`OnDisable` 释放运行时材质、网格、RenderTexture 和 ComputeBuffer。`OnDrawGizmos` 当前保留为注释，可后续用于绘制位移顶点、法线或浮力采样点。

---

# 29. 从零复现实验步骤

## 29.1 Unity 项目要求

建议使用 Unity 2022 LTS 或兼容 URP 的版本。由于 Shader 使用 Hull、Domain 和 Geometry 阶段，建议优先在桌面平台 DX11/DX12 下测试。移动端或不支持 Shader Model 5.0 的平台，需要改写为非曲面细分版本。

## 29.2 文件放置

将三个文件放入工程目录，例如：

```text
Assets/FFTWaterURP/FFTWater.cs
Assets/FFTWaterURP/FFTWater.compute
Assets/FFTWaterURP/FFTWaterURP.shader
```

## 29.3 场景搭建

1. 新建空物体，命名为 `FFT Water`。
2. 添加 `FFTWater` 脚本。
3. 把 `FFTWater.compute` 拖入 `fftComputeShader`。
4. 把 `FFTWaterURP.shader` 或该 Shader 创建的材质对应到 `waterShader`。若不手动指定，脚本会尝试自动查找 `Custom/FFTWaterURP`。
5. 场景中需要有 Camera 和 Directional Light。
6. 如有大气散射脚本，可把 `Atmosphere` 引用拖入 `atmosphere`，同步太阳方向和太阳颜色。
7. 如要环境反射，给 `environmentTexture` 指定 Cubemap。

## 29.4 关键参数建议

| 参数 | 建议值 | 说明 |
|---|---:|---|
| `planeLength` | 10~50 | 水面基础网格覆盖范围 |
| `quadRes` | 5~20 | 基础网格密度 |
| `lengthScale1~4` | 64 / 128 / 256 / 512 | 四层波长尺度 |
| `tile1~4` | 1~16 | 四层采样平铺倍率 |
| `gravity` | 9.81 | 重力加速度 |
| `depth` | 20 | 有限水深，影响色散关系 |
| `repeatTime` | 100~300 | 频谱动画循环周期 |
| `lambda` | (1,1) | 水平位移强度 |
| `normalStrength` | 1~5 | 法线扰动强度 |
| `foamBias` | -0.5 附近 | 越低越容易生成泡沫 |
| `roughness` | 0.02~0.2 | 水面微表面粗糙度 |

---

# 30. 常见问题排查

## 30.1 水面不动

检查 `fftComputeShader` 是否赋值，Console 是否有 ComputeShader 编译错误，`N=1024` 是否与 ComputeShader 中 `SIZE=1024` 一致，以及当前平台是否支持 ComputeShader。

## 30.2 Shader 编译失败或没有细分

检查平台是否支持 Shader Model 5.0。Hull/Domain/Geometry Shader 在部分平台不可用。如果目标平台不支持，需要改成普通顶点位移版本。

## 30.3 水面黑色或反射异常

检查场景是否有 Directional Light，`_SunColor` / `_SunIrradiance` 是否为黑，`environmentTexture` 是否为空，以及材质是否使用 `Custom/FFTWaterURP`。

## 30.4 泡沫过多或没有泡沫

调节 `foamBias`、`foamThreshold`、`foamAdd`、`foamDecayRate`。其中 `foamBias` 控制雅可比阈值，`foamAdd` 控制新增泡沫量，`foamDecayRate` 控制泡沫消散速度。

---

# 31. 实现总结

该系统的复现关键不是单独理解某个文件，而是保持三者的数据契约一致：

1. `FFTWater.compute` 输出 `_DisplacementTextures` 和 `_SlopeTextures`；
2. `FFTWater.cs` 创建这些 RenderTexture，并按 Kernel 顺序 Dispatch；
3. `FFTWaterURP.shader` 使用完全相同的变量名采样这些贴图；
4. C# 中 `N=1024` 必须与 ComputeShader 中 `SIZE=1024`、`LOG_SIZE=10` 对齐；
5. URP Shader 的 Pass Tag 必须使用 `UniversalForward`，SubShader 必须声明 `UniversalPipeline`。

只要这些约束不被破坏，就可以通过本文从 ComputeShader 到 URP Shader 再到 C# 脚本的顺序完整复现 FFT 水面渲染。

---

# 32. 参考理论与文献方向

- Tessendorf, J. *Simulating Ocean Water*：FFT 海洋模拟经典课程笔记。
- JONSWAP spectrum：风浪能谱模型。
- TMA shallow water correction：有限水深谱修正。
- Donelan-Banner spreading：方向谱模型。
- Cooley-Tukey FFT：基 2 快速傅里叶变换。
- GPU Gems：基于物理模型的实时水面模拟。
- Unity URP ShaderLibrary：`Core.hlsl`、`Lighting.hlsl`、`GetMainLight`、`TEXTURE2D_ARRAY` 等接口。
