using UnityEngine;
using UnityEditor;

[ExecuteInEditMode]
[RequireComponent(typeof(Camera))]
[AddComponentMenu("Image Effects/Glitch Art Effect (Realistic CRT)")]
public class GlitchArtEffect : MonoBehaviour
{
    // 材质引用
    private Material _material;
    
    // 故障纹理（用于数据注入）
    [Header("Fault Injection Texture")]
    [Tooltip("Texture containing error messages, code snippets, or glitch patterns")]
    public Texture2D glitchTexture;
    
    // 效果强度参数
    [Header("Global Settings")]
    [Range(0f, 1f)]
    [Tooltip("Overall effect intensity")]
    public float overallIntensity = 0.8f;
    
    [Header("Horizontal Banding")]
    [Tooltip("Intensity of horizontal band interference")]
    [Range(0f, 1f)]
    public float horizontalBanding = 0.75f;
    
    [Tooltip("Frequency of bands (higher = more bands)")]
    [Range(0.1f, 5f)]
    public float bandingFrequency = 2.5f;
    
    [Header("Pixel Block Distortion")]
    [Tooltip("Size of pixel blocks (higher = larger blocks)")]
    [Range(1f, 32f)]
    public float pixelBlockSize = 8f;
    
    [Tooltip("Intensity of block displacement")]
    [Range(0f, 3f)]
    public float pixelBlockJitter = 1.2f;
    
    [Header("Data Injection")]
    [Tooltip("Intensity of data corruption (code/characters replacing image)")]
    [Range(0f, 1f)]
    public float dataInjection = 0.4f;
    
    [Tooltip("Threshold for data injection (lower = more frequent)")]
    [Range(0.01f, 0.2f)]
    public float dataThreshold = 0.08f;
    
    [Header("Signal Loss")]
    [Tooltip("Intensity of signal dropouts (black/white areas)")]
    [Range(0f, 1f)]
    public float signalLoss = 0.35f;
    
    [Tooltip("Threshold for signal loss (lower = more frequent)")]
    [Range(0.01f, 0.3f)]
    public float lossThreshold = 0.1f;
    
    [Header("Classic CRT Effects")]
    [Tooltip("X: Displacement amount, Y: Threshold for applying jitter")]
    public Vector2 scanLineJitter = new Vector2(0.02f, 0.65f);
    
    [Header("Vertical Jump")]
    [Tooltip("X: Jump intensity (0-1), Y: Time speed")]
    public Vector2 verticalJump = new Vector2(0.0f, 1.5f); // 默认禁用
    
    [Header("Horizontal Shake")]
    [Range(0f, 0.1f)]
    public float horizontalShake = 0.015f;
    
    [Header("Color Drift")]
    [Tooltip("X: Color separation amount, Y: Time speed")]
    public Vector2 colorDrift = new Vector2(0.05f, 2.0f);
    
    // 内部时间变量
    private float _currentTime;
    
    // Shader属性ID缓存
    private static readonly int MainTexID = Shader.PropertyToID("_MainTex");
    private static readonly int GlitchTexID = Shader.PropertyToID("_GlitchTex");
    private static readonly int ScanLineJitterID = Shader.PropertyToID("_ScanLineJitter");
    private static readonly int VerticalJumpID = Shader.PropertyToID("_VerticalJump");
    private static readonly int HorizontalShakeID = Shader.PropertyToID("_HorizontalShake");
    private static readonly int ColorDriftID = Shader.PropertyToID("_ColorDrift");
    private static readonly int PixelBlockSizeID = Shader.PropertyToID("_PixelBlockSize");
    private static readonly int PixelBlockJitterID = Shader.PropertyToID("_PixelBlockJitter");
    private static readonly int PixelBlockTimeID = Shader.PropertyToID("_PixelBlockTime");
    private static readonly int HorizontalBandingID = Shader.PropertyToID("_HorizontalBanding");
    private static readonly int BandingFrequencyID = Shader.PropertyToID("_BandingFrequency");
    private static readonly int BandingTimeID = Shader.PropertyToID("_BandingTime");
    private static readonly int DataInjectionID = Shader.PropertyToID("_DataInjection");
    private static readonly int DataThresholdID = Shader.PropertyToID("_DataThreshold");
    private static readonly int DataTimeID = Shader.PropertyToID("_DataTime");
    private static readonly int SignalLossID = Shader.PropertyToID("_SignalLoss");
    private static readonly int LossThresholdID = Shader.PropertyToID("_LossThreshold");
    private static readonly int LossTimeID = Shader.PropertyToID("_LossTime");
    private static readonly int OverallIntensityID = Shader.PropertyToID("_OverallIntensity");

