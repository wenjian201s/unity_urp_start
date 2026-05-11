# 从频谱到 URP：拆解 Unity FFT 水面实现

本文对应项目目录 `Assets/水面/FTTWater`。目录名写作 FTTWater，但代码中的类、Shader 和算法实际都是 FFT 水面：`FFTWater.cs` 负责 Unity 运行时资源与调度，`FFTWater.compute` 在 GPU 上生成频谱、执行逆 FFT 并输出贴图，`FFTWaterURP.shader` 在 URP 前向渲染中采样这些贴图完成位移、法线、泡沫和水面光照。

## 代码里的渲染流水线

这套水面的核心不是在 CPU 上更新网格顶点，而是在频域中描述海浪，再把频域结果变回空间域贴图。运行时每帧只需要把参数同步到 ComputeShader，调度几个 Kernel，然后把生成的 Texture2DArray 绑定给 URP Shader。

```mermaid
flowchart LR
    A["Inspector 参数<br/>风速、风向、fetch、泡沫、PBR"] --> B["FFTWater.cs"]
    B --> C["CS_UpdateSpectrumForFFT<br/>频谱时间推进"]
    C --> D["CS_HorizontalFFT<br/>行方向逆 FFT"]
    D --> E["CS_VerticalFFT<br/>列方向逆 FFT"]
    E --> F["CS_AssembleMaps<br/>位移、斜率、泡沫、浮力"]
    F --> G["FFTWaterURP.shader"]
    G --> H["曲面细分、顶点位移、法线恢复、水面着色"]
```

初始化阶段会先执行 `CS_InitializeSpectrum` 和 `CS_PackSpectrumConjugate`。前者根据 JONSWAP 能谱生成初始复数频谱，后者把 `h0(k)` 与 `h0*(-k)` 打包到同一个像素里，保证后续逆 FFT 得到的是实数高度场。每帧阶段则从这个初始谱出发，根据时间相位得到当前帧的频谱，再通过二维逆 FFT 输出空间域的位移与斜率。

## 海浪高度先写成傅里叶级数

FFT 海面的基本假设是：任意时刻的水面高度可以看成许多正弦波的叠加。空间坐标为 `x=(x,z)`，波数向量为 `k=(kx,kz)`，复数频谱为 `h~(k,t)`，水面高度可以写成：

$$
h(x,t)=\sum_k \tilde{h}(k,t)e^{i k\cdot x}
$$

GPU 中不会真的逐项求和。代码把所有 `k` 的频谱值存进一张 `1024 x 1024` 的纹理数组，再交给逆 FFT 一次性转回空间域。`FFTWater.compute` 中的 `N` 和 `SIZE` 都固定为 `1024`，这两个值必须一致，否则 C# 侧创建的 RenderTexture 尺寸和 ComputeShader 的线程组共享内存布局会不匹配。

水波频率和波数之间由色散关系连接。项目中的初始频谱使用有限水深形式：

$$
\omega(k)=\sqrt{g|k|\tanh(|k|d)}
$$

这里 `g` 是重力加速度，`d` 是水深。深水时 `tanh(|k|d)` 接近 1，公式退化为 `sqrt(g|k|)`；浅水时长波传播速度会被水深压低。这一层物理关系让 `depth` 参数不只是视觉缩放，而是进入了频谱能量计算。

```hlsl
float Dispersion(float kMag) {
    return sqrt(_Gravity * kMag * tanh(min(kMag * _Depth, 20)));
}

float DispersionDerivative(float kMag) {
    float th = tanh(min(kMag * _Depth, 20));
    float ch = cosh(kMag * _Depth);
    return _Gravity * (_Depth * kMag / ch / ch + th) / Dispersion(kMag) / 2.0f;
}
```

`DispersionDerivative` 用在初始频谱幅值里。代码的频谱函数先在角频率域中计算 JONSWAP 能量，再通过 `dω/dk` 把能量映射到波数网格。这个细节决定了不同长度尺度下能量不会因为采样坐标变化而完全失真。

