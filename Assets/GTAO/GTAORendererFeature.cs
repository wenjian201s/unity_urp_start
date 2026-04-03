namespace UnityEngine.Rendering.Universal
{
    public class GTAORendererFeature : ScriptableRendererFeature
    {
        [System.Serializable]
        public class GTAOSettings
        {
            public bool isEnabled;
            public RenderPassEvent renderPassEvent = RenderPassEvent.AfterRenderingOpaques;
            public ComputeShader gtaoComputeShader;
        }

        public GTAOSettings settings = new GTAOSettings();
        private GTAORenderPass gtaoRenderPass;
        public override void Create()
        {
            gtaoRenderPass = new GTAORenderPass(settings);
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            GroundTruthAmbientOcclusion gtao = VolumeManager.instance.stack.GetComponent<GroundTruthAmbientOcclusion>();
            if (gtao != null && gtao.IsActive())
            {
                gtaoRenderPass.Setup(gtao);
                renderer.EnqueuePass(gtaoRenderPass);
            }
        }
    }
}