    private void Start()
    {
        if (!SystemInfo.supportsImageEffects)
        {
            enabled = false;
            return;
        }
        CreateMaterial();
        
        // 如果没有指定故障纹理，创建一个默认的
        if (glitchTexture == null)
        {
            CreateDefaultGlitchTexture();
        }
    }
    
    private void OnEnable()
    {
        CreateMaterial();
    }
    
    private void OnDisable()
    {
        DestroyMaterial();
    }
    
    private void CreateMaterial()
    {
        if (_material == null)
        {
            var shader = Shader.Find("lcl/screenEffect/GlitchArt");
            if (shader == null)
            {
                Debug.LogError("Shader 'lcl/screenEffect/GlitchArt' not found! Disabling effect.");
                enabled = false;
                return;
            }
            
            _material = new Material(shader);
            _material.hideFlags = HideFlags.HideAndDontSave;
        }
    }
    
    private void DestroyMaterial()
    {
        if (_material)
        {
            DestroyImmediate(_material);
            _material = null;
        }
    }
    
    private void CreateDefaultGlitchTexture()
    {
        // 创建一个简单的故障纹理（包含随机代码图案）
        int size = 128;
        glitchTexture = new Texture2D(size, size, TextureFormat.RGBA32, false);
        glitchTexture.wrapMode = TextureWrapMode.Repeat;
        
        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                // 生成类似代码的图案
                float value = Mathf.Sin(x * 0.2f + y * 0.1f) * 0.5f + 0.5f;
                float r = Mathf.PerlinNoise(x * 0.1f, y * 0.1f);
                
                // 70% 绿色（终端风格），30% 随机色
                Color color;
                if (r < 0.7f)
                {
                    color = new Color(0, value, 0, 1); // 绿色
                }
                else
                {
                    color = new Color(r, Mathf.PerlinNoise(y * 0.1f, x * 0.1f), 0, 1);
                }
                
                // 随机黑白字符
                if (Random.value < 0.3f)
                {
                    float charValue = (x % 8 < 4) ? 1.0f : 0.0f;
                    color = new Color(charValue, charValue, charValue, 1);
                }
                
                glitchTexture.SetPixel(x, y, color);
            }
        }
        
        glitchTexture.Apply();
    }

    private void Update()
    {
        if (Application.isPlaying)
        {
            _currentTime += Time.deltaTime;
        }
        else
        {
            _currentTime += Time.unscaledDeltaTime * 0.1f;
        }
    }

    private void OnRenderImage(RenderTexture source, RenderTexture destination)
    {
        if (!_material || !SystemInfo.supportsImageEffects)
        {
            Graphics.Blit(source, destination);
            return;
        }
        
        // 设置纹理
        _material.SetTexture(MainTexID, source);
        if (glitchTexture != null)
        {
            _material.SetTexture(GlitchTexID, glitchTexture);
        }
        else
        {
            // 如果没有故障纹理，使用默认白色纹理
            _material.SetTexture(GlitchTexID, Texture2D.whiteTexture);
        }
        
        // 设置全局强度
        _material.SetFloat(OverallIntensityID, overallIntensity);
        
        // 设置基础故障参数
        _material.SetVector(ScanLineJitterID, scanLineJitter);
        _material.SetVector(VerticalJumpID, new Vector2(verticalJump.x, _currentTime * verticalJump.y));
        _material.SetFloat(HorizontalShakeID, horizontalShake);
        _material.SetVector(ColorDriftID, new Vector2(colorDrift.x, _currentTime * colorDrift.y));
        
        // 设置像素块参数
        _material.SetFloat(PixelBlockSizeID, pixelBlockSize);
        _material.SetFloat(PixelBlockJitterID, pixelBlockJitter);
        _material.SetFloat(PixelBlockTimeID, _currentTime * 0.7f);
        
        // 设置水平条纹参数
        _material.SetFloat(HorizontalBandingID, horizontalBanding);
        _material.SetFloat(BandingFrequencyID, bandingFrequency);
        _material.SetFloat(BandingTimeID, _currentTime * 0.5f);
        
        // 设置数据注入参数
        _material.SetFloat(DataInjectionID, dataInjection);
        _material.SetFloat(DataThresholdID, dataThreshold);
        _material.SetFloat(DataTimeID, _currentTime * 1.2f);
        
        // 设置信号丢失参数
        _material.SetFloat(SignalLossID, signalLoss);
        _material.SetFloat(LossThresholdID, lossThreshold);
        _material.SetFloat(LossTimeID, _currentTime * 0.8f);
        
        // 应用图像效果
        Graphics.Blit(source, destination, _material);
    }
    
    // 编辑器按钮：重置为预设
    #if UNITY_EDITOR
    [ContextMenu("Reset to Realistic CRT Preset")]
    void ResetToRealisticPreset()
    {
        overallIntensity = 0.85f;
        horizontalBanding = 0.8f;
        bandingFrequency = 2.8f;
        pixelBlockSize = 6f;
        pixelBlockJitter = 1.5f;
        dataInjection = 0.45f;
        dataThreshold = 0.07f;
        signalLoss = 0.4f;
        lossThreshold = 0.09f;
        scanLineJitter = new Vector2(0.025f, 0.68f);
        verticalJump = new Vector2(0.0f, 1.5f); // 禁用垂直跳跃
        horizontalShake = 0.018f;
        colorDrift = new Vector2(0.06f, 2.2f);
        
        EditorUtility.SetDirty(this);
    }
    
    [ContextMenu("Reset to Intense Glitch Preset")]
    void ResetToIntensePreset()
    {
        overallIntensity = 0.95f;
        horizontalBanding = 1.0f;
        bandingFrequency = 4.0f;
        pixelBlockSize = 12f;
        pixelBlockJitter = 2.8f;
        dataInjection = 0.6f;
        dataThreshold = 0.12f;
        signalLoss = 0.55f;
        lossThreshold = 0.15f;
        scanLineJitter = new Vector2(0.035f, 0.6f);
        verticalJump = new Vector2(0.1f, 1.0f); // 轻微启用
        horizontalShake = 0.025f;
        colorDrift = new Vector2(0.09f, 2.8f);
        
        EditorUtility.SetDirty(this);
    }
    
    [ContextMenu("Reset to Subtle UI Glitch Preset")]
    void ResetToSubtlePreset()
    {
        overallIntensity = 0.4f;
        horizontalBanding = 0.3f;
        bandingFrequency = 1.5f;
        pixelBlockSize = 4f;
        pixelBlockJitter = 0.6f;
        dataInjection = 0.15f;
        dataThreshold = 0.03f;
        signalLoss = 0.1f;
        lossThreshold = 0.02f;
        scanLineJitter = new Vector2(0.01f, 0.75f);
        verticalJump = new Vector2(0.0f, 0f); // 完全禁用
        horizontalShake = 0.005f;
        colorDrift = new Vector2(0.02f, 1.5f);
        
        EditorUtility.SetDirty(this);
    }
    #endif
}