## JONSWAP 谱把风速和 fetch 变成能量分布

`DisplaySpectrumSettings` 暴露给 Inspector 的参数接近美术可调语言：`windSpeed`、`windDirection`、`fetch`、`spreadBlend`、`swell`、`peakEnhancement` 和 `shortWavesFade`。运行时 `FillSpectrumStruct` 会把这些值转换成 ComputeShader 能直接使用的 `SpectrumSettings`。

```csharp
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
```

JONSWAP 能谱的常用形式是：

$$
S(\omega)=\alpha g^2\omega^{-5}
\exp\left[-1.25\left(\frac{\omega_p}{\omega}\right)^4\right]
\gamma^r
$$

其中：

$$
r=\exp\left[-\frac{(\omega-\omega_p)^2}{2\sigma^2\omega_p^2}\right]
$$

项目代码在这个基础上乘了 TMA 有限水深修正、方向谱和短波衰减。`sigma` 在峰值两侧取不同值，`omega <= peakOmega` 时为 `0.07`，高频侧为 `0.09`。`gamma` 对应 `peakEnhancement`，数值越高，峰频附近的能量越尖锐，视觉上会出现更集中的主浪方向。

```hlsl
float JONSWAP(float omega, SpectrumParameters spectrum) {
    float sigma = (omega <= spectrum.peakOmega) ? 0.07f : 0.09f;
    float r = exp(-(omega - spectrum.peakOmega) * (omega - spectrum.peakOmega)
        / 2.0f / sigma / sigma / spectrum.peakOmega / spectrum.peakOmega);

    float oneOverOmega = 1.0f / omega;
    float peakOmegaOverOmega = spectrum.peakOmega / omega;

    return spectrum.scale * TMACorrection(omega) * spectrum.alpha * _Gravity * _Gravity
        * oneOverOmega * oneOverOmega * oneOverOmega * oneOverOmega * oneOverOmega
        * exp(-1.25f * peakOmegaOverOmega * peakOmegaOverOmega
        * peakOmegaOverOmega * peakOmegaOverOmega)
        * pow(abs(spectrum.gamma), r);
}
```

方向谱决定同一频率下能量往哪个方向扩散。代码中保留了 `DonelanBanner` 函数，但当前真实运行路径的 `DirectionSpectrum` 没有调用它，而是在线性插值一个宽的 `cos²` 方向瓣和一个 `Cosine2s` 方向瓣。`spreadBlend` 越接近 1，方向越受 `windDirection` 控制；越接近 0，能量越接近宽瓣扩散。

```hlsl
float DirectionSpectrum(float theta, float omega, SpectrumParameters spectrum) {
    float s = SpreadPower(omega, spectrum.peakOmega)
        + 16 * tanh(min(omega / spectrum.peakOmega, 20))
        * spectrum.swell * spectrum.swell;

    return lerp(
        2.0f / 3.1415f * cos(theta) * cos(theta),
        Cosine2s(theta - spectrum.angle, s),
        spectrum.spreadBlend
    );
}
```

这让四个 layer 能混合出不同尺度的风浪。当前场景 `watter.unity` 中第一层 `lengthScale1=94`、`tile1=0.01`，并且 `visualizeLayer1=1`、`contributeDisplacement1=1`，它承担主要几何起伏。第四层 `lengthScale4=32`、`tile4=0.13`，`visualizeLayer4=1` 但 `contributeDisplacement4=0`，更像是保留给法线、泡沫或调试视觉的细节层。

## 初始频谱用高斯随机数给每个波数一个相位

同一组海况不应该每个波数都拥有固定相位，否则水面会出现机械重复的图案。代码使用整数 hash 生成均匀随机数，再用 Box-Muller 变换得到高斯随机数。每个频域像素根据 `id.x + N * id.y + N + seed` 得到稳定随机源，所以相同 `seed` 下水面可复现，不同 `seed` 下整体波形会改变。

初始频谱写成：

$$
\tilde{h}_0(k)=\xi\sqrt{2S(k)D(k)\left|\frac{d\omega}{dk}\right|\frac{\Delta k^2}{|k|}}
$$

