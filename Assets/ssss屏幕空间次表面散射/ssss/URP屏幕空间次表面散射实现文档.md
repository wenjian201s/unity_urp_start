# URP 屏幕空间次表面散射从零到尾实现

这份文档对应目录 `Assets/ssss屏幕空间次表面散射/ssss` 中的实现。当前版本把原本依赖 Built-in Render Pipeline 的相机 `CommandBuffer` 后处理，迁移为 URP 的 `ScriptableRendererFeature` 和 `ScriptableRenderPass`，并参考两篇下载的知乎文章保留可分离卷积核、模板遮罩、半分辨率性能路径和深度边缘保护。

## 文件结构和渲染入口

本目录的运行链路由四类文件组成。`StencilSurface.shader` 是皮肤材质 shader，它在正常 URP 前向光照时把皮肤像素写入模板缓冲。`SubsurfaceScatterPostProcess.cs` 是 URP Renderer Feature，它负责把相机颜色复制出来，创建临时 RT，执行横向和纵向两次模糊，并在最后根据模板值把模糊结果合成回相机颜色。`SeparableSubsurfaceScatter.shader` 和 `SeparableSubsurfaceScatterCommon.cginc` 是后处理 shader，本体只声明三个 pass，真正采样、深度保护和卷积逻辑放在 include 文件里。`KernelCalculator.cs` 计算 25 点可分离 SSS 卷积核，`ShaderIDs.cs` 保存 shader 属性 ID，避免每帧重复字符串查找。

URP 中不能继续使用 Built-in 的 `CameraEvent.AfterForwardOpaque` 和 `Camera.AddCommandBuffer`。新的入口是把 `SubsurfaceScatterPostProcess` 添加到当前 URP Renderer asset 的 Renderer Features 列表中。由于本次操作范围被限制在 `ssss` 文件夹内，代码已经完成迁移，但 Renderer asset 需要在 Unity Inspector 中手动添加这个 Feature；添加后，`RenderPassEvent` 默认在 `AfterRenderingOpaques` 执行，行为对应旧工程的 `AfterForwardOpaque`。

## 模板标记阶段

屏幕空间 SSSS 不应该对整张画面模糊，否则背景、衣服、头发都会产生皮肤散射。实现中使用模板缓冲标记皮肤区域，和第一篇文章中的“先写 stencil，再通过 stencil 限定后处理范围”的思路一致。

皮肤材质使用 `Custom/StencilSurface`。它不再包含 Built-in 的 `UnityStandardCoreForward.cginc`，而是声明 URP 的 `UniversalForward` pass。这个 pass 仍然做 PBR 光照，同时通过 `Stencil` 块写入参考值。

```hlsl
Stencil
{
    Ref [_StencilRef]
    Comp Always
    Pass Replace
}
```

`_StencilRef` 默认是 5，和后处理 Feature 的 `stencilReference` 默认值一致。皮肤物体完成前向渲染后，屏幕上属于皮肤的像素在模板缓冲里留下 5。最终合成 pass 只在 `Comp Equal` 成立的位置写入模糊后的颜色，其余像素保持相机原图。

`StencilSurface.shader` 的前向光照部分使用 URP 的 `Core.hlsl` 和 `Lighting.hlsl`。顶点阶段通过 `GetVertexPositionInputs` 和 `GetVertexNormalInputs` 得到世界空间位置、法线、切线和裁剪空间坐标。片元阶段采样 `_MainTex`、可选法线贴图和 AO 贴图，然后构造 `InputData`、`SurfaceData` 和 `BRDFData`。当前版本不再直接调用完整 `UniversalFragmentPBR`，而是把漫反射和高光拆开：`UniversalForward` 只输出 DiffuseOnly，`SSSSSpecularOnly` 在 SSS 后延迟叠加高光。

```hlsl
InputData inputData = (InputData)0;
inputData.positionWS = input.positionWS;
inputData.normalWS = normalWS;
inputData.viewDirectionWS = GetWorldSpaceNormalizeViewDir(input.positionWS);
inputData.shadowCoord = input.shadowCoord;
inputData.fogCoord = input.fogFactor;
inputData.vertexLighting = VertexLighting(input.positionWS, normalWS);
inputData.bakedGI = SampleSH(normalWS);
inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(input.positionCS);
inputData.shadowMask = half4(1.0h, 1.0h, 1.0h, 1.0h);

half3 color = ComputeDiffuseOnlyLighting(inputData, surfaceData, brdfData);
color += ComputeSkinTranslucency(inputData, skin.normalWS, inputData.viewDirectionWS, skin.albedo, input.uv, skin.occlusion);
```

