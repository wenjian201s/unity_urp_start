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
