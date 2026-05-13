using System.Collections; // 作用：引入非泛型集合命名空间；原理：Unity 老代码中常保留该引用，用于兼容 ArrayList、Hashtable 等集合类型。
using System.Collections.Generic; // 作用：引入泛型集合命名空间；原理：本脚本使用 Dictionary 和 Queue 管理光源与 Mesh 池。
using UnityEngine; // 作用：引入 Unity 核心 API；原理：Camera、Mesh、Vector、Color、MonoBehaviour 等类型都来自这里。
using System; // 作用：引入 C# 基础系统命名空间；原理：保留给 Serializable、基础类型或后续扩展使用。
using UnityEngine.Rendering; // 作用：引入 Unity 渲染管线 API；原理：RenderPipelineManager.endCameraRendering 需要该命名空间。

#if UNITY_EDITOR // 作用：限定下面代码只在 Unity 编辑器中编译；原理：避免 UnityEditor API 被打进最终游戏包。
using UnityEditor; // 作用：引入 Unity 编辑器扩展 API；原理：CustomEditor、EditorGUILayout、Editor 等编辑器类都在这里。
#endif // 作用：结束编辑器专用代码块；原理：预处理器会根据是否在编辑器环境决定是否编译中间代码。
/// <summary>
/// 光晕当前的淡入淡出状态。
/// 
/// 作用：
/// 控制每个光源对应的 Lens Flare 当前应该显示、淡入、淡出，还是完全不渲染。
/// 
/// 原理：
/// 镜头光晕不是突然出现和消失，
/// 而是根据光源是否可见、是否在屏幕内、是否被遮挡，
/// 平滑地改变 flareScale，实现淡入淡出效果。
/// </summary>
public enum FadeState // 作用：定义镜头光晕淡入淡出状态；原理：用枚举代替数字，让状态机逻辑更清晰。
{ // 作用：开始 FadeState 枚举体；原理：枚举成员必须写在大括号内部。
    Render = 0, // 作用：表示正常渲染状态；原理：此时 flareScale 通常为 1，光晕完全显示。
    FadeIn = 1, // 作用：表示淡入状态；原理：光源变得可见后，flareScale 会从 0 逐渐增加到 1。
    FadeOut = 2, // 作用：表示淡出状态；原理：光源被遮挡或离屏后，flareScale 会从 1 逐渐减少到 0。
    Unrendered = 3 // 作用：表示完全不渲染状态；原理：光晕不可见时跳过位置计算或释放活跃检测槽位。
} // 作用：结束 FadeState 枚举体；原理：枚举定义到此结束。

public class FlareStatusData // 作用：保存单个光源的运行时光晕状态；原理：每个 MFFlareLauncher 对应一个 FlareStatusData。
{ // 作用：开始 FlareStatusData 类体；原理：类字段和运行时缓存数据写在大括号内部。
    public Vector3 sourceCoordinate; // 作用：保存光源屏幕坐标；原理：Camera.WorldToScreenPoint 会返回 x/y 像素坐标和 z 深度。
    public Vector3[] flareWorldPosCenter; // 作用：保存每个光晕块的屏幕中心点；原理：Lens Flare 由多个 Quad 沿屏幕中心线排列。
    public float flareScale; // 作用：保存整体淡入淡出比例；原理：0 表示不可见，1 表示完全可见，可影响缩放或透明度。
    public bool isInScreen; // 作用：记录光源是否在屏幕范围内；原理：根据 sourceCoordinate 是否落在 Camera.pixelRect 内判断。
    public bool isVisible; // 作用：记录光源是否真正可见；原理：需要同时满足在屏幕内且未被深度图中的物体遮挡。
    public FadeState fadeState; // 作用：记录当前淡入淡出状态；原理：Update 中根据可见性切换 Render、FadeIn、FadeOut、Unrendered。
    public Vector4 sourceScreenPos; // 作用：保存传给 Shader 的光源屏幕信息；原理：xy 为 0~1 屏幕 UV，w 可标记方向光。
    public Mesh flareMesh; // 作用：保存该光源对应的光晕 Mesh；原理：多个光晕 Quad 合并成一个 Mesh 后一次 DrawMesh 绘制。
    public Vector3[] vertices; // 作用：保存 Mesh 顶点；原理：每个光晕块是一个 Quad，每个 Quad 需要 4 个顶点。
    public Vector2[] uv; // 作用：保存 Mesh UV；原理：UV 指定每个 Quad 从光晕图集的哪个区域采样。
    public Color[] vertColor; // 作用：保存顶点颜色；原理：颜色会传入 Shader，用于控制每个光晕块的颜色、亮度和透明度。
    public int[] triangle; // 作用：保存 Mesh 三角形索引；原理：一个 Quad 由两个三角形组成，每个 Quad 需要 6 个索引。
    public int srcIndex; // 作用：保存遮挡检测槽位编号；原理：ComputeBuffer 固定 8 个槽位，-1 表示未参与检测。
} // 作用：结束 FlareStatusData 类体；原理：该类运行时数据定义到此结束。


/// <summary>
/// MFLensFlare 是镜头光晕系统的主控制器。
/// 
/// 使用方式：
/// 通常挂在主相机 MainCamera 上。
/// 
/// 作用：
/// 1. 管理场景中所有 MFFlareLauncher 光源
/// 2. 计算光源屏幕位置
/// 3. 判断光源是否在屏幕内
/// 4. 通过深度图判断光源是否被遮挡
/// 5. 控制镜头光晕淡入淡出
/// 6. 动态构建 Mesh
/// 7. 使用 Graphics.DrawMesh 绘制光晕
/// </summary>
public class MFLensFlare : MonoBehaviour // 作用：定义镜头光晕主控制器；原理：继承 MonoBehaviour 后可挂在 Camera 上逐帧运行。
{ // 作用：开始 MFLensFlare 类体；原理：字段、生命周期函数和渲染逻辑都写在这里。
    private static readonly int PIPELINE_DEPTH_TEX = Shader.PropertyToID("_CameraDepthTexture"); // 作用：缓存相机深度图属性 ID；原理：用 int ID 比每帧字符串查找更高效。
    private static readonly int Z_BUFFER_PARAMS = Shader.PropertyToID("_ZBufferParams"); // 作用：缓存 Unity 深度线性化参数 ID；原理：_ZBufferParams 用于把非线性深度还原为线性深度。
    private static readonly string CAMERA_COMPARE_TAG = "MainCamera"; // 作用：指定只处理主相机；原理：SRP 回调会对多个相机触发，用 Tag 过滤避免重复计算。

    public bool DebugMode; // 作用：控制是否输出调试信息；原理：为 true 时打印日志并绘制调试线，方便排查光晕位置。
    [Space(10)] // 作用：在 Inspector 中增加间隔；原理：Unity 属性特性会影响 Inspector 字段排版。
    public Material material; // 作用：指定绘制光晕的材质；原理：Graphics.DrawMesh 需要材质决定透明混合、贴图采样和顶点色计算。
    public float fadeoutTime = 0.25f; // 作用：控制淡入淡出时间；原理：flareScale 每帧按 Time.deltaTime / fadeoutTime 变化。
    public ComputeShader cs_PrepareLightOcclusion; // 作用：指定遮挡检测 Compute Shader；原理：GPU 读取深度图中光源位置的深度并写入 Buffer。

    private Dictionary<MFFlareLauncher, FlareStatusData> _flareDict; // 作用：保存全部注册光源；原理：用 Launcher 作为 Key 可以快速找到对应运行时数据。
    private Dictionary<MFFlareLauncher, FlareStatusData> _activeFlareDict; // 作用：保存当前参与遮挡检测的光源；原理：只有活跃光源占用 ComputeBuffer 槽位。
    private Camera _camera; // 作用：缓存当前相机；原理：屏幕坐标转换、ScreenToWorldPoint 和 DrawMesh 都依赖 Camera。
    private Vector2 _halfScreen; // 作用：保存屏幕中心像素坐标；原理：Lens Flare 光斑沿“光源位置与屏幕中心”连线分布。
    private MaterialPropertyBlock _propertyBlock; // 作用：为每次绘制传递独立材质参数；原理：避免复制材质实例，降低内存和性能开销。
    private Vector3 _screenCenter; // 作用：保存 Mesh 绘制中心点；原理：顶点用相对偏移保存，DrawMesh 时把 Mesh 放到该世界位置。
    private Queue<Mesh> _meshPool; // 作用：缓存可复用 Mesh；原理：减少运行时频繁 new Mesh 和 Destroy Mesh 产生的开销。

    private static readonly int STATIC_FLARESCREENPOS = Shader.PropertyToID("_FlareScreenPos"); // 作用：缓存 Shader 光源屏幕位置参数；原理：材质属性块通过该 ID 传递 Vector4。
    private static readonly int STATIC_BaseMap = Shader.PropertyToID("_MainTex"); // 作用：缓存 Shader 主贴图参数；原理：材质通过 _MainTex 采样光晕图集。
    private static readonly float DISTANCE = 1f; // 作用：指定屏幕点转世界点的深度距离；原理：ScreenToWorldPoint 的 z 表示离相机的距离。

    private int _csKernel; // 作用：保存 Compute Shader Kernel 编号；原理：Dispatch 前必须知道要执行哪个 kernel。
    private ComputeBuffer _cbLightOcclusionCheckBuffer; // 作用：保存 GPU 写出的线性深度结果；原理：Compute Shader 写 Buffer，CPU 通过 GetData 读回。
    private ComputeBuffer _cbLightUVBuffer; // 作用：保存传给 GPU 的光源屏幕像素坐标；原理：Compute Shader 用这些坐标访问深度纹理。

    public struct ScreenSpaceUV // 作用：定义光源屏幕像素坐标结构；原理：结构布局需要和 Compute Shader 中 LightUV 对应。
    { // 作用：开始 ScreenSpaceUV 结构体；原理：x/y 字段会连续存入 ComputeBuffer。
        public int x; // 作用：保存屏幕像素 x 坐标；原理：Texture2D[] 整数索引需要像素坐标而不是 0~1 UV。
        public int y; // 作用：保存屏幕像素 y 坐标；原理：Compute Shader 用 x/y 直接读取深度图对应像素。
    } // 作用：结束 ScreenSpaceUV 结构体；原理：该结构体总大小为两个 int。