`ξ` 是复高斯随机数，`S(k)` 来自 JONSWAP 与 TMA，`D(k)` 来自方向谱，`Δk=2π/L` 是当前 layer 的波数间距。公式中的 `1/|k|` 用来处理从频率方向域转换到二维波数域时的雅可比因子。

```hlsl
float deltaK = 2.0f * PI / lengthScales[i];
float2 K = (id.xy - halfN) * deltaK;
float kLength = length(K);

float omega = Dispersion(kLength);
float dOmegadk = DispersionDerivative(kLength);

float spectrum = JONSWAP(omega, _Spectrums[i * 2])
    * DirectionSpectrum(kAngle, omega, _Spectrums[i * 2])
    * ShortWavesFade(kLength, _Spectrums[i * 2]);

if (_Spectrums[i * 2 + 1].scale > 0)
    spectrum += JONSWAP(omega, _Spectrums[i * 2 + 1])
        * DirectionSpectrum(kAngle, omega, _Spectrums[i * 2 + 1])
        * ShortWavesFade(kLength, _Spectrums[i * 2 + 1]);

_InitialSpectrumTextures[uint3(id.xy, i)] =
    float4(float2(gauss2.x, gauss1.y)
    * sqrt(2 * spectrum * abs(dOmegadk) / kLength * deltaK * deltaK), 0.0f, 0.0f);
```

`lowCutoff` 和 `highCutoff` 在这里过滤波数范围。低波数过多会导致整片海面像大块平面在漂移，高波数过多会让法线闪烁和泡沫噪声变重。项目默认值 `0.0001` 到 `9000` 很宽，实际调海况时通常先调 `scale`、`fetch`、`windSpeed` 和 `shortWavesFade`，再根据画面稳定性收紧 cutoff。

## 频谱时间推进让海浪动起来

初始化只决定“这片海”的统计形态，每帧动画来自复数相位旋转：

$$
\tilde{h}(k,t)=\tilde{h}_0(k)e^{i\omega t}+\tilde{h}_0^*(-k)e^{-i\omega t}
$$

代码在 `CS_PackSpectrumConjugate` 中提前存好 `h0(k)` 和 `h0*(-k)`，所以更新时间时可以直接读取一个 `float4`。`EulerFormula` 返回 `(cos(x), sin(x))`，`ComplexMult` 执行复数乘法。

```hlsl
float4 initialSignal = _InitialSpectrumTextures[uint3(id.xy, i)];
float2 h0 = initialSignal.xy;
float2 h0conj = initialSignal.zw;

float w_0 = 2.0f * PI / _RepeatTime;
float dispersion = floor(sqrt(_Gravity * kMag) / w_0) * w_0 * _FrameTime;
float2 exponent = EulerFormula(dispersion);

float2 htilde = ComplexMult(h0, exponent)
    + ComplexMult(h0conj, float2(exponent.x, -exponent.y));
```

这里有一个值得在博客中讲清楚的实现取舍。初始谱使用了有限水深色散 `Dispersion(k)`，但时间推进为了 `repeatTime` 可循环，使用了 `sqrt(g*k)` 并量化到 `2π/repeatTime` 的整数倍。这样动画可以在设定周期内循环，但水深对相位速度的影响没有进入每帧推进；如果要更严格的浅水传播，可以把这一行替换为基于 `Dispersion(kMag)` 的量化版本。

项目还在频域中提前算出水平位移和斜率。垂直高度是 `h~`，水平位移近似来自 `i k / |k| * h~`：

$$
D_x(k,t)=i\frac{k_x}{|k|}\tilde{h}(k,t),\quad
D_z(k,t)=i\frac{k_z}{|k|}\tilde{h}(k,t)
$$

斜率用于恢复法线：

$$
s_x=\frac{\partial h}{\partial x},\quad
s_z=\frac{\partial h}{\partial z},\quad
n=normalize(-s_x,1,-s_z)
$$

