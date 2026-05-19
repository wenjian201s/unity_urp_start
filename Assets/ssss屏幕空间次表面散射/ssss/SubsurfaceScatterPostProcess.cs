using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

/// <summary>
/// URP renderer feature for Jimenez-style separable screen-space subsurface scattering.
/// Add this feature to the active URP Renderer asset, then use StencilSurface.shader on skin materials.
/// </summary>
public sealed class SubsurfaceScatterPostProcess : ScriptableRendererFeature
{
    private const int MaxSampleCount = 25;

    public enum DebugView
    {
        Final = 0,
        FullscreenBlur = 1,
        StencilMask = 2,
        FullscreenTint = 3
    }

    [Serializable]
    public sealed class Settings
    {
        [Header("Injection")]
        public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingOpaques;
        public bool renderInSceneView = true;

        [Header("Diagnostics")]
        public DebugView debugView = DebugView.Final;

        [Header("Shader")]
        public Shader shader;
        public Material material;

        [Header("Skin Mask")]
        [Range(0, 255)]
        public int stencilReference = 5;
        [Tooltip("Objects on these layers are eligible for the post-SSS specular-only redraw pass.")]
        public LayerMask skinLayerMask = -1;

        [Header("Scattering")]
        [Min(0.0f)]
        public float scaler = 3.0f;
        public Color strength = new Color(0.48f, 0.41f, 0.28f, 1.0f);
        public Color falloff = new Color(1.0f, 0.37f, 0.3f, 1.0f);
        [Tooltip("Kernel integration range. 2 is tighter and usually cleaner for half-resolution/mobile use; 3 matches the wider Jimenez reference range.")]
        [Range(1.0f, 3.0f)]
        public float kernelRange = 2.0f;
        [Range(3, MaxSampleCount)]
        public int sampleCount = MaxSampleCount;

        [Header("Paper Extension")]
        [Tooltip("Redraws the skin shader's SSSSSpecularOnly pass after the screen-space blur so highlights are not blurred.")]
        public bool renderSpecularAfterSSS = true;

        [Header("Quality")]
        [Tooltip("0 = full resolution, 1 = half resolution, 2 = quarter resolution.")]
        [Range(0, 2)]
        public int downsample = 1;
        [Tooltip("Use B10G11R11_UFloatPack32 for intermediate RGB buffers when the platform supports it.")]
        public bool useFastRgbFormat = true;
        [Tooltip("Higher values preserve color at depth discontinuities and reduce halo bleeding.")]
        [Min(0.0f)]
        public float depthEdgeFalloff = 300.0f;
        [Tooltip("Projection window distance used to keep the blur radius stable in perspective.")]
        [Min(0.001f)]
        public float projectionDistance = 5.671f;
    }

    public Settings settings = new Settings();

    private SubsurfaceScatterPass _pass;
    private Material _runtimeMaterial;

    public override void Create()
    {
        settings.shader = settings.shader != null
            ? settings.shader
            : Shader.Find("PostProcess/SeparableSubsurfaceScatter");

        _runtimeMaterial = settings.material != null
            ? settings.material
            : CoreUtils.CreateEngineMaterial(settings.shader);

        _pass = new SubsurfaceScatterPass(settings, _runtimeMaterial)
        {
            renderPassEvent = settings.renderPassEvent
        };
    }

    public override void SetupRenderPasses(ScriptableRenderer renderer, in RenderingData renderingData)
    {
        if (_pass == null)
            return;

        _pass.renderPassEvent = settings.renderPassEvent;
        _pass.Setup(renderer.cameraColorTargetHandle, renderer.cameraDepthTargetHandle);
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        if (_pass == null || _runtimeMaterial == null)
            return;

        Camera camera = renderingData.cameraData.camera;
        if (camera == null)
            return;

        if (!settings.renderInSceneView && renderingData.cameraData.isSceneViewCamera)
            return;

        if (camera.cameraType == CameraType.Reflection || camera.cameraType == CameraType.Preview)
            return;

        renderer.EnqueuePass(_pass);
    }

    protected override void Dispose(bool disposing)
    {
        _pass?.Dispose();
        _pass = null;

        if (settings.material == null)
            CoreUtils.Destroy(_runtimeMaterial);

        _runtimeMaterial = null;
    }

    private sealed class SubsurfaceScatterPass : ScriptableRenderPass
    {
        private readonly Settings _settings;
        private readonly Material _material;
        private readonly List<Vector4> _kernel = new List<Vector4>(MaxSampleCount);
        private static readonly List<ShaderTagId> SpecularOnlyShaderTagIds = new List<ShaderTagId>
        {
            new ShaderTagId("SSSSSpecularOnly")
        };

        private RTHandle _cameraColor;
        private RTHandle _cameraDepth;
        private RTHandle _sourceCopy;
        private RTHandle _blurX;
        private RTHandle _blurY;

        public SubsurfaceScatterPass(Settings settings, Material material)
        {
            _settings = settings;
            _material = material;
            ConfigureInput(ScriptableRenderPassInput.Depth);
        }

