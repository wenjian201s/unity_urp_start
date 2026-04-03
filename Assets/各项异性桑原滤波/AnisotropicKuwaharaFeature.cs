using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class AnisotropicKuwaharaFeature : ScriptableRendererFeature
{
    [System.Serializable]
    public class Settings
    {
        public Shader kuwaharaShader;

        [Range(2, 20)]     public int   kernelSize   = 6;
        [Range(1f, 18f)]   public float sharpness    = 8f;
        [Range(1f, 100f)]  public float hardness     = 8f;
        [Range(0.01f, 2f)] public float alpha        = 1f;
        [Range(0.01f, 2f)] public float zeroCrossing = 0.58f;

        public bool useZeta = false;
        [Range(0.01f, 3f)] public float zeta         = 1f;

        [Range(1, 4)] public int passes = 1;

        public RenderPassEvent renderPassEvent = RenderPassEvent.BeforeRenderingPostProcessing;
    }

    public Settings settings = new Settings();
    private AKPass _pass;

    public override void Create()
    {
        _pass = new AKPass(settings) { renderPassEvent = settings.renderPassEvent };
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData rd)
    {
        if (settings.kuwaharaShader == null) return;
        if (rd.cameraData.cameraType == CameraType.Preview) return;
        renderer.EnqueuePass(_pass);
    }

    // SetupRenderPasses 是访问 cameraColorTargetHandle 的唯一合法时机
    public override void SetupRenderPasses(ScriptableRenderer renderer, in RenderingData rd)
    {
        if (rd.cameraData.cameraType == CameraType.Preview) return;
        _pass.Setup(renderer.cameraColorTargetHandle);
    }

    protected override void Dispose(bool disposing) => _pass?.Dispose();

    // ═══════════════════════════════════════════════════════════════════════
    private class AKPass : ScriptableRenderPass
    {
        // Shader 属性 ID
        static readonly int P_KernelSize   = Shader.PropertyToID("_KernelSize");
        static readonly int P_N            = Shader.PropertyToID("_N");
        static readonly int P_Q            = Shader.PropertyToID("_Q");
        static readonly int P_Hardness     = Shader.PropertyToID("_Hardness");
        static readonly int P_Alpha        = Shader.PropertyToID("_Alpha");
        static readonly int P_ZeroCrossing = Shader.PropertyToID("_ZeroCrossing");
        static readonly int P_Zeta         = Shader.PropertyToID("_Zeta");
        static readonly int P_TFM          = Shader.PropertyToID("_TFM");

        // GetTemporaryRT 使用的名称 ID（与 Shader 属性无关，只是 RT 句柄）
        static readonly int RT_Src    = Shader.PropertyToID("_AK_Src");
        static readonly int RT_ST     = Shader.PropertyToID("_AK_ST");
        static readonly int RT_Eigen1 = Shader.PropertyToID("_AK_Eigen1");
        static readonly int RT_Eigen2 = Shader.PropertyToID("_AK_Eigen2");
        static readonly int[] RT_KW   =
        {
            Shader.PropertyToID("_AK_KW0"),
            Shader.PropertyToID("_AK_KW1"),
            Shader.PropertyToID("_AK_KW2"),
            Shader.PropertyToID("_AK_KW3"),
        };

        readonly Settings _s;
        readonly Material _mat;
        RTHandle          _camColor;   // 每帧由 Setup() 刷新

        public AKPass(Settings s)
        {
            _s               = s;
            _mat             = CoreUtils.CreateEngineMaterial(s.kuwaharaShader);
            profilingSampler = new ProfilingSampler("AnisotropicKuwahara");
        }

        public void Setup(RTHandle camColor) => _camColor = camColor;

        public override void Execute(ScriptableRenderContext ctx, ref RenderingData rd)
        {
            if (_mat == null || _camColor == null) return;

            var desc = rd.cameraData.cameraTargetDescriptor;
            int w = desc.width, h = desc.height;

            // 中间 RT 用高精度浮点，输出 RT 与相机格式一致
            var floatDesc = new RenderTextureDescriptor(w, h, RenderTextureFormat.ARGBFloat,  0, 0);
            var colorDesc = new RenderTextureDescriptor(w, h, desc.colorFormat, 0, 0);

            int passCount = Mathf.Clamp(_s.passes, 1, 4);

            var cmd = CommandBufferPool.Get("AnisotropicKuwahara");
            using (new ProfilingScope(cmd, profilingSampler))
            {
                // ── 申请临时 RT ──────────────────────────────────────────────
                cmd.GetTemporaryRT(RT_Src,    colorDesc, FilterMode.Bilinear);
                cmd.GetTemporaryRT(RT_ST,     floatDesc, FilterMode.Bilinear);
                cmd.GetTemporaryRT(RT_Eigen1, floatDesc, FilterMode.Bilinear);
                cmd.GetTemporaryRT(RT_Eigen2, floatDesc, FilterMode.Bilinear);
                for (int i = 0; i < passCount; i++)
                    cmd.GetTemporaryRT(RT_KW[i], colorDesc, FilterMode.Bilinear);

                // ── 构造 RenderTargetIdentifier（显式，避免 int 隐式转换歧义）──
                var id_Src    = new RenderTargetIdentifier(RT_Src);
                var id_ST     = new RenderTargetIdentifier(RT_ST);
                var id_Eigen1 = new RenderTargetIdentifier(RT_Eigen1);
                var id_Eigen2 = new RenderTargetIdentifier(RT_Eigen2);
                var id_KW     = new RenderTargetIdentifier[passCount];
                for (int i = 0; i < passCount; i++)
                    id_KW[i]  = new RenderTargetIdentifier(RT_KW[i]);

                // ── Shader 参数 ──────────────────────────────────────────────
                float zeta = _s.useZeta ? _s.zeta : 2.0f / (_s.kernelSize / 2.0f);
                _mat.SetInt  (P_KernelSize,   _s.kernelSize);
                _mat.SetInt  (P_N,            8);
                _mat.SetFloat(P_Q,            _s.sharpness);
                _mat.SetFloat(P_Hardness,     _s.hardness);
                _mat.SetFloat(P_Alpha,        _s.alpha);
                _mat.SetFloat(P_ZeroCrossing, _s.zeroCrossing);
                _mat.SetFloat(P_Zeta,         zeta);

                // ── 复制相机画面到 Src RT（兼容 backbuffer，不能直接读相机目标）
                cmd.Blit(_camColor.nameID, id_Src);

                // ── Pass 0 : Structure Tensor ────────────────────────────────
                cmd.Blit(id_Src, id_ST, _mat, 0);

                // ── Pass 1 : Blur H ──────────────────────────────────────────
                cmd.Blit(id_ST, id_Eigen1, _mat, 1);

                // ── Pass 2 : Blur V + Eigenvectors ───────────────────────────
                cmd.Blit(id_Eigen1, id_Eigen2, _mat, 2);

                // 用 RenderTargetIdentifier 绑定 TFM，不能传 int，否则 D3D12 绑 NULL
                cmd.SetGlobalTexture(P_TFM, id_Eigen2);

                // ── Pass 3 : Anisotropic Kuwahara ────────────────────────────
                cmd.Blit(id_Src, id_KW[0], _mat, 3);
                for (int i = 1; i < passCount; i++)
                    cmd.Blit(id_KW[i - 1], id_KW[i], _mat, 3);

                // ── 写回相机颜色缓冲 ─────────────────────────────────────────
                cmd.Blit(id_KW[passCount - 1], _camColor.nameID);

                // ── 释放临时 RT（随 CommandBuffer 执行后立即回池，零泄漏）───────
                cmd.ReleaseTemporaryRT(RT_Src);
                cmd.ReleaseTemporaryRT(RT_ST);
                cmd.ReleaseTemporaryRT(RT_Eigen1);
                cmd.ReleaseTemporaryRT(RT_Eigen2);
                for (int i = 0; i < passCount; i++)
                    cmd.ReleaseTemporaryRT(RT_KW[i]);
            }

            ctx.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        public override void OnCameraCleanup(CommandBuffer cmd) { }
        public void Dispose() => CoreUtils.Destroy(_mat);
    }
}