    private ScreenSpaceUV[] _screenSpaceLightSrcUV; // 作用：CPU 端保存 8 个光源采样坐标；原理：SetData 会把数组上传到 ComputeBuffer。
    private float[] _lightSourceDepth = // 作用：CPU 端保存 8 个深度检测结果；原理：GetData 会把 GPU 计算后的线性深度读回这里。
    { // 作用：开始初始化深度数组；原理：数组长度对应 8 个遮挡检测槽位。
        1.0f, 1.0f, 1.0f, 1.0f, // 作用：初始化前四个槽位；原理：默认值避免未写入时出现随机数据。
        1.0f, 1.0f, 1.0f, 1.0f // 作用：初始化后四个槽位；原理：总共支持 8 个活跃检测槽位。
    }; // 作用：结束深度数组初始化；原理：数组创建完成。
    private Queue<int> _emptyIndex = new Queue<int>(); // 作用：保存空闲槽位编号；原理：光源激活时 Dequeue，失活时 Enqueue 归还。

    private static readonly int CS_LIGHT_UV = Shader.PropertyToID("_LightUV"); // 作用：缓存 Compute Shader 坐标 Buffer 参数 ID；原理：SetBuffer 使用 ID 绑定数据。
    private static readonly int CS_IS_LIGHT_OCCLUDED = Shader.PropertyToID("_LightSourceDepth"); // 作用：缓存 Compute Shader 深度结果 Buffer 参数 ID；原理：GPU 通过该 Buffer 写出线性深度。
    private static readonly int CS_DEPTHTEX_NAME = Shader.PropertyToID("_DepthTex"); // 作用：缓存 Compute Shader 深度纹理参数 ID；原理：GPU 从该纹理读取相机深度。
    private static readonly int Z_BUFFER_DELIVERED = Shader.PropertyToID("_ZBufferDelivered"); // 作用：缓存传给 Compute Shader 的 ZBuffer 参数 ID；原理：用于深度线性化公式。

#if UNITY_EDITOR // 作用：下面属性只给编辑器调试用；原理：最终打包时不需要暴露这些调试数据。
    public Dictionary<MFFlareLauncher, FlareStatusData> FlareDict => _flareDict; // 作用：给 Inspector 读取全部光源；原理：表达式属性返回内部字典引用。
    public Dictionary<MFFlareLauncher, FlareStatusData> ActiveDict => _activeFlareDict; // 作用：给 Inspector 读取活跃光源；原理：调试面板需要显示当前参与遮挡检测的对象。
    public float[] Editor_LightSrcDepth => _lightSourceDepth; // 作用：给 Inspector 读取深度结果；原理：用于对比深度图读数和光源真实距离。
#endif // 作用：结束编辑器调试属性区域；原理：预处理器控制编译范围。
    /// <summary>
    /// Awake 在脚本初始化时调用。
    /// 
    /// 作用：
    /// 1. 获取 Camera
    /// 2. 初始化字典
    /// 3. 初始化 Mesh 池
    /// 4. 查找 Compute Shader Kernel
    /// 5. 创建 ComputeBuffer
    /// 6. 注册渲染管线回调
    /// 7. 初始化 8 个遮挡检测槽位
    /// </summary>
    private void Awake() // 作用：初始化系统；原理：Unity 会在脚本启用时、Start 前调用 Awake。
    { // 作用：开始 Awake 方法；原理：初始化代码写在方法体内。
        _camera = GetComponent<Camera>(); // 作用：获取当前相机组件；原理：该脚本设计为挂在 Camera 物体上。
        _propertyBlock = new MaterialPropertyBlock(); // 作用：创建材质属性块；原理：同一个材质可在每次绘制时传不同参数。
        _flareDict = new Dictionary<MFFlareLauncher, FlareStatusData>(); // 作用：初始化总光源字典；原理：后续 AddLight 会向其中注册光源。
        _activeFlareDict = new Dictionary<MFFlareLauncher, FlareStatusData>(); // 作用：初始化活跃光源字典；原理：只记录占用遮挡检测槽位的光源。
        _meshPool = new Queue<Mesh>(); // 作用：初始化 Mesh 池；原理：Queue 方便先进先出地复用 Mesh。

        if (cs_PrepareLightOcclusion != null) // 作用：检查 Compute Shader 是否绑定；原理：避免空引用调用 FindKernel。
        { // 作用：开始 if 代码块；原理：只有条件为真才执行内部语句。
            _csKernel = cs_PrepareLightOcclusion.FindKernel("PrepareLightOcclusion"); // 作用：查找 Kernel ID；原理：Unity 通过 kernel 名称定位 GPU 入口函数。
        } // 作用：结束 if 代码块；原理：Compute Shader 初始化判断完成。

        _cbLightOcclusionCheckBuffer = new ComputeBuffer(8, sizeof(float), ComputeBufferType.Structured); // 作用：创建深度结果 Buffer；原理：8 个 float 对应 8 个活跃光源槽位。
        _cbLightUVBuffer = new ComputeBuffer(8, sizeof(int) * 2, ComputeBufferType.Structured); // 作用：创建屏幕坐标 Buffer；原理：每个元素包含两个 int，对应 x/y 像素坐标。
        RenderPipelineManager.endCameraRendering += AddRenderPass; // 作用：注册相机渲染结束事件；原理：深度图在相机渲染后才可用于遮挡检测。
        _screenSpaceLightSrcUV = new ScreenSpaceUV[8]; // 作用：创建 CPU 端坐标数组；原理：长度与 ComputeBuffer 的 8 个槽位一致。

        for (int i = 0; i < 8; i++) // 作用：初始化 8 个遮挡检测槽位；原理：固定容量系统用 0~7 表示可用槽位。
        { // 作用：开始 for 循环体；原理：循环体会执行 8 次。
            _emptyIndex.Enqueue(i); // 作用：把槽位加入空闲队列；原理：后续光源激活时从队列取出可用编号。
            _screenSpaceLightSrcUV[i] = new ScreenSpaceUV { x = 0, y = 0 }; // 作用：初始化槽位坐标；原理：避免未初始化数据传入 GPU。
        } // 作用：结束 for 循环体；原理：8 个槽位初始化完成。
    } // 作用：结束 Awake 方法；原理：初始化阶段完成。
    
    
    /// <summary>
    /// OnDisable 在脚本禁用时调用。
    /// 
    /// 作用：
    /// 1. 取消渲染管线事件注册
    /// 2. 释放 ComputeBuffer
    /// 
    /// 原理：
    /// ComputeBuffer 是 GPU 资源，必须手动 Release。
    /// 否则可能造成显存泄漏。
    /// </summary>
    private void OnDisable() // 作用：禁用时清理资源；原理：Unity 在组件禁用或对象销毁前调用该方法。
    { // 作用：开始 OnDisable 方法；原理：资源释放语句写在方法体内。
        RenderPipelineManager.endCameraRendering -= AddRenderPass; // 作用：取消渲染回调；原理：避免组件禁用后回调仍然访问无效对象。
        _cbLightOcclusionCheckBuffer?.Release(); // 作用：释放深度结果 Buffer；原理：ComputeBuffer 是 GPU 资源，必须手动释放。
        _cbLightUVBuffer?.Release(); // 作用：释放坐标 Buffer；原理：防止显存泄漏。
    } // 作用：结束 OnDisable 方法；原理：禁用清理完成。

    
    /// <summary>
    /// 为一个 MFFlareLauncher 初始化对应的 FlareStatusData。
    /// 
    /// 作用：
    /// 当某个光源注册进 Lens Flare 系统时，
    /// 根据它使用的光晕资源 asset 创建运行时数据。
    /// 
    /// 主要做两件事：
    /// 1. 创建 Mesh 顶点、UV、颜色、三角形数组
    /// 2. 根据每个 spriteBlock 的 block Rect 初始化 UV 和 triangle
    /// </summary>
    private FlareStatusData InitFlareData(MFFlareLauncher mfFlareLauncher) // 作用：为一个光源创建运行时数据；原理：根据资源中光晕块数量分配 Mesh 数组。
    { // 作用：开始 InitFlareData 方法；原理：方法体内完成数据创建。
        int flareCount = mfFlareLauncher.asset.spriteBlocks.Count; // 作用：获取光晕块数量；原理：每个 spriteBlock 对应一个 Quad。
        FlareStatusData statusData = new FlareStatusData // 作用：创建状态对象；原理：对象初始化器可一次性设置多个字段。
        { // 作用：开始对象初始化器；原理：内部每行设置一个字段初始值。
            sourceCoordinate = Vector3.zero, // 作用：初始化屏幕坐标；原理：Vector3.zero 表示还未计算有效坐标。
            flareWorldPosCenter = new Vector3[flareCount], // 作用：创建光晕块中心点数组；原理：数组长度等于光晕块数量。
            flareScale = 0, // 作用：初始不可见；原理：光晕应通过 FadeIn 从 0 逐渐显示。
            fadeState = FadeState.Render, // 作用：设置初始状态；原理：后续 Update 会立刻根据可见性修正状态。
            sourceScreenPos = Vector4.zero, // 作用：初始化 Shader 屏幕参数；原理：零向量代表没有有效光源屏幕信息。
            flareMesh = _meshPool.Count > 0 ? _meshPool.Dequeue() : new Mesh(), // 作用：获取 Mesh；原理：优先复用对象池，没有可用 Mesh 才创建新对象。
            vertices = new Vector3[flareCount * 4], // 作用：创建顶点数组；原理：每个 Quad 需要 4 个顶点。
            triangle = new int[flareCount * 6], // 作用：创建三角形索引数组；原理：每个 Quad 由 2 个三角形 6 个索引组成。
            uv = new Vector2[flareCount * 4], // 作用：创建 UV 数组；原理：每个顶点需要一个 UV 坐标。
            vertColor = new Color[flareCount * 4], // 作用：创建顶点颜色数组；原理：每个顶点需要一个颜色用于 Shader 混合。
            srcIndex = -1 // 作用：标记未分配遮挡槽位；原理：-1 是无效索引。
        }; // 作用：结束对象初始化器；原理：statusData 对象创建完成。

        for (int i = 0; i < flareCount; i++) // 作用：遍历所有光晕块；原理：为每个 Quad 预先设置 UV 和三角形索引。
        { // 作用：开始循环体；原理：每次处理一个 spriteBlock。
            Rect rect = mfFlareLauncher.asset.spriteBlocks[i].block; // 作用：读取当前图块 UV 矩形；原理：block 描述该光斑在图集中的采样区域。
            statusData.uv[i * 4] = rect.position; // 作用：设置第 1 个顶点 UV；原理：使用矩形左下角或起始点作为采样坐标。
            statusData.uv[i * 4 + 1] = rect.position + new Vector2(rect.width, 0); // 作用：设置第 2 个顶点 UV；原理：在起点基础上向 U 方向偏移宽度。
            statusData.uv[i * 4 + 2] = rect.position + new Vector2(0, rect.height); // 作用：设置第 3 个顶点 UV；原理：在起点基础上向 V 方向偏移高度。
            statusData.uv[i * 4 + 3] = rect.position + rect.size; // 作用：设置第 4 个顶点 UV；原理：起点加宽高得到矩形对角 UV。
            
            statusData.triangle[i * 6] = i * 4; // 作用：设置第 1 个三角形索引 0；原理：指向当前 Quad 的第 1 个顶点。
            statusData.triangle[i * 6 + 1] = i * 4 + 3; // 作用：设置第 1 个三角形索引 1；原理：指向当前 Quad 的第 4 个顶点。
            statusData.triangle[i * 6 + 2] = i * 4 + 1; // 作用：设置第 1 个三角形索引 2；原理：指向当前 Quad 的第 2 个顶点。
            statusData.triangle[i * 6 + 3] = i * 4; // 作用：设置第 2 个三角形索引 0；原理：两个三角形共享第 1 个顶点。
            statusData.triangle[i * 6 + 4] = i * 4 + 2; // 作用：设置第 2 个三角形索引 1；原理：指向当前 Quad 的第 3 个顶点。
            statusData.triangle[i * 6 + 5] = i * 4 + 3; // 作用：设置第 2 个三角形索引 2；原理：与第 1 个三角形共同拼成矩形 Quad。
        } // 作用：结束循环体；原理：所有 Quad 的静态 UV 和索引设置完成。

        return statusData; // 作用：返回初始化结果；原理：AddLight 会把该数据存入字典。
    } // 作用：结束 InitFlareData 方法；原理：单个光源初始化完成。

    
    /// <summary>
    /// 添加一个光源到 Lens Flare 系统。
    /// 
    /// 通常由 MFFlareLauncher 在 OnEnable 或 Start 中调用。
    /// </summary>
    public void AddLight(MFFlareLauncher mfFlareLauncher) // 作用：注册一个光晕光源；原理：MFFlareLauncher 通常在启用时调用该函数。
    { // 作用：开始 AddLight 方法；原理：注册逻辑写在方法体内。
        if (mfFlareLauncher == null || mfFlareLauncher.asset == null) // 作用：检查输入是否合法；原理：光源或资源为空会导致后续访问空引用。
        { // 作用：开始 if 代码块；原理：条件为真时执行保护返回。
            return; // 作用：停止注册；原理：无效数据不进入系统。
        } // 作用：结束 if 代码块；原理：空引用保护结束。

        if (_flareDict.ContainsKey(mfFlareLauncher)) // 作用：检查是否重复注册；原理：Dictionary 不允许同 Key 重复 Add。
        { // 作用：开始 if 代码块；原理：已存在时跳过。
            return; // 作用：停止重复添加；原理：避免同一光源生成多份运行时数据。
        } // 作用：结束 if 代码块；原理：重复注册保护结束。

        if (DebugMode) // 作用：判断是否输出日志；原理：调试模式下显示注册过程。
        { // 作用：开始 if 代码块；原理：DebugMode 为 true 才执行。
            Debug.Log("Add Light " + mfFlareLauncher.gameObject.name + " to FlareList"); // 作用：输出添加日志；原理：便于确认光源是否成功进入系统。
        } // 作用：结束 if 代码块；原理：调试日志判断结束。

        FlareStatusData flareData = InitFlareData(mfFlareLauncher); // 作用：创建运行时数据；原理：根据光晕资源分配 Mesh 顶点、UV、颜色数组。
        _flareDict.Add(mfFlareLauncher, flareData); // 作用：加入总光源字典；原理：Update 会遍历该字典更新所有光源。
        ActiveLight(mfFlareLauncher, ref flareData); // 作用：尝试激活遮挡检测；原理：活跃光源会占用一个 ComputeBuffer 槽位。
    } // 作用：结束 AddLight 方法；原理：光源注册流程完成。

    
    