```hlsl
float2 ih = float2(-htilde.y, htilde.x);

float2 displacementX = ih * K.x * kMagRcp;
float2 displacementY = htilde;
float2 displacementZ = ih * K.y * kMagRcp;

float2 displacementY_dx = ih * K.x;
float2 displacementY_dz = ih * K.y;
```

这一步把位移和斜率都写入 `_SpectrumTextures`。四个水面尺度每个占两个 array slice，偶数 slice 存位移相关频谱，奇数 slice 存斜率和导数相关频谱。

## 二维逆 FFT 在共享内存中做两次一维变换

二维逆 FFT 可以拆成行方向和列方向两次一维逆 FFT：

$$
IFFT_{2D}(H)=IFFT_y(IFFT_x(H))
$$

`FFTWater.cs` 里的调度非常直接。`CS_HorizontalFFT` 的线程组尺寸是 `1024 x 1 x 1`，每个组处理一整行；C# 侧 dispatch 为 `(1, N, 1)`，表示一共处理 `N` 行。垂直方向同理，只是 ComputeShader 中用 `id.yx` 转置访问。

```csharp
void InverseFFT(RenderTexture spectrumTextures) {
    fftComputeShader.SetTexture(3, "_FourierTarget", spectrumTextures);
    fftComputeShader.Dispatch(3, 1, N, 1);

    fftComputeShader.SetTexture(4, "_FourierTarget", spectrumTextures);
    fftComputeShader.Dispatch(4, 1, N, 1);
}
```

基 2 FFT 的蝶形运算可以写成：

$$
X'_i=X_a+W_N^rX_b
$$

其中 `W_N^r=e^{-2πir/N}` 是旋转因子。项目通过翻转虚部方向实现逆 FFT，并把一行或一列的数据放进 `groupshared` 数组中，减少重复显存读写。

```hlsl
groupshared float4 fftGroupBuffer[2][SIZE];

void ButterflyValues(uint step, uint index, out uint2 indices, out float2 twiddle) {
    const float twoPi = 6.28318530718;
    uint b = SIZE >> (step + 1);
    uint w = b * (index / b);
    uint i = (w + index) % SIZE;

    sincos(-twoPi / SIZE * w, twiddle.y, twiddle.x);
    twiddle.y = -twiddle.y;
    indices = uint2(i, i + b);
}

float4 FFT(uint threadIndex, float4 input) {
    fftGroupBuffer[0][threadIndex] = input;
    GroupMemoryBarrierWithGroupSync();
    bool flag = false;

    [unroll]
    for (uint step = 0; step < LOG_SIZE; ++step) {
        uint2 inputsIndices;
        float2 twiddle;
        ButterflyValues(step, threadIndex, inputsIndices, twiddle);

        float4 v = fftGroupBuffer[flag][inputsIndices.y];
        fftGroupBuffer[!flag][threadIndex] =
            fftGroupBuffer[flag][inputsIndices.x]
            + float4(ComplexMult(twiddle, v.xy), ComplexMult(twiddle, v.zw));

        flag = !flag;
        GroupMemoryBarrierWithGroupSync();
    }

    return fftGroupBuffer[flag][threadIndex];
}
```

这段实现没有显式除以 `N` 或 `N²` 做归一化，因此 `spectrum.scale`、`lambda` 和材质侧的高度/法线强度也承担了一部分视觉归一化职责。只要这套参数一起调，它仍然能稳定工作；如果后续要和别的物理模块共享真实单位的波高，最好补上明确的 FFT 归一化约定。

## 组装贴图时同时生成泡沫和浮力数据

逆 FFT 之后，`_SpectrumTextures` 中已经是空间域数据，但还不能直接给 Shader 用。`CS_AssembleMaps` 会执行三件事：先用 `Permute` 修正频谱中心导致的奇偶相位，再把复数结果的实部整理成 `displacement` 和 `slopes`，最后根据雅可比行列式累积泡沫。

```hlsl
float4 Permute(float4 data, float3 id) {
    return data * (1.0f - 2.0f * ((id.x + id.y) % 2));
}
```