这个 shader 还提供了 `DepthOnly` 和 `ShadowCaster` pass。`DepthOnly` 让 URP 需要深度预通道时能写入深度，`ShadowCaster` 让皮肤物体可以参与阴影图渲染。它们只输出深度，不写颜色，也不写模板，因为模板标记只需要在相机可见颜色 pass 中完成。

## 卷积核生成

`KernelCalculate.CalculateKernel` 负责在 C# 侧生成 `_Kernel` 数组。每个元素是一个 `Vector4`，其中 `xyz` 是 RGB 三个通道的散射权重，`w` 是沿模糊轴采样时使用的偏移量。这样的设计来自 Jimenez 的 Separable SSS 方法，也对应文章中“C# 计算 kernel，shader 只负责按 kernel 采样”的做法。

偏移量先在线性区间里生成，再使用平方分布重排。代码中的 `EXPONENT = 2.0f` 会让更多样本靠近中心，较少样本放到远端，这和第二篇文章提到的移动端优化思路一致。当前范围由 Renderer Feature 的 `kernelRange` 控制，默认是 `[-2, 2]`；如果想要更宽的 Jimenez 原始散射范围，可以把它调到 3。

```csharp
float RANGE = Mathf.Clamp(range, 1.0f, 3.0f);
float EXPONENT = 2.0f;
float step = 2.0f * RANGE / (nSamples - 1);

for (int i = 0; i < nSamples; i++) {
    float o = -RANGE + i * step;
    float sign = o < 0.0f ? -1.0f : 1.0f;
    float w = RANGE * sign * Mathf.Abs(Mathf.Pow(o, EXPONENT)) / Mathf.Pow(RANGE, EXPONENT);
    kernel.Add(new Vector4(0, 0, 0, w));
}
```

权重由五组高斯函数叠加得到。不同方差对应不同散射距离，`falloff` 会按 RGB 通道缩放半径。皮肤通常红色通道散射更远，绿色次之，蓝色更集中，所以默认 `falloff = (1.0, 0.37, 0.3)`。权重计算完成后会按 RGB 分别归一化，保证卷积不凭空增加或损失能量。

`strength` 控制有多少能量参与散射。中心样本使用 `(1 - strength) + strength * centerWeight`，非中心样本直接乘以 `strength`。这意味着 `strength` 越低，原始颜色保留越多；`strength` 越高，颜色越多地向邻域扩散。这个参数对应文章里“Strength 控制散射参与度，剩余部分不散射”的解释。

## URP Renderer Feature

`SubsurfaceScatterPostProcess.cs` 的外层类继承 `ScriptableRendererFeature`。它持有可在 Inspector 中调节的 `Settings`，在 `Create` 中找到 `PostProcess/SeparableSubsurfaceScatter` shader 并创建运行时材质，在 `SetupRenderPasses` 中接收 URP 分配好的相机颜色和深度 RTHandle，在 `AddRenderPasses` 中把自定义 pass 加入渲染队列。

```csharp
public override void SetupRenderPasses(ScriptableRenderer renderer, in RenderingData renderingData)
{
    if (_pass == null)
        return;

    _pass.renderPassEvent = settings.renderPassEvent;
    _pass.Setup(renderer.cameraColorTargetHandle, renderer.cameraDepthTargetHandle);
}
```

旧版 Built-in 实现把命令缓冲挂到 `CameraEvent.AfterForwardOpaque`。URP 中相机颜色目标不能在 `AddRenderPasses` 里直接访问，否则会遇到 URP 14 的生命周期限制，所以这里使用 `SetupRenderPasses`。这是迁移时最容易踩的点之一。

`SubsurfaceScatterPass` 继承 `ScriptableRenderPass`，构造函数调用 `ConfigureInput(ScriptableRenderPassInput.Depth)`。后处理 shader 需要 `_CameraDepthTexture` 来做深度边缘保护，这个声明告诉 URP 为当前 pass 准备可采样的深度纹理。

```csharp
public SubsurfaceScatterPass(Settings settings, Material material)
{
    _settings = settings;
    _material = material;
    ConfigureInput(ScriptableRenderPassInput.Depth);
}
```

