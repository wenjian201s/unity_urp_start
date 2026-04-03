namespace UnityEngine.Rendering.Universal
{
    public class GTAORenderPass : ScriptableRenderPass
    {
        private const string profilerTag = "Ground Truth Ambient Occlusion";
        private const string gtaoKernelName = "GTAOMain";
        private const string blurHorizontalKernelName = "BlurHorizontalMain";
        private const string blurVerticalKernelName = "BlurVerticalMain";
        private const string visualizeKernelName = "VisualizeMain";

        private ProfilingSampler profilingSampler;
        private ProfilingSampler gtaoSampler = new ProfilingSampler("GTAO Pass");
        private ProfilingSampler blurSampler = new ProfilingSampler("Blur Pass");
        private ProfilingSampler visualizeSampler = new ProfilingSampler("Visualize Pass");

        private RenderTargetHandle cameraColor;
        private RenderTargetIdentifier cameraColorIden;
        private RenderTargetHandle cameraDepth;
        private RenderTargetIdentifier cameraDepthIden;
        private RenderTargetHandle cameraDepthAttachment;
        private RenderTargetIdentifier cameraDepthAttachmentIden;

        private static readonly string gtaoTextureName = "_GTAOBuffer";
        private static readonly int gtaoTextureID = Shader.PropertyToID(gtaoTextureName);
        private RenderTargetHandle gtaoTextureHandle;
        private RenderTargetIdentifier gtaoTextureIden;

        private static readonly string horizontalBlurTextureName = "_HorizontalBlurBuffer";
        private static readonly int horizontalBlurTextureID = Shader.PropertyToID(horizontalBlurTextureName);
        private RenderTargetHandle horizontalBlurTextureHandle;
        private RenderTargetIdentifier horizontalBlurTextureIden;

        private static readonly string vericalBlurTextureName = "_VerticalBlurBuffer";
        private static readonly int vericalBlurTextureID = Shader.PropertyToID(vericalBlurTextureName);
        private RenderTargetHandle vericalBlurTextureHandle;
        private RenderTargetIdentifier vericalBlurTextureIden;

        private static readonly string visualizeTextureName = "_VisualizeBuffer";
        private static readonly int visualizeTextureID = Shader.PropertyToID(visualizeTextureName);
        private RenderTargetHandle visualizeTextureHandle;
        private RenderTargetIdentifier visualizeTextureIden;

        private GroundTruthAmbientOcclusion groundTruthAmbientOcclusion;
        private ComputeShader gtaoComputeShader;
        private GTAORendererFeature.GTAOSettings settings;

        private int downsamplingFactor;
        private Vector2Int fullRes;
        private Vector2Int downsampleRes;
        private int frameIndex;

        static readonly int _GTAOFrameIndexID = Shader.PropertyToID("_FrameIndex");
        static readonly int _GTAODownsamplingFactorID = Shader.PropertyToID("_DownsamplingFactor");
        static readonly int _GTAOIntensityID = Shader.PropertyToID("_Intensity");
        static readonly int _GTAOSampleRadiusID = Shader.PropertyToID("_SampleRadius");
        static readonly int _GTAODistributionPowerID = Shader.PropertyToID("_DistributionPower");
        static readonly int _GTAOFalloffRangeID = Shader.PropertyToID("_FalloffRange");

        static readonly int _GTAOTextureSizeID = Shader.PropertyToID("_TextureSize");
        static readonly int _GTAOColorTextureID = Shader.PropertyToID("_ColorTexture");
        static readonly int _GTAODepthTextureID = Shader.PropertyToID("_DepthTexture");
        static readonly int _GTAOTextureID = Shader.PropertyToID("_GTAOTexture");
        static readonly int _GTAORWTextureID = Shader.PropertyToID("_RW_GTAOTexture");
        static readonly int _GTAORWBlurTextureID = Shader.PropertyToID("_RW_BlurTexture");
        static readonly int _GTAORWVisualizeTextureID = Shader.PropertyToID("_RW_VisualizeTexture");

        public GTAORenderPass(GTAORendererFeature.GTAOSettings settings)
        {
            this.settings = settings;
            profilingSampler = new ProfilingSampler(profilerTag);
            renderPassEvent = settings.renderPassEvent;
            gtaoComputeShader = settings.gtaoComputeShader;

            cameraColor.Init("_CameraColorTexture");
            cameraColorIden = cameraColor.Identifier();
            cameraDepth.Init("_CameraDepthTexture");
            cameraDepthIden = cameraDepth.Identifier();
            cameraDepthAttachment.Init("_CameraDepthAttachment");
            cameraDepthAttachmentIden = cameraDepthAttachment.Identifier();

            gtaoTextureHandle.Init(gtaoTextureName);
            gtaoTextureIden = gtaoTextureHandle.Identifier();
            horizontalBlurTextureHandle.Init(horizontalBlurTextureName);
            horizontalBlurTextureIden = horizontalBlurTextureHandle.Identifier();
            vericalBlurTextureHandle.Init(vericalBlurTextureName);
            vericalBlurTextureIden = vericalBlurTextureHandle.Identifier();
            visualizeTextureHandle.Init(visualizeTextureName);
            visualizeTextureIden = visualizeTextureHandle.Identifier();

            frameIndex = 0;
        }

        public void Setup(GroundTruthAmbientOcclusion groundTruthAmbientOcclusion)
        {
            this.groundTruthAmbientOcclusion = groundTruthAmbientOcclusion;
        }

        public override void Configure(CommandBuffer cmd, RenderTextureDescriptor cameraTextureDescriptor)
        {
            RenderTextureDescriptor desc = cameraTextureDescriptor;
            desc.enableRandomWrite = true;
            desc.depthBufferBits = 0;
            desc.msaaSamples = 1;
            desc.graphicsFormat = Experimental.Rendering.GraphicsFormat.R16G16B16A16_SFloat;

            downsamplingFactor = groundTruthAmbientOcclusion.downsamplingFactor.value;
            fullRes = new Vector2Int(desc.width, desc.height);
            downsampleRes = new Vector2Int(Mathf.CeilToInt((float)desc.width / downsamplingFactor), Mathf.CeilToInt((float)desc.height / downsamplingFactor));

            cmd.GetTemporaryRT(visualizeTextureID, desc);
            cmd.GetTemporaryRT(vericalBlurTextureID, desc);
            desc.height = downsampleRes.y;
            cmd.GetTemporaryRT(horizontalBlurTextureID, desc);
            desc.width = downsampleRes.x;
            cmd.GetTemporaryRT(gtaoTextureID, desc);      
        }

        private void DoGTAOCalculation(CommandBuffer cmd, RenderTargetIdentifier depthid, RenderTargetIdentifier gtaoid, ComputeShader computeShader)
        {
            if (!computeShader.HasKernel(gtaoKernelName)) return;
            int gtaoKernel = computeShader.FindKernel(gtaoKernelName);

            computeShader.GetKernelThreadGroupSizes(gtaoKernel, out uint x, out uint y, out uint z);
            cmd.SetComputeIntParam(computeShader, _GTAOFrameIndexID, frameIndex);
            cmd.SetComputeIntParam(computeShader, _GTAODownsamplingFactorID, downsamplingFactor);
            cmd.SetComputeVectorParam(computeShader, _GTAOTextureSizeID, new Vector4(fullRes.x, fullRes.y, 1.0f / fullRes.x, 1.0f / fullRes.y));

            cmd.SetComputeFloatParam(computeShader, _GTAOSampleRadiusID, groundTruthAmbientOcclusion.radius.value);
            cmd.SetComputeFloatParam(computeShader, _GTAODistributionPowerID, groundTruthAmbientOcclusion.distributionPower.value);
            cmd.SetComputeFloatParam(computeShader, _GTAOFalloffRangeID, groundTruthAmbientOcclusion.falloffRange.value);

            cmd.SetComputeTextureParam(computeShader, gtaoKernel, _GTAODepthTextureID, depthid);
            cmd.SetComputeTextureParam(computeShader, gtaoKernel, _GTAORWTextureID, gtaoid);

            cmd.DispatchCompute(computeShader, gtaoKernel,
                    Mathf.CeilToInt((float)downsampleRes.x / x),
                    Mathf.CeilToInt((float)downsampleRes.y / y),
                    1);
        }

        private void DoBlur(CommandBuffer cmd, RenderTargetIdentifier gtaoid, RenderTargetIdentifier horizontalid, RenderTargetIdentifier verticalid, ComputeShader computeShader)
        {
            if (!computeShader.HasKernel(blurHorizontalKernelName) || !computeShader.HasKernel(blurVerticalKernelName)) return;
            int horizontalKernel = computeShader.FindKernel(blurHorizontalKernelName);
            int verticalKernel = computeShader.FindKernel(blurVerticalKernelName);

            uint x, y, z;
            computeShader.GetKernelThreadGroupSizes(horizontalKernel, out x, out y, out z);
            cmd.SetComputeTextureParam(computeShader, horizontalKernel, _GTAOTextureID, gtaoid);
            cmd.SetComputeTextureParam(computeShader, horizontalKernel, _GTAORWBlurTextureID, horizontalid);
            cmd.DispatchCompute(computeShader, horizontalKernel,
                                Mathf.CeilToInt((float)fullRes.x / x),
                                Mathf.CeilToInt((float)downsampleRes.y / y),
                                1);

            computeShader.GetKernelThreadGroupSizes(verticalKernel, out x, out y, out z);
            cmd.SetComputeTextureParam(computeShader, verticalKernel, _GTAOTextureID, horizontalid);
            cmd.SetComputeTextureParam(computeShader, verticalKernel, _GTAORWBlurTextureID, verticalid);
            cmd.DispatchCompute(computeShader, verticalKernel,
                                Mathf.CeilToInt((float)fullRes.x / x),
                                Mathf.CeilToInt((float)fullRes.y / y),
                                1);
        }

        private void DoVisualization(CommandBuffer cmd, RenderTargetIdentifier colorid, RenderTargetIdentifier verticalid, RenderTargetIdentifier visualizeid, ComputeShader computeShader)
        {
            if (!computeShader.HasKernel(visualizeKernelName)) return;
            int visualzieKernel = computeShader.FindKernel(visualizeKernelName);
            cmd.SetComputeFloatParam(computeShader, _GTAOIntensityID, groundTruthAmbientOcclusion.intensity.value);

            computeShader.GetKernelThreadGroupSizes(visualzieKernel, out uint x, out uint y, out uint z);
            cmd.SetComputeTextureParam(computeShader, visualzieKernel, _GTAOColorTextureID, colorid);
            cmd.SetComputeTextureParam(computeShader, visualzieKernel, _GTAOTextureID, verticalid);
            cmd.SetComputeTextureParam(computeShader, visualzieKernel, _GTAORWVisualizeTextureID, visualizeid);
            cmd.DispatchCompute(computeShader, visualzieKernel,
                                Mathf.CeilToInt((float)fullRes.x / x),
                                Mathf.CeilToInt((float)fullRes.y / y),
                                1);

            cmd.Blit(visualizeid, colorid);
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get(profilerTag);
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();

            using (new ProfilingScope(cmd, profilingSampler))
            {
                using (new ProfilingScope(cmd, gtaoSampler))
                {
                    if(renderingData.cameraData.isSceneViewCamera)
                    {
                        DoGTAOCalculation(cmd, cameraDepthIden, gtaoTextureIden, gtaoComputeShader);
                    }
                    else
                    {
                        DoGTAOCalculation(cmd, cameraDepthAttachmentIden, gtaoTextureIden, gtaoComputeShader);
                    }
                }

                using (new ProfilingScope(cmd, blurSampler))
                {
                    DoBlur(cmd, gtaoTextureIden, horizontalBlurTextureIden, vericalBlurTextureIden, gtaoComputeShader);
                }

                using (new ProfilingScope(cmd, visualizeSampler))
                {
                    DoVisualization(cmd, cameraColorIden, vericalBlurTextureIden, visualizeTextureIden, gtaoComputeShader);
                }
            }

            frameIndex=(++frameIndex)%60;

            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            CommandBufferPool.Release(cmd);
        }

        public override void FrameCleanup(CommandBuffer cmd)
        {
            cmd.ReleaseTemporaryRT(gtaoTextureID);
            cmd.ReleaseTemporaryRT(horizontalBlurTextureID);
            cmd.ReleaseTemporaryRT(vericalBlurTextureID);
            cmd.ReleaseTemporaryRT(visualizeTextureID);
        }
    }
}