水平位移会把海面从单纯高度场变成更有横向翻卷感的形状。`lambda` 控制这个横向位移强度：

$$
D=(\lambda_xD_x,D_y,\lambda_yD_z)
$$

泡沫来自曲面变形的雅可比行列式。代码使用的形式是：

$$
J=(1+\lambda_x d_{xx})(1+\lambda_y d_{zz})-\lambda_x\lambda_y d_{xz}^2
$$

当局部压缩或翻卷让 `J` 落到阈值以下时，泡沫增加；每帧再乘指数衰减，让泡沫自然消失：

$$
foam_t=foam_{t-1}e^{-decay}+add\cdot\max(0,-(J-bias))
$$

```hlsl
float jacobian = (1.0f + _Lambda.x * dxxdzz.x)
    * (1.0f + _Lambda.y * dxxdzz.y)
    - _Lambda.x * _Lambda.y * dydxz.y * dydxz.y;

float3 displacement = float3(_Lambda.x * dxdz.x, dydxz.x, _Lambda.y * dxdz.y);
float2 slopes = dyxdyz.xy / (1 + abs(dxxdzz * _Lambda));

float foam = _DisplacementTextures[uint3(id.xy, i)].a;
foam *= exp(-_FoamDecayRate);
foam = saturate(foam);

float biasedJacobian = max(0.0f, -(jacobian - _FoamBias));
if (biasedJacobian > _FoamThreshold)
    foam += _FoamAdd * biasedJacobian;

_DisplacementTextures[uint3(id.xy, i)] = float4(displacement, foam);
_SlopeTextures[uint3(id.xy, i)] = float2(slopes);

if (i == 0) {
    _BuoyancyData[id.xy] = displacement.y;
}
```

`_DisplacementTextures` 是四层 Texture2DArray，`rgb` 保存顶点位移，`a` 保存泡沫。`_SlopeTextures` 也是四层 Texture2DArray，`rg` 保存斜率。第一层高度额外写入 `_BuoyancyData`，后续可以给漂浮物采样使用。

## URP Shader 只消费贴图，不重新计算海浪频谱

`FFTWaterURP.shader` 的顶点阶段从世界坐标 `xz` 采样四层位移贴图，叠加后把顶点推到水面形状上。这里使用世界坐标而不是模型 UV，所以水面对象移动或网格细分后仍然能保持连续波纹。

```hlsl
g.worldPos = TransformObjectToWorld(v.vertex.xyz);

float3 displacement1 =
    SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures,
    g.worldPos.xz * _Tile0, 0, 0).xyz * _DebugLayer0 * _ContributeDisplacement0;

float3 displacement2 =
    SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures,
    g.worldPos.xz * _Tile1, 1, 0).xyz * _DebugLayer1 * _ContributeDisplacement1;

float3 displacement3 =
    SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures,
    g.worldPos.xz * _Tile2, 2, 0).xyz * _DebugLayer2 * _ContributeDisplacement2;

float3 displacement4 =
    SAMPLE_TEXTURE2D_ARRAY_LOD(_DisplacementTextures, sampler_DisplacementTextures,
    g.worldPos.xz * _Tile3, 3, 0).xyz * _DebugLayer3 * _ContributeDisplacement3;

float3 displacement = displacement1 + displacement2 + displacement3 + displacement4;
displacement = lerp(0.0f, displacement, pow(saturate(depth), _DisplacementDepthAttenuation));
v.vertex.xyz += TransformWorldToObjectDir(displacement.xyz, false);
```

`_DebugLayer` 在这份代码中不只是调试显示，也参与 layer 是否采样。`_ContributeDisplacement` 只控制顶点位移贡献；片元阶段的泡沫和斜率采样仍然由 `_DebugLayer` 控制。这意味着可以让某层不改变几何，只贡献细节法线或泡沫视觉，也可以只打开某层观察图案。

Shader 还使用 Hull/Domain 阶段做曲面细分。细分因子基于边长、屏幕高度和视距：