临时 RT 使用 `RTHandle` 和 `RenderingUtils.ReAllocateIfNeeded`。相机颜色复制 RT 保持全分辨率，模糊 RT 根据 `downsample` 降低分辨率。默认 `downsample = 1`，也就是半分辨率模糊；这是第二篇文章里强调的性能方向。半分辨率会减少两次卷积的采样成本，最终合成时再双线性采样回全分辨率。

```csharp
RenderTextureDescriptor descriptor = renderingData.cameraData.cameraTargetDescriptor;
descriptor.depthBufferBits = 0;
descriptor.msaaSamples = 1;
descriptor.useMipMap = false;
descriptor.autoGenerateMips = false;

RenderTextureDescriptor fullDescriptor = descriptor;
RenderingUtils.ReAllocateIfNeeded(
    ref _sourceCopy,
    in fullDescriptor,
    FilterMode.Bilinear,
    TextureWrapMode.Clamp,
    name: "_SSSS_SourceCopy"
);

int downsample = Mathf.Clamp(_settings.downsample, 0, 2);
descriptor.width = Mathf.Max(1, descriptor.width >> downsample);
descriptor.height = Mathf.Max(1, descriptor.height >> downsample);
```

执行阶段分成三次全屏绘制。第一次把相机颜色复制到 `_sourceCopy`，第二步执行 `XBlur` 写入 `_blurX`，第三步执行 `YBlur` 写入 `_blurY`，最后执行 `Composite` 写回相机颜色。合成时绑定相机深度作为 depth/stencil attachment，shader 中的 stencil test 才能读到皮肤材质写入的模板值。

```csharp
Blitter.BlitCameraTexture(cmd, _cameraColor, _sourceCopy);

SetSource(cmd, _sourceCopy);
CoreUtils.SetRenderTarget(cmd, _blurX, ClearFlag.None);
CoreUtils.DrawFullScreen(cmd, _material, null, 0);

SetSource(cmd, _blurX);
CoreUtils.SetRenderTarget(cmd, _blurY, ClearFlag.None);
CoreUtils.DrawFullScreen(cmd, _material, null, 1);

SetSource(cmd, _blurY);
cmd.SetGlobalTexture(ShaderIDs._SSSOriginalTex, _sourceCopy.nameID);
CoreUtils.SetRenderTarget(cmd, _cameraColor, _cameraDepth, ClearFlag.None);
CoreUtils.DrawFullScreen(cmd, _material, null, 2);
```

`SetSource` 会把当前输入 RT 绑定到 `_SSSSSourceTex`，并写入 `_SourceTexelSize`。横向模糊使用当前输入宽度的倒数，纵向模糊使用当前输入高度的倒数。这样同一份 shader 可以处理全分辨率输入和半分辨率输入，不需要为不同质量等级写不同变体。

## 后处理 shader 的三段执行

`SeparableSubsurfaceScatter.shader` 是一个 URP 后处理 shader。它只有三个 pass：`XBlur`、`YBlur`、`Composite`。前两个 pass 不做模板测试，因为半分辨率模糊 RT 没有匹配的模板附件；最终合成 pass 才使用模板限制写入位置。这个处理方式避免了半分辨率 stencil 难以对齐的问题，也让边缘修复交给深度保护完成。

```hlsl
Pass
{
    Name "Composite"

    Stencil
    {
        Ref [_StencilRef]
        Comp Equal
        Pass Keep
    }

    HLSLPROGRAM
    #pragma vertex Vert
    #pragma fragment FragComposite
    #include "SeparableSubsurfaceScatterCommon.cginc"
    ENDHLSL
}
```

采样和卷积逻辑在 `SeparableSubsurfaceScatterCommon.cginc`。它包含 URP 的 `Core.hlsl` 和 `DeclareDepthTexture.hlsl`，因此深度读取改为 `SampleSceneDepth`，线性化改为 `LinearEyeDepth(rawDepth, _ZBufferParams)`。这替代了旧 Built-in 版本中的 `SAMPLE_DEPTH_TEXTURE` 和 `UnityCG.cginc`。

```hlsl
float SceneLinearEyeDepth(float2 uv)
{
    float rawDepth = SampleSceneDepth(uv);
    return LinearEyeDepth(rawDepth, _ZBufferParams);
}
```