        public void Setup(RTHandle cameraColor, RTHandle cameraDepth)
        {
            _cameraColor = cameraColor;
            _cameraDepth = cameraDepth;
        }

        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            RenderTextureDescriptor descriptor = renderingData.cameraData.cameraTargetDescriptor;
            descriptor.depthBufferBits = 0;
            descriptor.msaaSamples = 1;
            descriptor.useMipMap = false;
            descriptor.autoGenerateMips = false;
            ApplyIntermediateFormat(ref descriptor);

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

            RenderingUtils.ReAllocateIfNeeded(
                ref _blurX,
                in descriptor,
                FilterMode.Bilinear,
                TextureWrapMode.Clamp,
                name: "_SSSS_BlurX"
            );

            RenderingUtils.ReAllocateIfNeeded(
                ref _blurY,
                in descriptor,
                FilterMode.Bilinear,
                TextureWrapMode.Clamp,
                name: "_SSSS_BlurY"
            );
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            if (_material == null || _cameraColor == null || _cameraDepth == null)
                return;

            CommandBuffer cmd = CommandBufferPool.Get("Separable Subsurface Scatter");

            using (new ProfilingScope(cmd, new ProfilingSampler("Separable Subsurface Scatter")))
            {
                UpdateMaterialProperties();

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
                CoreUtils.DrawFullScreen(cmd, _material, null, GetFinalPassIndex());

                if (_settings.renderSpecularAfterSSS)
                {
                    CoreUtils.SetRenderTarget(cmd, _cameraColor, _cameraDepth, ClearFlag.None);
                    context.ExecuteCommandBuffer(cmd);
                    cmd.Clear();

                    DrawSpecularOnly(context, ref renderingData);
                }
            }

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        private int GetFinalPassIndex()
        {
            switch (_settings.debugView)
            {
                case DebugView.FullscreenBlur:
                    return 3;
                case DebugView.StencilMask:
                    return 4;
                case DebugView.FullscreenTint:
                    return 5;
                default:
                    return 2;
            }
        }

        private void UpdateMaterialProperties()
        {
            int sampleCount = Mathf.Clamp(_settings.sampleCount, 3, MaxSampleCount);
            _kernel.Clear();
            Vector3 strength = new Vector3(_settings.strength.r, _settings.strength.g, _settings.strength.b);
            Vector3 falloff = new Vector3(_settings.falloff.r, _settings.falloff.g, _settings.falloff.b);
            KernelCalculate.CalculateKernel(_kernel, sampleCount, strength, falloff, Mathf.Clamp(_settings.kernelRange, 1.0f, 3.0f));

            _material.SetVectorArray(ShaderIDs._Kernel, _kernel);
            _material.SetInt(ShaderIDs._SampleCount, sampleCount);
            _material.SetFloat(ShaderIDs._SSSScale, Mathf.Max(0.0f, _settings.scaler));
            _material.SetFloat(ShaderIDs._SSSDepthEdgeFalloff, Mathf.Max(0.0f, _settings.depthEdgeFalloff));
            _material.SetFloat(ShaderIDs._SSSProjectionDistance, Mathf.Max(0.001f, _settings.projectionDistance));
            _material.SetInt(ShaderIDs._StencilRef, Mathf.Clamp(_settings.stencilReference, 0, 255));
        }

        private void SetSource(CommandBuffer cmd, RTHandle source)
        {
            cmd.SetGlobalTexture(ShaderIDs._SSSSSourceTex, source.nameID);

            RenderTexture rt = source.rt;
            Vector4 texelSize = rt != null
                ? new Vector4(1.0f / rt.width, 1.0f / rt.height, rt.width, rt.height)
                : Vector4.one;

            cmd.SetGlobalVector(ShaderIDs._SourceTexelSize, texelSize);
        }

        private void ApplyIntermediateFormat(ref RenderTextureDescriptor descriptor)
        {
            if (!_settings.useFastRgbFormat)
                return;

            if (SystemInfo.IsFormatSupported(GraphicsFormat.B10G11R11_UFloatPack32, FormatUsage.Render))
                descriptor.graphicsFormat = GraphicsFormat.B10G11R11_UFloatPack32;
        }

        private void DrawSpecularOnly(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            SortingCriteria sortingCriteria = renderingData.cameraData.defaultOpaqueSortFlags;
            DrawingSettings drawingSettings = CreateDrawingSettings(SpecularOnlyShaderTagIds, ref renderingData, sortingCriteria);
            FilteringSettings filteringSettings = new FilteringSettings(RenderQueueRange.opaque, _settings.skinLayerMask.value);
            context.DrawRenderers(renderingData.cullResults, ref drawingSettings, ref filteringSettings);
        }

        public void Dispose()
        {
            _sourceCopy?.Release();
            _blurX?.Release();
            _blurY?.Release();

            _sourceCopy = null;
            _blurX = null;
            _blurY = null;
        }
    }
}