$$
tess=\frac{edgeLength\cdot screenHeight}{edgeTarget\cdot (viewDistance\cdot0.5)^{1.2}}
$$

```hlsl
float TessellationHeuristic(float3 cp0, float3 cp1) {
    float edgeLength = distance(cp0, cp1);
    float3 edgeCenter = (cp0 + cp1) * 0.5;
    float viewDistance = distance(edgeCenter, _WorldSpaceCameraPos);
    return edgeLength * _ScreenParams.y
        / (_TessellationEdgeLength * (pow(viewDistance * 0.5f, 1.2f)));
}
```

这让近处水面有更多顶点承载 FFT 位移，远处减少细分开销。由于 Shader 使用 Hull、Domain 和 Geometry 阶段，目标平台需要支持 Shader Model 5.0；如果要上移动端，需要把细分阶段改成普通网格或 GPU instancing 的方案。

## 片元阶段用同一份斜率贴图恢复法线

片元着色再次采样四层位移贴图和斜率贴图。位移贴图的 `a` 通道累加为泡沫，斜率贴图恢复中尺度法线：

```hlsl
float2 slopes1 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures,
    f.data.uv * _Tile0, 0).xy * _DebugLayer0;
float2 slopes2 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures,
    f.data.uv * _Tile1, 1).xy * _DebugLayer1;
float2 slopes3 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures,
    f.data.uv * _Tile2, 2).xy * _DebugLayer2;
float2 slopes4 = SAMPLE_TEXTURE2D_ARRAY(_SlopeTextures, sampler_SlopeTextures,
    f.data.uv * _Tile3, 3).xy * _DebugLayer3;

float2 slopes = slopes1 + slopes2 + slopes3 + slopes4;
slopes *= _NormalStrength;

float3 mesoNormal = normalize(float3(-slopes.x, 1.0f, -slopes.y));
mesoNormal = normalize(lerp(float3(0, 1, 0), mesoNormal,
    pow(saturate(depth), _NormalDepthAttenuation)));
mesoNormal = normalize(TransformObjectToWorldNormal(normalize(mesoNormal)));
```

深度衰减会让远处法线逐渐回到平面法线，减少远景闪烁。顶点位移和片元法线来自同一套 FFT 输出，因此波峰位置、泡沫位置和高光方向能保持一致。

## 水面光照由菲涅尔、微表面高光和散射混合

水的反射随视角变化很明显，所以 Shader 使用了菲涅尔项。垂直入射时的基础反射率由折射率估算：

$$
R_0=\left(\frac{\eta-1}{\eta+1}\right)^2
$$

代码取 `eta=1.33`，接近水相对空气的折射率。随后用一个带粗糙度修正的 Schlick 风格公式得到 `F`：

```hlsl
float eta = 1.33f;
float R = ((eta - 1) * (eta - 1)) / ((eta + 1) * (eta + 1));

float numerator = pow(1 - dot(mesoNormal, viewDir), 5 * exp(-2.69 * a));
float F = R + (1 - R) * numerator / (1.0f + 22.7f * pow(a, 1.5f));
F = saturate(F);
```

高光使用 Beckmann 法线分布和 Smith 风格的几何遮蔽。Beckmann 分布在代码中写作：

$$
D(n,h)=\frac{\exp((n\cdot h)^2-1)/(\alpha^2(n\cdot h)^2)}
{\pi\alpha^2(n\cdot h)^4}
$$

对应实现是：

```hlsl
float Beckmann(float ndoth, float roughness) {
    float exp_arg = (ndoth * ndoth - 1)
        / (roughness * roughness * ndoth * ndoth);

    return exp(exp_arg)
        / (PI * roughness * roughness * ndoth * ndoth * ndoth * ndoth);
}
```

最终颜色把散射、太阳镜面和环境反射合在一起，再按泡沫强度混合到泡沫色：