    /// <summary>
    /// 将某个光源加入活跃列表。
    /// 
    /// 作用：
    /// 活跃光源会占用一个 ComputeBuffer 槽位，
    /// 用于深度遮挡检测。
    /// </summary>
    public void ActiveLight(MFFlareLauncher mfFlareLauncher, ref FlareStatusData flareData) // 作用：让光源进入活跃检测列表；原理：分配 srcIndex 后才能写入坐标并读取深度。
    { // 作用：开始 ActiveLight 方法；原理：激活逻辑写在方法体内。
        if (_activeFlareDict.ContainsKey(mfFlareLauncher)) // 作用：检查光源是否已经活跃；原理：避免重复占用多个槽位。
        { // 作用：开始 if 代码块；原理：已活跃时返回。
            return; // 作用：停止重复激活；原理：保证一个光源只对应一个 srcIndex。
        } // 作用：结束 if 代码块；原理：重复激活保护结束。

        if (_emptyIndex.Count <= 0) // 作用：检查是否还有空闲槽位；原理：当前系统固定最多 8 个活跃光源。
        { // 作用：开始 if 代码块；原理：没有槽位时执行保护逻辑。
            if (DebugMode) // 作用：判断是否输出警告；原理：调试时提示超过系统上限。
            { // 作用：开始内部 if；原理：DebugMode 为 true 才打印。
                Debug.LogWarning("MFLensFlare active light limit reached. Max active lights = 8."); // 作用：输出上限警告；原理：提醒需要扩展 Buffer 容量或减少活跃光源。
            } // 作用：结束内部 if；原理：警告输出判断完成。

            flareData.srcIndex = -1; // 作用：标记未分配槽位；原理：-1 表示不参与遮挡检测。
            return; // 作用：停止激活；原理：没有槽位无法继续绑定 ComputeBuffer 索引。
        } // 作用：结束 if 代码块；原理：槽位检查完成。

        if (DebugMode) // 作用：判断是否打印激活日志；原理：调试模式下可追踪光源状态变化。
        { // 作用：开始 if 代码块；原理：DebugMode 为 true 执行。
            Debug.Log("Active Light " + mfFlareLauncher.gameObject.name + " to ActiveList"); // 作用：输出激活日志；原理：确认光源进入活跃列表。
        } // 作用：结束 if 代码块；原理：日志判断结束。

        flareData.srcIndex = _emptyIndex.Dequeue(); // 作用：分配一个空闲槽位；原理：队列取出的编号对应 Buffer 中的元素索引。
        _activeFlareDict.Add(mfFlareLauncher, flareData); // 作用：加入活跃字典；原理：调试面板和失活逻辑需要记录活跃光源。
    } // 作用：结束 ActiveLight 方法；原理：光源激活流程完成。

    
    /// <summary>
    /// 从 Lens Flare 系统中移除一个光源。
    /// 
    /// 通常由 MFFlareLauncher 在 OnDisable 或 OnDestroy 中调用。
    /// </summary>
    public void RemoveLight(MFFlareLauncher mfFlareLauncher) // 作用：从系统移除光源；原理：MFFlareLauncher 禁用或销毁时应调用。
    { // 作用：开始 RemoveLight 方法；原理：移除逻辑写在方法体内。
        if (mfFlareLauncher == null) // 作用：检查输入是否为空；原理：避免访问空对象。
        { // 作用：开始 if 代码块；原理：为空时执行保护返回。
            return; // 作用：停止移除；原理：没有有效目标无需处理。
        } // 作用：结束 if 代码块；原理：空引用保护结束。

        InactiveLight(mfFlareLauncher); // 作用：先解除活跃状态；原理：释放它占用的 ComputeBuffer 槽位。

        if (DebugMode) // 作用：判断是否打印移除日志；原理：调试时观察生命周期。
        { // 作用：开始 if 代码块；原理：DebugMode 为 true 执行。
            Debug.Log("Remove Light " + mfFlareLauncher.gameObject.name + " from FlareList"); // 作用：输出移除日志；原理：确认光源离开总列表。
        } // 作用：结束 if 代码块；原理：日志判断结束。

        if (_flareDict.TryGetValue(mfFlareLauncher, out FlareStatusData flareState)) // 作用：查找光源运行时数据；原理：TryGetValue 可避免 Key 不存在时报错。
        { // 作用：开始 if 代码块；原理：找到数据后执行清理。
            if (flareState.flareMesh != null) // 作用：检查 Mesh 是否存在；原理：避免对空 Mesh 调用方法。
            { // 作用：开始内部 if；原理：Mesh 有效时才回收。
                flareState.flareMesh.Clear(); // 作用：清空 Mesh 数据；原理：复用前移除旧顶点、UV、索引和颜色。
                _meshPool.Enqueue(flareState.flareMesh); // 作用：把 Mesh 放回对象池；原理：下次光源注册时可复用，减少分配。
            } // 作用：结束内部 if；原理：Mesh 回收判断完成。

            _flareDict.Remove(mfFlareLauncher); // 作用：从总字典移除光源；原理：Update 不再遍历该光源。
        } // 作用：结束 if 代码块；原理：运行时数据清理完成。
    } // 作用：结束 RemoveLight 方法；原理：光源移除流程完成。

    
    /// <summary>
    /// 将某个光源从活跃遮挡检测列表移除。
    /// 
    /// 作用：
    /// 释放它占用的 srcIndex 槽位。
    /// </summary>
    private void InactiveLight(MFFlareLauncher mfFlareLauncher) // 作用：让光源退出活跃遮挡检测；原理：归还 srcIndex 槽位并移出活跃字典。
    { // 作用：开始 InactiveLight 方法；原理：失活逻辑写在方法体内。
        if (mfFlareLauncher == null) // 作用：检查光源是否为空；原理：空对象不能作为字典 Key 查询。
        { // 作用：开始 if 代码块；原理：为空时返回。
            return; // 作用：停止失活；原理：没有有效对象可处理。
        } // 作用：结束 if 代码块；原理：空引用保护结束。

        if (_activeFlareDict.TryGetValue(mfFlareLauncher, out FlareStatusData flareState)) // 作用：查找活跃数据；原理：只有活跃光源才需要释放槽位。
        { // 作用：开始 if 代码块；原理：找到后执行释放流程。
            if (flareState.srcIndex >= 0) // 作用：检查槽位编号是否有效；原理：-1 表示没有占用槽位。
            { // 作用：开始内部 if；原理：有效槽位才需要归还。
                _emptyIndex.Enqueue(flareState.srcIndex); // 作用：归还槽位；原理：下一个活跃光源可以复用该编号。
            } // 作用：结束内部 if；原理：槽位归还判断完成。

            flareState.srcIndex = -1; // 作用：标记不再占用槽位；原理：防止后续仍使用旧索引访问 Buffer。
            _activeFlareDict.Remove(mfFlareLauncher); // 作用：从活跃字典移除；原理：调试面板和遮挡管理不再把它视为活跃。

            if (DebugMode) // 作用：判断是否打印失活日志；原理：调试时追踪槽位释放。
            { // 作用：开始内部 if；原理：DebugMode 为 true 才执行。
                Debug.Log("Inactive Light " + mfFlareLauncher.gameObject.name + " from FlareList"); // 作用：输出失活日志；原理：确认该光源离开活跃列表。
            } // 作用：结束内部 if；原理：日志判断完成。
        } // 作用：结束 if 代码块；原理：失活查找与释放完成。
    } // 作用：结束 InactiveLight 方法；原理：光源失活流程完成。