`ApplySSS` 是横向和纵向 pass 共用的卷积函数。它先读取中心像素深度，用 `_SSSProjectionDistance / centerDepth` 计算透视缩放，让远处物体的屏幕半径自然变小，近处物体散射半径变大。`axis` 由 pass 决定，横向是 `(texelWidth * scale, 0)`，纵向是 `(0, texelHeight * scale)`。

```hlsl
float centerDepth = SceneLinearEyeDepth(uv);
float blurLength = _SSSProjectionDistance / max(centerDepth, 1.0e-4);
float2 stepVector = axis * blurLength;
float4 result = centerColor * _Kernel[0];
```

深度边缘保护用于解决半分辨率和屏幕空间模糊常见的轮廓漏色。每个邻域样本都会读取自己的深度，和中心深度比较。如果两个深度差距大，说明样本大概率来自背景、衣服或另一个物体，shader 会把该样本颜色向中心颜色拉回。`_SSSDepthEdgeFalloff` 越高，越容易阻止跨深度边界的颜色参与卷积。

```hlsl
float depthDelta = abs(centerDepth - sampleDepth);
float edgeFactor = saturate(depthDelta * _SSSDepthEdgeFalloff);
sampleColor.rgb = lerp(sampleColor.rgb, centerColor.rgb, edgeFactor);

result += sampleColor * _Kernel[i];
```

第一篇文章提到 Built-in 的 `Blit` 默认不能按自定义 stencil 约束绘制，因此旧实现用 `SetGlobalTexture`、`SetRenderTarget`、`DrawMesh` 三步替代。URP 版本保留了这个思想，但执行方式换成 `CoreUtils.SetRenderTarget` 和 `CoreUtils.DrawFullScreen`。这样既能绑定相机 depth/stencil，又能避免旧 `Graphics.Blit` 在 SRP 下的目标管理问题。

## 参数如何影响画面

`scaler` 是最直接的半径参数。它乘上输入纹理的 texel size，再乘上透视深度缩放，得到每次采样沿屏幕移动的基础距离。值过小会几乎看不到散射，值过大会让皮肤变糊并出现颜色外溢。

`strength` 是 RGB 三通道的散射参与度。红色强度高会让皮肤暗部和阴影边缘更偏红，绿色和蓝色强度过高会让画面出现蜡感。当前默认值 `(0.48, 0.41, 0.28)` 是一个偏保守的皮肤起点。

`falloff` 是 RGB 三通道散射距离曲线。它不直接改变最终亮度，而是改变高斯 profile 的宽度。红色 falloff 大于绿色和蓝色时，红色会扩散得更远，这正是皮肤 SSSS 的主要视觉来源。

`sampleCount` 控制采样核数量。25 点质量最高，低于 25 时 `KernelCalculate` 会把范围切到 `[-2, 2]`，减少远端样本带来的抖动和浪费。移动端或低端平台可以从 17 或 11 开始调，但采样数太低会让散射形状更硬。

`downsample` 控制模糊 RT 分辨率。0 是全分辨率，1 是半分辨率，2 是四分之一分辨率。半分辨率通常是性能和质量的平衡点；四分之一分辨率需要更强的深度保护，否则轮廓处更容易出现双线性放大痕迹。

`depthEdgeFalloff` 控制跨深度边界时的回退速度。角色脸部靠近头发、衣领、背景时，如果出现边缘染色，可以提高这个值。如果散射在鼻翼、嘴唇附近过早断开，可以降低这个值。

## 文章扩展整合

当前版本已经把第一篇文章的“论文扩展”落到 URP 渲染链路里。`StencilSurface.shader` 的 `UniversalForward` 不再直接输出完整 PBR，而是输出 DiffuseOnly：直接漫反射、间接漫反射、AO、阴影、雾效和透射项会进入屏幕空间 SSSS。高光被拆到同一个 shader 的 `SSSSSpecularOnly` pass 中，`SubsurfaceScatterPostProcess` 在完成 X/Y blur 和 stencil composite 后，通过 `DrawRenderers` 重新绘制这个 pass，并用 `Blend One One` 叠加回相机颜色。这样就对应第一篇文章的流程：皮肤无高光 PBR -> 屏幕空间 SSS -> 无漫反射高光 PBR。