```hlsl
float3 specular = sunIrradiance * F * G * Beckmann(ndoth, a);
specular /= 4.0f * max(0.001f, DotClamped(macroNormal, lightDir));
specular *= DotClamped(mesoNormal, lightDir);

float3 envReflection =
    SAMPLE_TEXTURECUBE(_EnvironmentMap, sampler_EnvironmentMap,
    reflect(-viewDir, mesoNormal)).rgb;
envReflection *= _EnvironmentLightStrength;

float3 output = (1 - F) * scatter + specular + F * envReflection;
output = max(0.0f, output);
output = lerp(output, _FoamColor, saturate(foam));
```

`FFTWater.cs` 每帧会优先从 `Atmosphere` 脚本传入 `_SunDirection` 和 `_SunColor`。如果大气脚本不存在，Shader 侧会回退到 URP 的 `GetMainLight()`。这使水面可以跟天空散射系统共享太阳方向和色彩，不会出现天空已经日落、水面高光仍然像正午的割裂感。

## C# 侧的资源绑定决定整套系统是否能跑起来

ComputeShader 输出的是 GPU 纹理，C# 侧必须创建支持随机写入的 RenderTexture。四层位移贴图、四层斜率贴图、四层初始谱和八层当前谱都使用 Texture2DArray；浮力数据使用普通 2D RenderTexture。

```csharp
RenderTexture CreateRenderTex(int width, int height, int depth,
    RenderTextureFormat format, bool useMips) {
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
```

初始化顺序是创建网格、创建材质、请求 URP 相机深度纹理、创建 RenderTexture、创建 `ComputeBuffer`、上传频谱参数、生成初始谱、打包共轭谱。每帧顺序则是同步材质参数、同步 ComputeShader 参数、可选重建频谱、更新时间频谱、逆 FFT、组装贴图、生成 mip、绑定给材质。

```csharp
fftComputeShader.SetTexture(2, "_InitialSpectrumTextures", initialSpectrumTextures);
fftComputeShader.SetTexture(2, "_SpectrumTextures", spectrumTextures);
fftComputeShader.Dispatch(2, threadGroupsX, threadGroupsY, 1);

InverseFFT(spectrumTextures);

fftComputeShader.SetTexture(5, "_DisplacementTextures", displacementTextures);
fftComputeShader.SetTexture(5, "_SpectrumTextures", spectrumTextures);
fftComputeShader.SetTexture(5, "_SlopeTextures", slopeTextures);
fftComputeShader.SetTexture(5, "_BuoyancyData", buoyancyDataTex);
fftComputeShader.Dispatch(5, threadGroupsX, threadGroupsY, 1);

displacementTextures.GenerateMips();
slopeTextures.GenerateMips();

waterMaterial.SetTexture("_DisplacementTextures", displacementTextures);
waterMaterial.SetTexture("_SlopeTextures", slopeTextures);
```

URP 深度纹理由 `SetupCameraForURPDepthTexture` 请求。当前 Shader 主要用顶点自身深度做远处衰减，但保留 `_CameraDepthTexture` 和 `_CameraInvViewProjection` 可以继续扩展岸边水深、软交界或屏幕空间折射。

```csharp
UniversalAdditionalCameraData cameraData = cam.GetComponent<UniversalAdditionalCameraData>();
if (cameraData != null) {
    cameraData.requiresDepthTexture = true;
}

cam.depthTextureMode |= DepthTextureMode.Depth;
```

## 调参时先分清尺度、平铺和能量

`lengthScale` 决定频谱的物理尺度，进入 `deltaK=2π/L`。数值越大，可表达的长波越明显；数值越小，波形更偏中短波。`tile` 是 Shader 采样时对世界坐标的缩放，它决定同一张贴图在世界中重复的密度。`scale` 是谱能量缩放，它直接影响初始谱幅值。

`windSpeed` 和 `fetch` 一起影响 `alpha` 与 `peakOmega`。风速增大通常会推高能量并改变峰频；fetch 越大，海浪有更长距离成长，主浪更容易形成。`shortWavesFade` 用来压制高频，画面出现闪烁或噪声时先提高它，比盲目降低整体 `scale` 更可控。