    /// <summary>
    /// Update 每帧执行。
    /// 
    /// 作用：
    /// 对每个注册的光源执行：
    /// 1. 计算屏幕坐标
    /// 2. 判断是否在屏幕内
    /// 3. 判断是否可见
    /// 4. 更新淡入淡出状态
    /// 5. 计算每个 flare 光斑位置
    /// 6. 生成 Mesh 并绘制
    /// </summary>
    private void Update() // 作用：每帧更新光晕系统；原理：Unity 每帧调用 Update 以驱动状态变化和绘制。
    { // 作用：开始 Update 方法；原理：每帧逻辑写在方法体内。
        if (_camera == null) // 作用：检查相机是否存在；原理：没有相机无法做屏幕转换和绘制。
        { // 作用：开始 if 代码块；原理：相机为空时保护返回。
            return; // 作用：停止本帧更新；原理：避免空引用。
        } // 作用：结束 if 代码块；原理：相机检查完成。

        _halfScreen = new Vector2(_camera.scaledPixelWidth / 2f + _camera.pixelRect.xMin, _camera.scaledPixelHeight / 2f + _camera.pixelRect.yMin); // 作用：计算相机屏幕中心；原理：考虑 pixelRect 可支持分屏或非全屏相机。
        Transform cameraTransform = _camera.transform; // 作用：缓存相机 Transform；原理：减少重复属性访问。
        _screenCenter = cameraTransform.position + cameraTransform.forward * 0.1f; // 作用：计算 Mesh 世界中心；原理：将光晕 Mesh 放在相机前方近处，顶点再相对偏移。

        foreach (var pair in _flareDict) // 作用：遍历全部注册光源；原理：每帧需要更新每个光源的光晕状态。
        { // 作用：开始 foreach 循环体；原理：循环体每次处理一个光源。
            FlareStatusData flareStatusData = pair.Value; // 作用：取出当前光源状态数据；原理：后续计算会修改其中的状态和 Mesh 数据。
            MFFlareLauncher lightSource = pair.Key; // 作用：取出当前光源组件；原理：需要读取 Transform、asset、directionalLight 等配置。
            
            GetSourceCoordinate(lightSource, ref flareStatusData); // 作用：计算光源屏幕坐标；原理：世界空间位置需要转到屏幕空间才能生成 Lens Flare。
            CheckIn(lightSource, ref flareStatusData); // 作用：判断屏幕内和遮挡状态；原理：深度比较决定光晕是否可见。

            if (flareStatusData.flareScale > 0) // 作用：判断光晕当前是否有显示强度；原理：大于 0 时可能继续显示或淡出。
            { // 作用：开始 if 代码块；原理：处理已显示或半显示状态。
                if (flareStatusData.flareScale >= 1) // 作用：判断是否已经完全显示；原理：flareScale 到达 1 后进入稳定状态。
                { // 作用：开始内部 if；原理：完全显示时只需根据可见性决定保持或淡出。
                    flareStatusData.fadeState = flareStatusData.isVisible ? FadeState.Render : FadeState.FadeOut; // 作用：设置状态；原理：可见则 Render，不可见则 FadeOut。
                } // 作用：结束内部 if；原理：完全显示状态判断完成。
                else // 作用：处理半透明过渡状态；原理：flareScale 位于 0 和 1 之间。
                { // 作用：开始 else 代码块；原理：根据可见性决定继续向哪个方向变化。
                    flareStatusData.fadeState = flareStatusData.isVisible ? FadeState.FadeIn : FadeState.FadeOut; // 作用：设置过渡方向；原理：可见继续淡入，不可见转为淡出。
                } // 作用：结束 else 代码块；原理：半透明状态判断完成。
            } // 作用：结束 if 代码块；原理：已显示状态处理完成。
            else // 作用：处理完全不可见状态；原理：flareScale 为 0 时需要决定是否激活并淡入。
            { // 作用：开始 else 代码块；原理：当前光晕不可见。
                if (!flareStatusData.isInScreen) // 作用：判断光源是否不在屏幕内；原理：离屏光源不需要绘制光晕。
                { // 作用：开始内部 if；原理：离屏时进入不渲染。
                    flareStatusData.fadeState = FadeState.Unrendered; // 作用：设置不渲染状态；原理：后续会释放活跃槽位。
                } // 作用：结束内部 if；原理：离屏判断完成。
                else // 作用：处理在屏幕内但当前不可见强度为 0 的情况；原理：可能需要开始淡入。
                { // 作用：开始 else 代码块；原理：光源在屏幕范围内。
                    if (!_activeFlareDict.TryGetValue(lightSource, out _)) // 作用：检查是否还没有活跃；原理：可见检测需要先占用槽位。
                    { // 作用：开始内部 if；原理：未活跃时分配槽位。
                        ActiveLight(lightSource, ref flareStatusData); // 作用：激活光源；原理：使其进入遮挡检测 Buffer 队列。
                    } // 作用：结束内部 if；原理：活跃检查完成。

                    flareStatusData.fadeState = FadeState.FadeIn; // 作用：设置淡入状态；原理：在屏幕内的光源应从 0 开始显示。
                } // 作用：结束 else 代码块；原理：屏幕内不可见状态处理完成。
            } // 作用：结束 else 代码块；原理：完全不可见状态处理完成。

            if (flareStatusData.fadeState != FadeState.Unrendered) // 作用：判断是否需要计算光晕位置；原理：完全不渲染时可跳过 Mesh 位置计算。
            { // 作用：开始 if 代码块；原理：可渲染或过渡状态才计算位置。
                CalculateMeshData(lightSource, ref flareStatusData); // 作用：计算各个光晕块屏幕位置；原理：沿光源与屏幕中心连线按 offset 分布。
            } // 作用：结束 if 代码块；原理：位置计算判断完成。

            float fadeTime = Mathf.Max(0.0001f, fadeoutTime); // 作用：保护淡入淡出时间；原理：避免 fadeoutTime 为 0 导致除零。

            switch (flareStatusData.fadeState) // 作用：根据状态更新 flareScale；原理：状态机驱动淡入淡出数值变化。
            { // 作用：开始 switch 代码块；原理：每个 case 对应一种状态处理。
                case FadeState.FadeIn: // 作用：处理淡入状态；原理：需要逐渐提高强度。
                    flareStatusData.flareScale += Time.deltaTime / fadeTime; // 作用：增加光晕强度；原理：按时间归一化增量实现帧率无关过渡。
                    flareStatusData.flareScale = Mathf.Clamp01(flareStatusData.flareScale); // 作用：限制强度范围；原理：Clamp01 保证数值在 0~1。
                    break; // 作用：退出当前 case；原理：避免继续执行其他状态分支。
                case FadeState.FadeOut: // 作用：处理淡出状态；原理：需要逐渐降低强度。
                    flareStatusData.flareScale -= Time.deltaTime / fadeTime; // 作用：减少光晕强度；原理：按时间归一化减量实现平滑淡出。
                    flareStatusData.flareScale = Mathf.Clamp01(flareStatusData.flareScale); // 作用：限制强度范围；原理：防止小于 0 或大于 1。
                    break; // 作用：退出当前 case；原理：状态处理完成。
                case FadeState.Unrendered: // 作用：处理不渲染状态；原理：彻底关闭显示并释放活跃槽位。
                    flareStatusData.flareScale = 0; // 作用：强制强度为 0；原理：保证完全不可见。
                    InactiveLight(lightSource); // 作用：让光源失活；原理：归还 ComputeBuffer 槽位给其他光源使用。
                    break; // 作用：退出当前 case；原理：状态处理完成。
                case FadeState.Render: // 作用：处理正常渲染状态；原理：光晕已完全可见。
                    flareStatusData.flareScale = 1; // 作用：强制强度为 1；原理：保持稳定完全显示。
                    break; // 作用：退出当前 case；原理：状态处理完成。
            } // 作用：结束 switch 代码块；原理：flareScale 更新完成。

            CreateMesh(lightSource, ref flareStatusData); // 作用：生成并绘制 Mesh；原理：根据顶点、UV、颜色和材质绘制屏幕空间光晕。

            if (DebugMode) // 作用：判断是否绘制调试线；原理：只在调试模式下显示辅助线。
            { // 作用：开始 if 代码块；原理：DebugMode 为 true 才执行。
                DebugDrawMeshPos(lightSource, flareStatusData); // 作用：绘制光晕位置线；原理：从相机到每个光斑中心画线方便观察分布。
            } // 作用：结束 if 代码块；原理：调试绘制判断完成。
        } // 作用：结束 foreach 循环体；原理：一个光源更新完成，继续下一个。
    } // 作用：结束 Update 方法；原理：本帧所有光源更新完成。

    
    /// <summary>
    /// 计算光源在屏幕上的位置。
    /// 
    /// 点光源 / 聚光灯：
    /// 直接使用 lightSource.transform.position。
    /// 
    /// 方向光：
    /// 方向光没有实际位置，所以使用：
    /// 相机位置 - 光源 forward * 10000
    /// 构造一个非常远的方向点。
    /// 
    /// 原理：
    /// 方向光代表无限远方向的光，
    /// 所以只需要知道方向，不需要真实位置。
    /// </summary>
    private void GetSourceCoordinate(MFFlareLauncher lightSource, ref FlareStatusData statusData) // 作用：计算光源屏幕坐标；原理：Lens Flare 需要在屏幕空间中定位。
    { // 作用：开始 GetSourceCoordinate 方法；原理：屏幕坐标计算写在方法体内。
        Transform lightSourceTransform = lightSource.transform; // 作用：缓存光源 Transform；原理：减少重复访问组件属性。
        Vector3 sourceWorldPosition = lightSource.directionalLight ? _camera.transform.position - lightSourceTransform.forward * 10000f : lightSourceTransform.position; // 作用：确定光源世界位置；原理：方向光无实际位置，所以用远处方向点模拟无限远光源。
        Vector3 sourceScreenPos = _camera.WorldToScreenPoint(sourceWorldPosition); // 作用：世界坐标转屏幕坐标；原理：相机投影矩阵将 3D 位置映射到 2D 屏幕像素。
        statusData.sourceCoordinate = sourceScreenPos; // 作用：保存屏幕坐标；原理：后续在屏幕内判断、光晕排列和遮挡检测都要使用它。
    } // 作用：结束 GetSourceCoordinate 方法；原理：光源屏幕坐标计算完成。

