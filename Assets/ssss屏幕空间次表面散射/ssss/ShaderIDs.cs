using UnityEngine;

public static class ShaderIDs
{
    public static readonly int _MainTex = Shader.PropertyToID("_MainTex");
    public static readonly int _SSSSSourceTex = Shader.PropertyToID("_SSSSSourceTex");
    public static readonly int _SSSOriginalTex = Shader.PropertyToID("_SSSOriginalTex");
    public static readonly int _Kernel = Shader.PropertyToID("_Kernel");
    public static readonly int _SampleCount = Shader.PropertyToID("_SampleCount");
    public static readonly int _SSSScale = Shader.PropertyToID("_SSSScale");
    public static readonly int _SSSDepthEdgeFalloff = Shader.PropertyToID("_SSSDepthEdgeFalloff");
    public static readonly int _SSSProjectionDistance = Shader.PropertyToID("_SSSProjectionDistance");
    public static readonly int _SourceTexelSize = Shader.PropertyToID("_SourceTexelSize");
    public static readonly int _StencilRef = Shader.PropertyToID("_StencilRef");
}