`lambda` 控制横向位移。它太小，水面只像高度贴图在上下起伏；它太大，局部翻卷会夸张，泡沫也会因为雅可比阈值更容易被触发。当前场景使用 `(1,1)`，适合先观察完整形态，再按镜头距离调整。

泡沫的主要入口是 `foamBias`、`foamThreshold`、`foamAdd` 和 `foamDecayRate`。`foamBias` 越接近压缩区域的雅可比值，越容易出泡沫；`foamAdd` 决定新增速度；`foamDecayRate` 决定残留时间。当前场景中 `foamBias=0.85`、`foamAdd=0.1`、`foamDecayRate=0.0175`，泡沫会比较温和地累积，而不是瞬间铺满整个波面。

## 这个实现最值得保留的约束

`FFTWater.compute`、`FFTWater.cs` 和 `FFTWaterURP.shader` 之间依赖同一组纹理名、slice 约定和尺寸约定。`_DisplacementTextures` 的四层必须被 C# 创建、ComputeShader 写入、Shader 采样；`_SlopeTextures` 也是同样的绑定关系。`N=1024` 必须和 `SIZE=1024` 同步，`spectrumTextures` 的八层必须保持“四个尺度乘以位移/斜率两类频谱”的布局。

这套水面真正的扩展点不在于把公式继续堆复杂，而在于明确每张贴图的语义。想加漂浮物，就从 `_BuoyancyData` 或第一层位移高度采样；想加岸边交互，就使用已经传入 Shader 的深度纹理和逆 VP 矩阵；想改海况循环，就从时间推进里的量化色散关系开始。

## 参考资料

Jerry Tessendorf 的 [Simulating Ocean Water](https://jtessen.people.clemson.edu/reports/papers_files/coursenotes2004.pdf) 是这类 FFT 海面实现的经典课程笔记，本文中的频域高度场、共轭频谱、水平位移和雅可比泡沫思路都与它直接相关。

JONSWAP 谱来自 Hasselmann 等人的 Joint North Sea Wave Project 观测报告，可参考 Max Planck Society 归档的 [Measurements of Wind-Wave Growth and Swell Decay during the Joint North Sea Wave Project](https://pure.mpg.de/pubman/faces/ViewItemFullPage.jsp?itemId=item_3262854_2)。项目中 `alpha` 和 `peakOmega` 的 fetch-limited 写法对应这类经验风浪谱。

有限水深修正可参考 Bouws、Günther、Rosenthal 和 Vincent 的 [Similarity of the Wind Wave Spectrum in Finite Depth Water](https://pure.mpg.de/pubman/item/item_2514801_2/component/file_3514893/Journal%2Bof%2BGeophysical%2BResearch%2BOceans%2B-%2B20%2BJanuary%2B1985%2B-%2BBouws%2B-%2BSimilarity%2Bof%2Bthe%2Bwind%2Bwave%2Bspectrum%2Bin%2Bfinite%2Bdepth.pdf)，代码里的 `TMACorrection` 就是在 JONSWAP 能谱外乘一个浅水修正因子。

方向谱背景可参考 Donelan、Hamilton 和 Hui 的 [Directional Spectra of Wind-Generated Waves](https://publications.gc.ca/pub?id=9.904937&sl=1)。当前代码保留了 Donelan-Banner 方向函数，但运行路径主要使用 `Cosine2s` 与宽瓣混合。

FFT 算法背景可参考 Cooley 和 Tukey 的 [An Algorithm for the Machine Calculation of Complex Fourier Series](https://research.ibm.com/publications/an-algorithm-for-the-machine-calculation-of-complex-fourier-series)。Unity 侧 ComputeShader 与 RenderTexture 随机写入可参考 Unity 官方文档中的 [Compute shaders](https://docs.unity.cn/Manual/class-ComputeShader-create.html)、[RenderTexture.enableRandomWrite](https://docs.unity.cn/2022.3/Documentation/ScriptReference/RenderTexture-enableRandomWrite.html) 和 URP 的 [custom lighting shader methods](https://docs.unity.cn/6000.0/Documentation/Manual/urp/use-built-in-shader-methods-lighting.html)。