    /// <summary>
    /// 检查光源是否在屏幕范围内，以及是否被遮挡。
    /// 
    /// 主要判断：
    /// 1. 光源屏幕坐标是否超出相机像素范围
    /// 2. 光源是否在相机前方
    /// 3. 光源深度是否被深度纹理中的物体挡住
    /// </summary>
    private void CheckIn(MFFlareLauncher lightSource, ref FlareStatusData statusData) // 作用：判断光源是否在屏幕内且可见；原理：结合屏幕范围、方向和深度遮挡判断。
    { // 作用：开始 CheckIn 方法；原理：可见性检测写在方法体内。
        bool outOfScreen = statusData.sourceCoordinate.x < _camera.pixelRect.xMin || statusData.sourceCoordinate.y < _camera.pixelRect.yMin || statusData.sourceCoordinate.x > _camera.pixelRect.xMax || statusData.sourceCoordinate.y > _camera.pixelRect.yMax; // 作用：判断是否离开屏幕；原理：屏幕像素坐标超出 Camera.pixelRect 就不应显示光晕。
        Vector3 lightDirection = lightSource.directionalLight ? Vector3.Normalize(_camera.transform.position - lightSource.transform.forward * 10000f) : Vector3.Normalize(lightSource.transform.position - _camera.transform.position); // 作用：计算光源方向；原理：用方向与相机 forward 的点积判断是否在相机前方。
        bool behindCamera = Vector3.Dot(lightDirection, _camera.transform.forward) < 0.25f; // 作用：判断是否偏离相机正前方过多；原理：点积越小说明夹角越大，低于阈值认为不可见。

        if (outOfScreen || behindCamera) // 作用：处理屏幕外或相机后方情况；原理：这些情况下光晕应关闭。
        { // 作用：开始 if 代码块；原理：无效位置时执行清空状态。
            statusData.sourceScreenPos = Vector4.zero; // 作用：清空 Shader 屏幕参数；原理：避免 Shader 使用无效光源坐标。
            statusData.isVisible = false; // 作用：标记不可见；原理：离屏或背向时不能产生光晕。
            statusData.isInScreen = false; // 作用：标记不在屏幕内；原理：状态机可据此进入 Unrendered。
            return; // 作用：提前结束检测；原理：不需要再做深度遮挡判断。
        } // 作用：结束 if 代码块；原理：离屏检测处理完成。

        statusData.isInScreen = true; // 作用：标记在屏幕内；原理：通过屏幕范围和方向判断后进入遮挡检测。

        if (statusData.srcIndex == -1) // 作用：判断是否有遮挡检测槽位；原理：没有 srcIndex 就无法读取对应深度结果。
        { // 作用：开始 if 代码块；原理：未激活时无法判断遮挡。
            statusData.isVisible = false; // 作用：暂时标记不可见；原理：等待 ActiveLight 分配槽位后下一帧再判断。
            return; // 作用：提前结束；原理：无有效深度数据可比较。
        } // 作用：结束 if 代码块；原理：槽位检查完成。

        Vector4 screenUV = statusData.sourceCoordinate; // 作用：复制屏幕坐标；原理：接下来将像素坐标转换为 UV。
        screenUV.x /= _camera.pixelWidth; // 作用：转换 x 为 0~1；原理：屏幕 UV = 像素坐标 / 屏幕宽度。
        screenUV.y /= _camera.pixelHeight; // 作用：转换 y 为 0~1；原理：屏幕 UV = 像素坐标 / 屏幕高度。
        screenUV.w = lightSource.directionalLight ? 1 : 0; // 作用：标记方向光；原理：Shader 可根据 w 分量区分方向光和普通光源。
        statusData.sourceScreenPos = screenUV; // 作用：保存 Shader 参数；原理：后续 MaterialPropertyBlock 会把它传入材质。
        float worldSpaceDepth = _lightSourceDepth[statusData.srcIndex]; // 作用：读取深度图中该位置的线性深度；原理：Compute Shader 已把非线性深度转换为线性视深度。

        if (lightSource.directionalLight) // 作用：分支处理方向光；原理：方向光可视为无限远，遮挡判断和点光不同。
        { // 作用：开始方向光分支；原理：使用远裁剪深度判断是否被物体挡住。
            if (worldSpaceDepth >= _camera.farClipPlane - _camera.nearClipPlane) // 作用：判断该像素是否接近远裁剪面；原理：接近远裁剪说明该方向没有场景物体遮挡。
            { // 作用：开始 if 代码块；原理：无遮挡时可见。
                statusData.isVisible = true; // 作用：标记方向光可见；原理：可见状态会驱动光晕淡入或保持显示。
            } // 作用：结束 if 代码块；原理：方向光可见判断完成。
            else // 作用：处理方向光被遮挡情况；原理：深度图出现近处物体。
            { // 作用：开始 else 代码块；原理：被遮挡时关闭可见性。
                statusData.sourceScreenPos = Vector4.zero; // 作用：清空 Shader 屏幕参数；原理：避免被遮挡光源参与 Shader 计算。
                statusData.isVisible = false; // 作用：标记不可见；原理：状态机会让光晕淡出。
            } // 作用：结束 else 代码块；原理：方向光遮挡处理完成。
        } // 作用：结束方向光分支；原理：方向光判断完成。
        else // 作用：分支处理普通光源；原理：普通光源有真实位置和相机距离。
        { // 作用：开始普通光源分支；原理：用深度图深度与光源距离比较。
            float lightDistance = Vector3.Magnitude(lightSource.transform.position - _camera.transform.position) - _camera.nearClipPlane; // 作用：计算光源线性距离；原理：与 LinearEyeDepth 结果对齐时扣除近裁剪偏移。

            if (worldSpaceDepth > lightDistance) // 作用：判断是否无遮挡；原理：深度图最近物体比光源更远，说明光源在前面可见。
            { // 作用：开始 if 代码块；原理：无遮挡时显示光晕。
                statusData.isVisible = true; // 作用：标记普通光源可见；原理：可见状态驱动 FadeIn 或 Render。
            } // 作用：结束 if 代码块；原理：普通光源可见判断完成。
            else // 作用：处理普通光源被遮挡情况；原理：深度图中物体比光源更近。
            { // 作用：开始 else 代码块；原理：遮挡时关闭光晕。
                statusData.sourceScreenPos = Vector4.zero; // 作用：清空 Shader 屏幕参数；原理：防止遮挡光源仍影响材质效果。
                statusData.isVisible = false; // 作用：标记不可见；原理：状态机会让光晕淡出。
            } // 作用：结束 else 代码块；原理：普通光源遮挡处理完成。
        } // 作用：结束普通光源分支；原理：可见性判断完成。
    } // 作用：结束 CheckIn 方法；原理：光源屏幕和遮挡检测完成。
    
