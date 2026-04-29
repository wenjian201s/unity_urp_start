using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace SSR {
    internal enum BlendMode {
        Addtive,
        Balance
    }

    [Serializable]
    internal class SSRSettings {
        [SerializeField, Range(0.0f, 1.0f)] internal float Intensity = 0.8f;
        [SerializeField, Min(0.01f)] internal float MaxDistance = 10.0f;
        [SerializeField, Range(1, 64)] internal int Stride = 8;
        [SerializeField, Range(1, 128)] internal int StepCount = 64;
        [SerializeField, Min(0.001f)] internal float Thickness = 0.25f;
        [SerializeField, Range(0, 8)] internal int BinaryCount = 5;
        [SerializeField] internal bool jitterDither = true;
        [SerializeField] internal bool UseHiZ = true;
        [SerializeField, Range(1, 12)] internal int MipCount = 8;
        [SerializeField] internal BlendMode blendMode = BlendMode.Addtive;
        [SerializeField, Range(0.0f, 5.0f)] internal float BlurRadius = 1.0f;
        [SerializeField, Range(0.0f, 0.5f)] internal float RayBias = 0.03f;
        [SerializeField, Range(0.0f, 8.0f)] internal float DistanceFade = 2.0f;
        [SerializeField, Range(0.0f, 50.0f)] internal float EdgeFade = 8.0f;
        [SerializeField, Range(0.0f, 1.0f)] internal float FresnelStrength = 0.35f;
    }

    [DisallowMultipleRendererFeature("SSR")]
    public class SSR : ScriptableRendererFeature {
        [SerializeField] private SSRSettings mSettings = new SSRSettings();

        private const string ShaderName = "Hidden/SSR";

        private Shader mShader;
        private RenderPass mRenderPass;
        private Material mMaterial;

        public override void Create() {
            mRenderPass ??= new RenderPass {
                renderPassEvent = RenderPassEvent.AfterRenderingOpaques
            };
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData) {
            CameraType cameraType = renderingData.cameraData.cameraType;
            if (cameraType != CameraType.Game && cameraType != CameraType.SceneView)
                return;

            if (!GetMaterial()) {
                Debug.LogErrorFormat("{0}.AddRenderPasses(): Missing shader or material for {1}.", GetType().Name, name);
                return;
            }

            if (mRenderPass.Setup(mSettings, mMaterial))
                renderer.EnqueuePass(mRenderPass);
        }

        protected override void Dispose(bool disposing) {
            CoreUtils.Destroy(mMaterial);
            mRenderPass?.Dispose();
            mRenderPass = null;
        }

        private bool GetMaterial() {
            if (mShader == null)
                mShader = Shader.Find(ShaderName);

            if (mMaterial == null && mShader != null)
                mMaterial = CoreUtils.CreateEngineMaterial(mShader);

            return mMaterial != null && mMaterial.passCount >= RenderPass.RequiredPassCount;
        }

        private sealed class RenderPass : ScriptableRenderPass {
            internal const int RequiredPassCount = 5;
            private const int MaxHiZMipCount = 12;

            private enum ShaderPass {
                GenerateHiZ,
                Raymarching,
                Blur,
                Addtive,
                Balance
            }

            private static readonly int SourceSizeID = Shader.PropertyToID("_SourceSize");
            private static readonly int SSRParams0ID = Shader.PropertyToID("_SSRParams0");
            private static readonly int SSRParams1ID = Shader.PropertyToID("_SSRParams1");
            private static readonly int SSRParams2ID = Shader.PropertyToID("_SSRParams2");
            private static readonly int BlurRadiusID = Shader.PropertyToID("_SSRBlurRadius");
            private static readonly int SourceTextureID = Shader.PropertyToID("_SSRSourceTexture");
            private static readonly int HiZSourceSizeID = Shader.PropertyToID("_HiZSourceSize");
            private static readonly int HiZBufferTextureID = Shader.PropertyToID("_HierarchicalZBufferTexture");
            private static readonly int HiZBufferFromMipLevelID = Shader.PropertyToID("_HierarchicalZBufferTextureFromMipLevel");
            private static readonly int MaxHiZBufferMipLevelID = Shader.PropertyToID("_MaxHierarchicalZBufferTextureMipLevel");

            private const string JitterKeyword = "_JITTER_ON";
            private const string HiZKeyword = "_HIZ_ON";
            private const string SourceCopyTextureName = "_SSRSourceCopy";
            private const string SSRTexture0Name = "_SSRTexture0";
            private const string SSRTexture1Name = "_SSRTexture1";
            private const string HiZBufferTextureName = "_SSRHiZBuffer";
            private const string HiZBufferMipTextureName = "_SSRHiZBufferMip";

            private readonly ProfilingSampler mProfilingSampler = new ProfilingSampler("SSR");
            private readonly RTHandle[] mHiZBufferMipTextures = new RTHandle[MaxHiZMipCount];
            private readonly RenderTextureDescriptor[] mHiZBufferMipDescriptors = new RenderTextureDescriptor[MaxHiZMipCount];

            private SSRSettings mSettings;
            private Material mMaterial;
            private RenderTextureDescriptor mDescriptor;
            private RenderTextureDescriptor mHiZBufferDescriptor;
            private RTHandle mSourceCopyTexture;
            private RTHandle mSSRTexture0;
            private RTHandle mSSRTexture1;
            private RTHandle mHiZBufferTexture;
            private int mHiZMipCount = 1;

            internal bool Setup(SSRSettings featureSettings, Material material) {
                mSettings = featureSettings;
                mMaterial = material;
                ConfigureInput(ScriptableRenderPassInput.Depth | ScriptableRenderPassInput.Normal);
                return mMaterial != null && mMaterial.passCount >= RequiredPassCount;
            }

            public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData) {
                mDescriptor = renderingData.cameraData.cameraTargetDescriptor;
                mDescriptor.msaaSamples = 1;
                mDescriptor.depthBufferBits = 0;

                RenderingUtils.ReAllocateIfNeeded(ref mSourceCopyTexture, mDescriptor, FilterMode.Bilinear, TextureWrapMode.Clamp, name: SourceCopyTextureName);
                RenderingUtils.ReAllocateIfNeeded(ref mSSRTexture0, mDescriptor, FilterMode.Bilinear, TextureWrapMode.Clamp, name: SSRTexture0Name);
                RenderingUtils.ReAllocateIfNeeded(ref mSSRTexture1, mDescriptor, FilterMode.Bilinear, TextureWrapMode.Clamp, name: SSRTexture1Name);

                if (mSettings.UseHiZ)
                    AllocateHiZTextures();
                else
                    ReleaseHiZTextures();

                mMaterial.SetVector(SourceSizeID, new Vector4(mDescriptor.width, mDescriptor.height, 1.0f / mDescriptor.width, 1.0f / mDescriptor.height));
                mMaterial.SetVector(SSRParams0ID, new Vector4(mSettings.MaxDistance, mSettings.Stride, mSettings.StepCount, mSettings.Thickness));
                mMaterial.SetVector(SSRParams1ID, new Vector4(mSettings.BinaryCount, mSettings.Intensity, 0.0f, 0.0f));
                mMaterial.SetVector(SSRParams2ID, new Vector4(mSettings.RayBias, mSettings.DistanceFade, mSettings.EdgeFade, mSettings.FresnelStrength));

                if (mSettings.jitterDither)
                    mMaterial.EnableKeyword(JitterKeyword);
                else
                    mMaterial.DisableKeyword(JitterKeyword);

                if (mSettings.UseHiZ)
                    mMaterial.EnableKeyword(HiZKeyword);
                else
                    mMaterial.DisableKeyword(HiZKeyword);

                ConfigureTarget(renderingData.cameraData.renderer.cameraColorTargetHandle);
                ConfigureClear(ClearFlag.None, Color.clear);
            }

            public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData) {
                if (mMaterial == null)
                    return;

                RTHandle cameraColor = renderingData.cameraData.renderer.cameraColorTargetHandle;
                if (mSourceCopyTexture == null || mSSRTexture0 == null || mSSRTexture1 == null || cameraColor == null || cameraColor.rt == null)
                    return;

                CommandBuffer cmd = CommandBufferPool.Get();

                using (new ProfilingScope(cmd, mProfilingSampler)) {
                    bool useHiZ = mSettings.UseHiZ && mHiZBufferTexture != null && mHiZBufferMipTextures[0] != null;
                    if (useHiZ) {
                        BuildHiZBuffer(cmd, renderingData.cameraData.renderer.cameraDepthTargetHandle);
                        cmd.SetGlobalFloat(MaxHiZBufferMipLevelID, mHiZMipCount - 1);
                        cmd.SetGlobalTexture(HiZBufferTextureID, mHiZBufferTexture.nameID);
                        mMaterial.EnableKeyword(HiZKeyword);
                    }
                    else {
                        mMaterial.DisableKeyword(HiZKeyword);
                    }

                    Blitter.BlitCameraTexture(cmd, cameraColor, mSourceCopyTexture);
                    cmd.SetGlobalTexture(SourceTextureID, mSourceCopyTexture.nameID);

                    Blitter.BlitCameraTexture(cmd, mSourceCopyTexture, mSSRTexture0, mMaterial, (int)ShaderPass.Raymarching);

                    cmd.SetGlobalVector(BlurRadiusID, new Vector4(mSettings.BlurRadius, 0.0f, 0.0f, 0.0f));
                    Blitter.BlitCameraTexture(cmd, mSSRTexture0, mSSRTexture1, mMaterial, (int)ShaderPass.Blur);

                    cmd.SetGlobalVector(BlurRadiusID, new Vector4(0.0f, mSettings.BlurRadius, 0.0f, 0.0f));
                    Blitter.BlitCameraTexture(cmd, mSSRTexture1, mSSRTexture0, mMaterial, (int)ShaderPass.Blur);

                    cmd.SetGlobalTexture(SourceTextureID, mSourceCopyTexture.nameID);
                    int blendPass = mSettings.blendMode == BlendMode.Addtive ? (int)ShaderPass.Addtive : (int)ShaderPass.Balance;
                    Blitter.BlitCameraTexture(cmd, mSSRTexture0, cameraColor, mMaterial, blendPass);
                }

                context.ExecuteCommandBuffer(cmd);
                CommandBufferPool.Release(cmd);
            }

            public override void OnCameraCleanup(CommandBuffer cmd) {
            }

            public void Dispose() {
                mSourceCopyTexture?.Release();
                mSSRTexture0?.Release();
                mSSRTexture1?.Release();
                ReleaseHiZTextures();
                mSourceCopyTexture = null;
                mSSRTexture0 = null;
                mSSRTexture1 = null;
            }

            private void AllocateHiZTextures() {
                int width = Mathf.Max(1, Mathf.NextPowerOfTwo(Mathf.Max(1, mDescriptor.width)) >> 1);
                int height = Mathf.Max(1, Mathf.NextPowerOfTwo(Mathf.Max(1, mDescriptor.height)) >> 1);
                int maxDimension = Mathf.Max(width, height);
                int maxPossibleMipCount = 1;
                while (maxDimension > 1 && maxPossibleMipCount < MaxHiZMipCount) {
                    maxDimension >>= 1;
                    maxPossibleMipCount++;
                }

                mHiZMipCount = Mathf.Clamp(mSettings.MipCount, 1, maxPossibleMipCount);

                mHiZBufferDescriptor = new RenderTextureDescriptor(width, height, RenderTextureFormat.RFloat, 0) {
                    msaaSamples = 1,
                    depthBufferBits = 0,
                    useMipMap = true,
                    autoGenerateMips = false,
                    mipCount = mHiZMipCount,
                    sRGB = false
                };

                RenderingUtils.ReAllocateIfNeeded(ref mHiZBufferTexture, mHiZBufferDescriptor, FilterMode.Point, TextureWrapMode.Clamp, name: HiZBufferTextureName);

                for (int i = 0; i < mHiZMipCount; i++) {
                    RenderTextureDescriptor mipDescriptor = new RenderTextureDescriptor(width, height, RenderTextureFormat.RFloat, 0) {
                        msaaSamples = 1,
                        depthBufferBits = 0,
                        useMipMap = false,
                        autoGenerateMips = false,
                        mipCount = 1,
                        sRGB = false
                    };

                    mHiZBufferMipDescriptors[i] = mipDescriptor;
                    RenderingUtils.ReAllocateIfNeeded(ref mHiZBufferMipTextures[i], mipDescriptor, FilterMode.Point, TextureWrapMode.Clamp, name: HiZBufferMipTextureName + i);

                    width = Mathf.Max(width >> 1, 1);
                    height = Mathf.Max(height >> 1, 1);
                }

                for (int i = mHiZMipCount; i < MaxHiZMipCount; i++) {
                    mHiZBufferMipTextures[i]?.Release();
                    mHiZBufferMipTextures[i] = null;
                }
            }

            private void BuildHiZBuffer(CommandBuffer cmd, RTHandle cameraDepth) {
                if (cameraDepth == null || mHiZBufferTexture == null || mHiZBufferMipTextures[0] == null)
                    return;

                Blitter.BlitCameraTexture(cmd, cameraDepth, mHiZBufferMipTextures[0]);
                cmd.CopyTexture(mHiZBufferMipTextures[0], 0, 0, mHiZBufferTexture, 0, 0);

                for (int i = 1; i < mHiZMipCount; i++) {
                    RenderTextureDescriptor previousDescriptor = mHiZBufferMipDescriptors[i - 1];
                    cmd.SetGlobalFloat(HiZBufferFromMipLevelID, 0.0f);
                    cmd.SetGlobalVector(HiZSourceSizeID, new Vector4(previousDescriptor.width, previousDescriptor.height, 1.0f / previousDescriptor.width, 1.0f / previousDescriptor.height));
                    Blitter.BlitCameraTexture(cmd, mHiZBufferMipTextures[i - 1], mHiZBufferMipTextures[i], mMaterial, (int)ShaderPass.GenerateHiZ);
                    cmd.CopyTexture(mHiZBufferMipTextures[i], 0, 0, mHiZBufferTexture, 0, i);
                }
            }

            private void ReleaseHiZTextures() {
                mHiZBufferTexture?.Release();
                mHiZBufferTexture = null;

                for (int i = 0; i < mHiZBufferMipTextures.Length; i++) {
                    mHiZBufferMipTextures[i]?.Release();
                    mHiZBufferMipTextures[i] = null;
                }
            }
        }
    }
}