透射项也从简单背光色改成了第一篇文章中使用的 6 项 diffusion profile。URP 中直接读取原始 shadowmap 厚度会牵涉级联阴影、屏幕空间阴影和平台宏，所以这里做了 URP 兼容实现：默认不需要厚度图，使用背光方向估算 profile distance；如果以后有角色厚度贴图，可以把 `_ThicknessMapWeight` 从 0 提高，让厚度图参与控制。透射最终由 profile、`dot(L, -N)` 背光包裹、视线方向项、主光颜色、阴影衰减和 `_TranslucencyStrength` 共同决定。

第二篇文章的优化也已经整合到当前 URP 版本中。Renderer Feature 默认半分辨率执行 X/Y blur，`useFastRgbFormat` 开启后会在平台支持时把中间 RGB RT 切到 `B10G11R11_UFloatPack32`。`kernelRange` 现在是可调参数，默认 2.0，贴近文章里“移动端用更紧积分域提高有效精度”的建议；如果想更接近 Jimenez 原始宽散射，可以调到 3.0。边缘问题继续使用深度跟随保护处理，避免半分辨率 blur 跨头发、衣服或背景串色。

## 接入流程

项目切到 URP 后，先确保当前 Pipeline Asset 使用的 Renderer 是 Forward Renderer 或 Universal Renderer。打开这个 Renderer asset，在 Renderer Features 列表中添加 `SubsurfaceScatterPostProcess`。`Shader` 字段可以留空，Feature 会通过 `Shader.Find("PostProcess/SeparableSubsurfaceScatter")` 自动创建材质；如果要固定材质实例，也可以手动创建材质并填到 `material` 字段。

需要 SSSS 的皮肤材质改用 `Custom/StencilSurface`。材质上的 `_StencilRef` 要和 Feature 的 `stencilReference` 相同，默认都是 5。普通物体不要使用这个 shader，否则最终合成 pass 会把它们也当成皮肤区域。

调试时先把 `downsample` 设为 0，确认全分辨率下 stencil 区域正确、散射方向正常，再切回 1 检查性能路径。若画面没有效果，先确认 Renderer Feature 是否真的挂在当前相机使用的 Renderer 上，再确认材质是否写入模板，最后检查 `scaler` 和 `strength` 是否过低。

## 旧辅助代码的状态

`GraphicUtils.cs` 是旧 Built-in 版本留下的 CommandBuffer 全屏绘制辅助类。URP 迁移后主流程已经不再调用它，因为 URP 的 RTHandle、相机颜色生命周期和 depth/stencil 绑定方式都不同。文件暂时保留是为了不破坏可能存在的外部引用；当前目录内没有代码再依赖它。

`ShaderIDs.cs` 只保留运行时需要的属性 ID。`_SSSSSourceTex` 是后处理当前 pass 输入，`_SSSOriginalTex` 预留给需要对比原图的扩展，`_Kernel`、`_SampleCount`、`_SSSScale`、`_SSSDepthEdgeFalloff`、`_SSSProjectionDistance` 和 `_SourceTexelSize` 控制卷积，`_StencilRef` 保证 C# 设置和 shader stencil 属性使用同一个整数。

## 验证结果

迁移完成后，`SubsurfaceScatterPostProcess.cs` 和 `ShaderIDs.cs` 通过 Unity MCP 的 `validate_script` 标准校验。Unity 刷新并请求编译后，控制台不再有本目录相关 C# 错误。随后使用 `ShaderUtil.GetShaderMessages` 检查 `PostProcess/SeparableSubsurfaceScatter` 和 `Custom/StencilSurface`，两个 shader 的 message count 都为 0。

当前控制台仍有项目其他目录的旧警告，例如 GTAO、SSR、体积光脚本中的隐藏成员和 obsolete API 提示，还有一个包解析异常提示。这些日志不来自 `Assets/ssss屏幕空间次表面散射/ssss`，本次没有修改它们。

## 后续扩展方向

当前实现已经完成 URP 后处理迁移、模板限制、半分辨率模糊、深度边缘保护和可调 kernel。若要继续贴近完整皮肤渲染管线，下一步应把皮肤材质拆成 diffuse/specular 两条路径，让 SSSS 只处理 diffuse，再在散射后叠加 specular。透射项则需要新增厚度数据来源，可以选择角色厚度贴图，也可以在光源空间利用阴影图估算背光路径长度；这部分最好作为单独功能加入，而不是塞进当前全屏模糊 pass。