    /// <summary>
    /// 准备光源遮挡检测。
    /// 
    /// 作用：
    /// 1. 把当前活跃光源的屏幕像素坐标传入 Compute Shader
    /// 2. 把相机深度图传入 Compute Shader
    /// 3. 把 ZBuffer 参数传入 Compute Shader
    /// 4. Dispatch 计算
    /// 5. 从 GPU 读回每个光源位置处的线性深度
    /// 
    /// 原理：
    /// Compute Shader 读取 _DepthTex 中光源屏幕坐标处的深度，
    /// 然后用 _ZBufferParams 把非线性深度转成线性深度。
    /// </summary>
    private void PrepareLightOcclusion() // 作用：执行光源遮挡深度准备；原理：把屏幕坐标和深度图交给 Compute Shader 计算线性深度。
    { // 作用：开始 PrepareLightOcclusion 方法；原理：GPU 遮挡检测准备写在这里。
        if (cs_PrepareLightOcclusion == null) // 作用：检查 Compute Shader 是否存在；原理：没有 Shader 无法执行 GPU 计算。
        { // 作用：开始 if 代码块；原理：为空时返回。
            return; // 作用：停止遮挡检测；原理：避免空引用。
        } // 作用：结束 if 代码块；原理：Compute Shader 检查完成。

        DeliverUV(); // 作用：准备光源屏幕坐标数组；原理：GPU 需要像素坐标去深度图读取对应位置。
        Texture depthTex = Shader.GetGlobalTexture(PIPELINE_DEPTH_TEX); // 作用：获取相机深度纹理；原理：SRP 会把深度图设置为全局纹理。

        if (depthTex == null) // 作用：检查深度纹理是否有效；原理：未开启深度纹理或管线未生成时可能为空。
        { // 作用：开始 if 代码块；原理：没有深度图时无法遮挡检测。
            return; // 作用：停止遮挡检测；原理：避免给 Compute Shader 绑定空纹理。
        } // 作用：结束 if 代码块；原理：深度纹理检查完成。

        cs_PrepareLightOcclusion.SetTexture(_csKernel, CS_DEPTHTEX_NAME, depthTex); // 作用：绑定深度纹理；原理：Compute Shader 通过 _DepthTex 读取屏幕深度。
        _cbLightOcclusionCheckBuffer.SetData(_lightSourceDepth); // 作用：上传深度结果初始数组；原理：保证 Buffer 有已知初始值。
        _cbLightUVBuffer.SetData(_screenSpaceLightSrcUV); // 作用：上传光源屏幕坐标；原理：GPU 根据这些坐标采样深度图。
        cs_PrepareLightOcclusion.SetBuffer(_csKernel, CS_IS_LIGHT_OCCLUDED, _cbLightOcclusionCheckBuffer); // 作用：绑定深度输出 Buffer；原理：Compute Shader 会把线性深度写入这里。
        cs_PrepareLightOcclusion.SetBuffer(_csKernel, CS_LIGHT_UV, _cbLightUVBuffer); // 作用：绑定坐标输入 Buffer；原理：Compute Shader 读取每个光源的 x/y 像素位置。
        Vector4 zBufferParam = Shader.GetGlobalVector(Z_BUFFER_PARAMS); // 作用：获取 ZBuffer 参数；原理：Unity 根据相机 near/far 和平台深度规则生成这些参数。
        cs_PrepareLightOcclusion.SetVector(Z_BUFFER_DELIVERED, zBufferParam); // 作用：传递深度线性化参数；原理：Compute Shader 用 1/(z*depth+w) 还原线性深度。
        cs_PrepareLightOcclusion.Dispatch(_csKernel, 1, 1, 1); // 作用：启动 GPU 计算；原理：Kernel 的 numthreads(8,1,1) 使一个 Dispatch 处理 8 个槽位。
        _cbLightOcclusionCheckBuffer.GetData(_lightSourceDepth); // 作用：读回 GPU 计算结果；原理：CPU 后续 CheckIn 需要用这些深度值比较遮挡。
    } // 作用：结束 PrepareLightOcclusion 方法；原理：遮挡深度准备完成。

    
    /// <summary>
    /// 把每个活跃光源的屏幕像素坐标写入数组。
    /// 
    /// 这些坐标会传给 Compute Shader，
    /// 用于从深度图中读取对应像素的深度。
    /// </summary>
    private void DeliverUV() // 作用：把活跃光源屏幕坐标写入数组；原理：ComputeBuffer.SetData 会上传该数组给 GPU。
    { // 作用：开始 DeliverUV 方法；原理：坐标准备逻辑写在这里。
        foreach (var pair in _flareDict) // 作用：遍历全部光源；原理：只有分配了 srcIndex 的光源会写入槽位。
        { // 作用：开始 foreach 循环体；原理：每次处理一个光源。
            FlareStatusData src = pair.Value; // 作用：获取当前光源状态；原理：需要读取 sourceCoordinate 和 srcIndex。

            if (src.srcIndex != -1) // 作用：判断是否有有效槽位；原理：-1 表示不参与 GPU 遮挡检测。
            { // 作用：开始 if 代码块；原理：有效槽位才写入数组。
                _screenSpaceLightSrcUV[src.srcIndex].x = Mathf.Clamp((int)src.sourceCoordinate.x, 0, _camera.pixelWidth - 1); // 作用：写入 x 像素坐标；原理：Clamp 防止越界访问深度纹理。
                _screenSpaceLightSrcUV[src.srcIndex].y = Mathf.Clamp((int)src.sourceCoordinate.y, 0, _camera.pixelHeight - 1); // 作用：写入 y 像素坐标；原理：Texture2D 整数索引必须在纹理尺寸范围内。
            } // 作用：结束 if 代码块；原理：当前光源坐标写入完成。
        } // 作用：结束 foreach 循环体；原理：所有有效光源坐标准备完成。
    } // 作用：结束 DeliverUV 方法；原理：CPU 坐标数组可上传给 GPU。

    
    /// <summary>
    /// SRP 相机渲染完成回调。
    /// 
    /// 作用：
    /// 在相机渲染结束后执行遮挡检测。
    /// 
    /// 原理：
    /// 这时 _CameraDepthTexture 已经存在，
    /// 可以安全地传给 Compute Shader 使用。
    /// </summary>
    private void AddRenderPass(ScriptableRenderContext context, Camera camera) // 作用：响应相机渲染结束事件；原理：SRP 在每个相机渲染结束后调用该回调。
    { // 作用：开始 AddRenderPass 方法；原理：回调处理写在方法体内。
        if (camera != null && camera.gameObject.CompareTag(CAMERA_COMPARE_TAG)) // 作用：过滤有效主相机；原理：避免 SceneView 或其他相机重复执行遮挡检测。
        { // 作用：开始 if 代码块；原理：只有主相机满足条件。
            PrepareLightOcclusion(); // 作用：执行遮挡检测准备；原理：此时深度图通常已经生成，可安全读取。
        } // 作用：结束 if 代码块；原理：相机过滤完成。
    } // 作用：结束 AddRenderPass 方法；原理：本次相机回调处理完成。

    
    /// <summary>
    /// 计算每个 flare 小光斑的屏幕中心位置。
    /// 
    /// 原理：
    /// Lens Flare 通常沿着：
    /// 
    ///     光源屏幕位置 -> 屏幕中心
    /// 
    /// 这条方向线排列。
    /// 
    /// 每个 spriteBlock 中的 offset 决定该光斑在线上的相对位置。
    /// </summary>
    private void CalculateMeshData(MFFlareLauncher lightSource, ref FlareStatusData statusData) // 作用：计算每个光晕块屏幕位置；原理：光斑沿光源与屏幕中心连线按 offset 分布。
    { // 作用：开始 CalculateMeshData 方法；原理：位置计算写在方法体内。
        int flareCount = lightSource.asset.spriteBlocks.Count; // 作用：获取光晕块数量；原理：每个块都需要一个中心点。
        Vector3[] oneFlareLine = new Vector3[flareCount]; // 作用：创建位置数组；原理：临时存储所有光斑中心。

        for (int i = 0; i < flareCount; i++) // 作用：遍历每个光晕块；原理：逐个根据 offset 计算位置。
        { // 作用：开始 for 循环体；原理：每次处理一个 spriteBlock。
            Vector2 sourceOffsetFromCenter = new Vector2(statusData.sourceCoordinate.x - _halfScreen.x, statusData.sourceCoordinate.y - _halfScreen.y); // 作用：计算光源相对屏幕中心偏移；原理：Lens Flare 的鬼影光斑沿这条方向线排列。
            Vector2 realOffset = sourceOffsetFromCenter * lightSource.asset.spriteBlocks[i].offset; // 作用：根据 offset 缩放偏移；原理：offset 决定该光斑在线上的相对位置。
            oneFlareLine[i] = new Vector3(_halfScreen.x + realOffset.x, _halfScreen.y + realOffset.y, DISTANCE); // 作用：得到光斑屏幕中心；原理：屏幕中心加偏移得到最终屏幕坐标，z 用于 ScreenToWorldPoint。
        } // 作用：结束 for 循环体；原理：所有光斑位置计算完成。

        statusData.flareWorldPosCenter = oneFlareLine; // 作用：保存计算结果；原理：CreateMesh 会根据这些中心点生成顶点。
    } // 作用：结束 CalculateMeshData 方法；原理：Mesh 位置数据准备完成。

    
    /// <summary>
    /// 根据当前光源状态创建 Mesh，并绘制 Lens Flare。
    /// 
    /// 每个 flare 小光斑都是一个 Quad。
    /// 一条 Lens Flare 是多个 Quad 组成的 Mesh。
    /// 
    /// 核心流程：
    /// 1. 根据 Rect 和 scale 计算每个 Quad 的大小
    /// 2. 根据屏幕位置计算四个顶点
    /// 3. 根据 useRotation 决定是否旋转
    /// 4. 根据颜色、光源颜色、距离屏幕中心程度、fadeScale 计算顶点色
    /// 5. 设置 Mesh 数据
    /// 6. Graphics.DrawMesh 绘制
    /// </summary>
    private void CreateMesh(MFFlareLauncher lightSource, ref FlareStatusData statusData) // 作用：生成并绘制光晕 Mesh；原理：把每个光晕块作为 Quad 写入同一个 Mesh。
    { // 作用：开始 CreateMesh 方法；原理：顶点、颜色和绘制逻辑写在这里。
        if (statusData.flareScale <= 0) // 作用：检查是否完全不可见；原理：强度为 0 时绘制没有意义。
        { // 作用：开始 if 代码块；原理：不可见时提前返回。
            return; // 作用：跳过绘制；原理：节省 CPU 和 GPU 开销。
        } // 作用：结束 if 代码块；原理：可见性强度检查完成。

        if (lightSource.asset == null || lightSource.asset.flareSprite == null || material == null) // 作用：检查必要资源；原理：缺少资源会导致 Mesh 绘制或贴图采样失败。
        { // 作用：开始 if 代码块；原理：资源缺失时提前返回。
            return; // 作用：跳过绘制；原理：避免空引用错误。
        } // 作用：结束 if 代码块；原理：资源检查完成。

        Light source = lightSource.GetComponent<Light>(); // 作用：获取 Unity Light 组件；原理：光晕颜色和强度可受真实光源影响。

        if (source == null) // 作用：检查 Light 组件是否存在；原理：没有 Light 就无法读取颜色和强度。
        { // 作用：开始 if 代码块；原理：缺少组件时保护返回。
            return; // 作用：跳过绘制；原理：避免访问 source.color 时空引用。
        } // 作用：结束 if 代码块；原理：Light 组件检查完成。

        Texture2D tex = lightSource.asset.flareSprite; // 作用：获取光晕图集；原理：Quad 大小和 Shader 采样都依赖该纹理。
        float angle = (45f + Vector2.SignedAngle(Vector2.up, new Vector2(statusData.sourceCoordinate.x - _halfScreen.x, statusData.sourceCoordinate.y - _halfScreen.y))) / 180f * Mathf.PI; // 作用：计算旋转角弧度；原理：根据光源到屏幕中心方向，让需要旋转的光斑朝向该方向。
        int flareCount = lightSource.asset.spriteBlocks.Count; // 作用：获取光晕块数量；原理：循环生成每个 Quad。

        for (int i = 0; i < flareCount; i++) // 作用：遍历所有光晕块；原理：每个 spriteBlock 生成一个 Quad。
        { // 作用：开始 for 循环体；原理：逐个更新顶点和颜色。
            MFFlareSpriteData spriteData = lightSource.asset.spriteBlocks[i]; // 作用：读取当前光晕块配置；原理：包含 UV、缩放、颜色、旋转、offset 等数据。
            Rect rect = spriteData.block; // 作用：读取图集 UV 矩形；原理：rect.width/height 代表该图块在整张纹理中的比例。
            Vector2 halfSize = new Vector2(tex.width * rect.width * 0.5f * spriteData.scale * (lightSource.asset.fadeWithScale ? statusData.flareScale * 0.5f + 0.5f : 1f), tex.height * rect.height * 0.5f * spriteData.scale * (lightSource.asset.fadeWithScale ? statusData.flareScale * 0.5f + 0.5f : 1f)); // 作用：计算 Quad 半尺寸；原理：图集像素尺寸乘 UV 比例得到图块像素大小，再乘缩放和淡入淡出缩放。
            Vector3 flarePos = statusData.flareWorldPosCenter[i]; // 作用：读取当前光斑中心；原理：顶点会围绕该中心生成。

            if (spriteData.useRotation) // 作用：判断是否启用旋转；原理：某些光晕纹理需要朝向屏幕中心或光源方向。
            { // 作用：开始旋转分支；原理：用三角函数计算旋转后的顶点。
                float magnitude = Mathf.Sqrt(halfSize.x * halfSize.x + halfSize.y * halfSize.y); // 作用：计算半对角线长度；原理：旋转矩形顶点可用对角线半径表示。
                float cos = magnitude * Mathf.Cos(angle); // 作用：计算旋转后的水平分量；原理：cos(angle) 给出旋转方向上的 x 投影。
                float sin = magnitude * Mathf.Sin(angle); // 作用：计算旋转后的垂直分量；原理：sin(angle) 给出旋转方向上的 y 投影。
                statusData.vertices[i * 4] = _camera.ScreenToWorldPoint(new Vector3(flarePos.x - sin, flarePos.y + cos, flarePos.z)) - _screenCenter; // 作用：设置旋转 Quad 顶点 0；原理：屏幕点转世界点后减去 Mesh 中心得到局部坐标。
                statusData.vertices[i * 4 + 1] = _camera.ScreenToWorldPoint(new Vector3(flarePos.x - cos, flarePos.y - sin, flarePos.z)) - _screenCenter; // 作用：设置旋转 Quad 顶点 1；原理：通过旋转偏移得到第二个角点。
                statusData.vertices[i * 4 + 2] = _camera.ScreenToWorldPoint(new Vector3(flarePos.x + cos, flarePos.y + sin, flarePos.z)) - _screenCenter; // 作用：设置旋转 Quad 顶点 2；原理：对称偏移得到第三个角点。
                statusData.vertices[i * 4 + 3] = _camera.ScreenToWorldPoint(new Vector3(flarePos.x + sin, flarePos.y - cos, flarePos.z)) - _screenCenter; // 作用：设置旋转 Quad 顶点 3；原理：补齐第四个角点形成旋转矩形。
            } // 作用：结束旋转分支；原理：旋转顶点计算完成。
            else // 作用：处理不旋转光晕块；原理：直接用轴对齐屏幕矩形生成 Quad。
            { // 作用：开始非旋转分支；原理：用中心点加减 halfSize 得到四个角。
                statusData.vertices[i * 4] = _camera.ScreenToWorldPoint(new Vector3(flarePos.x - halfSize.x, flarePos.y + halfSize.y, flarePos.z)) - _screenCenter; // 作用：设置左上顶点；原理：中心点减 x 加 y 得到屏幕左上角。
                statusData.vertices[i * 4 + 1] = _camera.ScreenToWorldPoint(new Vector3(flarePos.x - halfSize.x, flarePos.y - halfSize.y, flarePos.z)) - _screenCenter; // 作用：设置左下顶点；原理：中心点减 x 减 y 得到屏幕左下角。
                statusData.vertices[i * 4 + 2] = _camera.ScreenToWorldPoint(new Vector3(flarePos.x + halfSize.x, flarePos.y + halfSize.y, flarePos.z)) - _screenCenter; // 作用：设置右上顶点；原理：中心点加 x 加 y 得到屏幕右上角。
                statusData.vertices[i * 4 + 3] = _camera.ScreenToWorldPoint(new Vector3(flarePos.x + halfSize.x, flarePos.y - halfSize.y, flarePos.z)) - _screenCenter; // 作用：设置右下顶点；原理：中心点加 x 减 y 得到屏幕右下角。
            } // 作用：结束非旋转分支；原理：普通 Quad 顶点计算完成。

            Color vertexAddColor = spriteData.color; // 作用：读取光晕块基础颜色；原理：每个 spriteBlock 可配置独立颜色。
            Color lightColor = Color.white; // 作用：初始化光源颜色权重；原理：白色乘法不会改变原始颜色。
            lightColor.r = Mathf.Lerp(1f, source.color.r, spriteData.useLightColor); // 作用：混合红色通道；原理：useLightColor 为 0 使用白色，为 1 使用光源红色。
            lightColor.g = Mathf.Lerp(1f, source.color.g, spriteData.useLightColor); // 作用：混合绿色通道；原理：线性插值让光源颜色影响可调。
            lightColor.b = Mathf.Lerp(1f, source.color.b, spriteData.useLightColor); // 作用：混合蓝色通道；原理：控制光晕是否染上光源颜色。
            lightColor.a = 1f; // 作用：设置光源颜色 Alpha；原理：这里只让透明度由后续 offset 和 fade 控制。
            lightColor *= lightSource.useLightIntensity ? source.intensity : 1f; // 作用：应用光源强度；原理：启用后 Light.intensity 会放大或减弱光晕亮度。
            float offsetAlpha = (1.5f - Mathf.Abs(spriteData.offset)) / 1.5f; // 作用：按 offset 计算透明度；原理：距离中心线相对位置越极端，透明度越低。
            float screenCenterAlpha = 1f - Mathf.Min(1f, new Vector2(flarePos.x - _halfScreen.x, flarePos.y - _halfScreen.y).magnitude / new Vector2(_halfScreen.x, _halfScreen.y).magnitude); // 作用：按离屏幕中心距离衰减透明度；原理：越靠近屏幕边缘越暗，避免边缘光斑突兀。
            float fadeAlpha = lightSource.asset.fadeWithAlpha ? statusData.flareScale : 1f; // 作用：计算淡入淡出透明度；原理：fadeWithAlpha 开启时使用 flareScale 控制 Alpha。
            vertexAddColor *= new Vector4(lightColor.r, lightColor.g, lightColor.b, offsetAlpha * screenCenterAlpha) * fadeAlpha; // 作用：合成最终顶点颜色；原理：基础色乘光源色、位置透明度和淡入淡出透明度。
            vertexAddColor = vertexAddColor.linear; // 作用：转换到线性颜色空间；原理：Linear Space 项目中这样能得到更正确的亮度混合。
            statusData.vertColor[i * 4] = vertexAddColor; // 作用：设置顶点 0 颜色；原理：同一个 Quad 四个顶点使用同色保持整体一致。
            statusData.vertColor[i * 4 + 1] = vertexAddColor; // 作用：设置顶点 1 颜色；原理：Shader 会插值顶点色。
            statusData.vertColor[i * 4 + 2] = vertexAddColor; // 作用：设置顶点 2 颜色；原理：保持整张光晕块颜色一致。
            statusData.vertColor[i * 4 + 3] = vertexAddColor; // 作用：设置顶点 3 颜色；原理：四角同色避免出现不必要渐变。
        } // 作用：结束 for 循环；原理：所有光晕块顶点和颜色计算完成。

        statusData.flareMesh.Clear(); // 作用：清空旧 Mesh 数据；原理：每帧重新写入动态顶点，避免残留旧数据。
        statusData.flareMesh.vertices = statusData.vertices; // 作用：写入顶点数组；原理：Mesh 根据顶点确定几何形状。
        statusData.flareMesh.uv = statusData.uv; // 作用：写入 UV 数组；原理：Shader 根据 UV 从图集中采样光晕图案。
        statusData.flareMesh.triangles = statusData.triangle; // 作用：写入三角形索引；原理：GPU 根据索引将顶点组成三角形。
        statusData.flareMesh.colors = statusData.vertColor; // 作用：写入顶点颜色；原理：材质 Shader 可读取顶点色控制最终颜色。
        _propertyBlock.SetTexture(STATIC_BaseMap, lightSource.asset.flareSprite); // 作用：设置本次绘制的图集；原理：MaterialPropertyBlock 让不同光源可使用不同贴图。
        _propertyBlock.SetVector(STATIC_FLARESCREENPOS, statusData.sourceScreenPos); // 作用：设置光源屏幕位置参数；原理：Shader 可根据该参数做额外屏幕空间计算。
        Graphics.DrawMesh(statusData.flareMesh, _screenCenter, Quaternion.identity, material, 0, _camera, 0, _propertyBlock); // 作用：绘制光晕 Mesh；原理：直接把动态 Mesh 提交给指定相机和材质渲染。
    } // 作用：结束 CreateMesh 方法；原理：本光源光晕绘制完成。

    
    /// <summary>
    /// 调试绘制每个 flare 光斑的位置。
    /// 
    /// 作用：
    /// 从相机位置向每个光斑中心画一条 Debug Line。
    /// 可以在 Scene 视图中观察光斑分布。
    /// </summary>
    private void DebugDrawMeshPos(MFFlareLauncher lightSource, FlareStatusData statusData) // 作用：绘制调试线；原理：Scene 视图中可观察每个光斑的空间位置。
    { // 作用：开始 DebugDrawMeshPos 方法；原理：调试绘制逻辑写在这里。
        if (statusData.flareWorldPosCenter == null) // 作用：检查光斑位置数组；原理：未计算位置时不能访问数组。
        { // 作用：开始 if 代码块；原理：数组为空时保护返回。
            return; // 作用：跳过调试绘制；原理：避免空引用。
        } // 作用：结束 if 代码块；原理：位置数组检查完成。

        for (int i = 0; i < lightSource.asset.spriteBlocks.Count; i++) // 作用：遍历每个光斑；原理：每个光斑画一条线用于观察。
        { // 作用：开始 for 循环体；原理：逐个绘制调试线。
            Debug.DrawLine(_camera.transform.position, _camera.ScreenToWorldPoint(statusData.flareWorldPosCenter[i])); // 作用：从相机画线到光斑中心；原理：ScreenToWorldPoint 把屏幕光斑位置转换成世界位置。
        } // 作用：结束 for 循环体；原理：所有调试线绘制完成。
    } // 作用：结束 DebugDrawMeshPos 方法；原理：调试绘制完成。
    /// <summary>
    /// OnDestroy 在对象销毁时调用。
    /// 
    /// 作用：
    /// 彻底销毁 Mesh 资源，避免内存泄漏。
    /// </summary>
    private void OnDestroy() // 作用：对象销毁时释放 Mesh；原理：动态创建的 Mesh 不清理可能残留内存。
    { // 作用：开始 OnDestroy 方法；原理：销毁清理写在这里。
        if (_flareDict != null) // 作用：检查总光源字典是否存在；原理：初始化失败或生命周期异常时可能为空。
        { // 作用：开始 if 代码块；原理：存在时遍历回收 Mesh。
            foreach (var pair in _flareDict) // 作用：遍历所有注册光源；原理：每个光源可能持有一个 Mesh。
            { // 作用：开始 foreach 循环体；原理：逐个检查 Mesh。
                if (pair.Value.flareMesh != null) // 作用：检查 Mesh 是否存在；原理：避免把空对象加入池中。
                { // 作用：开始 if 代码块；原理：有效 Mesh 才回收。
                    _meshPool.Enqueue(pair.Value.flareMesh); // 作用：加入 Mesh 池；原理：统一在下面 while 中销毁。
                } // 作用：结束 if 代码块；原理：单个 Mesh 回收检查完成。
            } // 作用：结束 foreach 循环体；原理：所有注册光源 Mesh 收集完成。
        } // 作用：结束 if 代码块；原理：字典回收流程完成。

        if (_meshPool != null) // 作用：检查 Mesh 池是否存在；原理：避免空引用。
        { // 作用：开始 if 代码块；原理：存在时销毁池中 Mesh。
            while (_meshPool.Count > 0) // 作用：循环直到池为空；原理：逐个取出并销毁 Mesh。
            { // 作用：开始 while 循环体；原理：每次销毁一个 Mesh。
                Destroy(_meshPool.Dequeue()); // 作用：销毁 Mesh 资源；原理：UnityEngine.Object 需要 Destroy 才能释放运行时对象。
            } // 作用：结束 while 循环体；原理：继续直到没有 Mesh。

            _meshPool.Clear(); // 作用：清空队列；原理：确保池状态干净。
        } // 作用：结束 if 代码块；原理：Mesh 池清理完成。
    } // 作用：结束 OnDestroy 方法；原理：销毁清理完成。
} // 作用：结束 MFLensFlare 类；原理：运行时主控制器定义完成。

#if UNITY_EDITOR // 作用：下面是编辑器专用调试面板；原理：不参与游戏运行时打包。


/// <summary>
/// MFLensflareEditor 是 MFLensFlare 的自定义 Inspector。
/// 
/// 作用：
/// 在 Unity Inspector 中显示当前 Lens Flare 系统的运行时调试信息。
/// 
/// 包括：
/// 1. 当前注册光源数量
/// 2. 当前活跃光源状态
/// 3. 是否方向光
/// 4. 是否在屏幕内
/// 5. 是否可见
/// 6. 遮挡检测槽位 srcIndex
/// 7. 深度图读取到的线性深度
/// 8. 光源到相机的真实距离
/// </summary>
[CustomEditor(typeof(MFLensFlare))] // 作用：指定自定义 Inspector 目标；原理：当选中 MFLensFlare 时 Unity 使用该 Editor 绘制面板。
public class MFLensflareEditor : Editor // 作用：定义 MFLensFlare 的编辑器面板类；原理：继承 Editor 可重写 OnInspectorGUI。
{ // 作用：开始编辑器类体；原理：Inspector 绘制逻辑写在这里。
    public MFLensFlare _target; // 作用：缓存当前编辑目标；原理：避免每次绘制都重复转换 target。

    private void OnEnable() // 作用：编辑器启用时初始化；原理：Inspector 创建时 Unity 会调用。
    { // 作用：开始 OnEnable 方法；原理：缓存目标对象。
        _target = target as MFLensFlare; // 作用：转换并保存目标；原理：target 是 UnityEditor.Editor 提供的通用 Object。
    } // 作用：结束 OnEnable 方法；原理：目标缓存完成。

    public override void OnInspectorGUI() // 作用：自定义 Inspector 绘制；原理：Unity 每次刷新 Inspector 时调用该函数。
    { // 作用：开始 OnInspectorGUI 方法；原理：所有编辑器 UI 写在这里。
        if (_target.FlareDict != null && _target.FlareDict.Count != 0) // 作用：判断是否有注册光源；原理：有数据时才显示数量。
        { // 作用：开始 if 代码块；原理：条件成立则绘制文本。
            EditorGUILayout.LabelField("Light Count: ", _target.FlareDict.Count.ToString()); // 作用：显示光源数量；原理：LabelField 用于只读文本显示。
        } // 作用：结束 if 代码块；原理：光源数量显示完成。

        EditorGUILayout.Space(); // 作用：增加面板间距；原理：改善调试信息可读性。

        if (_target.ActiveDict != null && _target.ActiveDict.Count != 0) // 作用：判断是否有活跃光源；原理：只有活跃光源才有遮挡检测调试数据。
        { // 作用：开始 if 代码块；原理：存在活跃数据时绘制表格。
            EditorGUIUtility.fieldWidth = 50; // 作用：设置字段宽度；原理：让横向表格显示更紧凑。

            using (new EditorGUILayout.HorizontalScope()) // 作用：创建横向布局表头；原理：using 结束时自动关闭布局作用域。
            { // 作用：开始横向布局；原理：内部控件会排成一行。
                EditorGUILayout.TextField("Dir"); // 作用：显示方向光列名；原理：Dir 表示 directionalLight。
                EditorGUILayout.TextField("InScreen"); // 作用：显示屏幕内状态列名；原理：对应 isInScreen。
                EditorGUILayout.TextField("Visible"); // 作用：显示可见性列名；原理：对应 isVisible。
                EditorGUILayout.TextField("SrcIndex"); // 作用：显示槽位列名；原理：对应 ComputeBuffer 槽位索引。
                EditorGUILayout.TextField("DepthOnTex"); // 作用：显示深度图读数列名；原理：对应 _lightSourceDepth。
                EditorGUILayout.TextField("LinearDist"); // 作用：显示真实距离列名；原理：用于和深度图读数比较。
            } // 作用：结束横向布局；原理：表头绘制完成。

            foreach (var pair in _target.ActiveDict) // 作用：遍历所有活跃光源；原理：每个活跃光源显示一行调试信息。
            { // 作用：开始 foreach 循环体；原理：逐行绘制表格内容。
                using (new EditorGUILayout.HorizontalScope("box")) // 作用：创建带边框的横向布局；原理：box 样式让每个光源信息更清晰。
                { // 作用：开始横向布局；原理：内部字段排成一行。
                    EditorGUILayout.TextField(pair.Key.directionalLight.ToString()); // 作用：显示是否方向光；原理：读取 MFFlareLauncher.directionalLight。
                    EditorGUILayout.TextField(pair.Value.isInScreen.ToString()); // 作用：显示是否在屏幕内；原理：读取运行时状态 isInScreen。
                    EditorGUILayout.TextField(pair.Value.isVisible.ToString()); // 作用：显示是否可见；原理：读取遮挡检测后的 isVisible。
                    EditorGUILayout.TextField(pair.Value.srcIndex.ToString()); // 作用：显示 Buffer 槽位；原理：srcIndex 对应 _lightSourceDepth 数组索引。
                    float oDepth = 0f; // 作用：初始化深度图读数；原理：无效索引时显示 0。

                    if (pair.Value.srcIndex >= 0 && _target.Editor_LightSrcDepth != null && pair.Value.srcIndex < _target.Editor_LightSrcDepth.Length) // 作用：检查索引和数组有效性；原理：避免越界或空引用。
                    { // 作用：开始 if 代码块；原理：有效时读取深度。
                        oDepth = _target.Editor_LightSrcDepth[pair.Value.srcIndex]; // 作用：读取深度结果；原理：该值来自 Compute Shader 对深度图的采样和线性化。
                    } // 作用：结束 if 代码块；原理：深度读取完成。

                    EditorGUILayout.TextField(oDepth.ToString()); // 作用：显示深度图线性深度；原理：用于观察遮挡判断是否合理。
                    float linearDist = 0f; // 作用：初始化光源真实距离；原理：没有主相机时保持 0。

                    if (Camera.main != null) // 作用：检查主相机是否存在；原理：计算距离需要 Camera.main.transform。
                    { // 作用：开始 if 代码块；原理：存在主相机时计算距离。
                        linearDist = Vector3.Magnitude(pair.Key.transform.position - Camera.main.transform.position); // 作用：计算光源到主相机距离；原理：向量长度表示两点间欧氏距离。
                    } // 作用：结束 if 代码块；原理：距离计算完成。

                    EditorGUILayout.TextField(linearDist.ToString()); // 作用：显示真实距离；原理：可和 DepthOnTex 对比判断是否被遮挡。
                } // 作用：结束横向布局；原理：当前光源调试行绘制完成。
            } // 作用：结束 foreach 循环；原理：所有活跃光源调试行绘制完成。
        } // 作用：结束 if 代码块；原理：活跃光源调试表格绘制完成。

        EditorGUILayout.Space(); // 作用：增加底部间距；原理：让默认 Inspector 与调试表格分隔。
        base.OnInspectorGUI(); // 作用：绘制默认 Inspector；原理：保留 DebugMode、material、fadeoutTime、ComputeShader 等字段编辑功能。
    } // 作用：结束 OnInspectorGUI 方法；原理：Inspector 绘制完成。
} // 作用：结束 MFLensflareEditor 类；原理：自定义编辑器定义完成。

#endif // 作用：结束编辑器专用代码；原理：UNITY_EDITOR 条件编译块结束。
