using UnityEngine; // 作用：引入 Unity 核心命名空间；原理：MonoBehaviour、Light、Camera、GetComponent 等 Unity 类型和函数都来自这里。

[RequireComponent(typeof(Light))] // 作用：强制当前 GameObject 必须带有 Light 组件；原理：如果物体没有 Light，Unity 会自动添加，防止运行时 GetComponent<Light>() 为空。
public class MFFlareLauncher : MonoBehaviour // 作用：定义镜头光晕光源发射器脚本；原理：继承 MonoBehaviour 后可以挂载到场景物体上，并使用 OnEnable、OnDisable 等生命周期函数。
{ // 作用：开始 MFFlareLauncher 类体；原理：类中的字段和方法都写在大括号内部。

    public bool directionalLight; // 作用：标记当前光源是否按方向光处理；原理：方向光没有真实位置，镜头光晕系统会用光源方向模拟一个很远的屏幕位置。

    public bool useLightIntensity; // 作用：控制光晕亮度是否受 Light.intensity 影响；原理：开启后，光源强度越高，生成的 Lens Flare 越亮。

    public MFFlareAsset asset; // 作用：指定当前光源使用的光晕资源；原理：MFFlareAsset 中保存图集、光斑块、UV、颜色、缩放、偏移等配置。

    [HideInInspector] public Light lightSource; // 作用：缓存当前物体上的 Light 组件，但不在 Inspector 中显示；原理：运行时需要读取光源颜色和强度，HideInInspector 避免面板中重复暴露该字段。

    private Camera _mainCam; // 作用：缓存主相机引用；原理：启用时注册到主相机上的 MFLensFlare，禁用时也需要通过这个引用把自己移除。

    private void OnEnable() // 作用：当该脚本启用时自动调用；原理：Unity 在物体激活或组件启用时调用 OnEnable，适合做注册操作。
    { // 作用：开始 OnEnable 方法体；原理：启用时的初始化逻辑写在这里。

        lightSource = GetComponent<Light>(); // 作用：获取当前物体上的 Light 组件；原理：[RequireComponent(typeof(Light))] 保证理论上该组件一定存在。

        _mainCam = Camera.main; // 作用：获取场景中的主相机；原理：Camera.main 会查找 Tag 为 MainCamera 的相机对象。

        if (_mainCam == null) // 作用：判断是否找到了主相机；原理：如果场景中没有 Tag 为 MainCamera 的相机，Camera.main 会返回 null。
        { // 作用：开始主相机为空的保护逻辑；原理：避免后续 _mainCam.GetComponent 报空引用错误。

            Debug.LogWarning("MFFlareLauncher 找不到 MainCamera，请确认场景中有一个 Tag 为 MainCamera 的相机。", this); // 作用：输出警告信息；原理：提示用户镜头光晕系统需要主相机作为管理器挂载对象。

            return; // 作用：停止继续执行注册逻辑；原理：没有主相机就无法找到 MFLensFlare 系统。
        } // 作用：结束主相机为空判断；原理：如果相机存在则继续执行下面逻辑。

        MFLensFlare lensFlare = _mainCam.GetComponent<MFLensFlare>(); // 作用：从主相机上获取 MFLensFlare 管理器；原理：所有光源需要注册到该管理器中统一计算、遮挡检测和绘制。

        if (lensFlare == null) // 作用：判断主相机上是否挂载了 MFLensFlare；原理：如果没有该组件，就无法管理和绘制这个光源的 Lens Flare。
        { // 作用：开始 MFLensFlare 为空的保护逻辑；原理：避免调用 AddLight 时报空引用。

            Debug.LogWarning("MFFlareLauncher 找不到 MFLensFlare，请把 MFLensFlare 脚本挂到 MainCamera 上。", this); // 作用：输出警告信息；原理：提示用户缺少镜头光晕系统主控制器。

            return; // 作用：停止注册；原理：没有 MFLensFlare 管理器时当前光源无法加入系统。
        } // 作用：结束 MFLensFlare 为空判断；原理：如果管理器存在则继续注册。

        lensFlare.AddLight(this); // 作用：把当前光源注册到 MFLensFlare 系统中；原理：MFLensFlare 会保存这个 Launcher，并在每帧计算它的屏幕位置、遮挡状态和光晕 Mesh。
    } // 作用：结束 OnEnable 方法；原理：当前光源启用时的注册流程完成。

    private void Reset() // 作用：当组件第一次添加或点击 Reset 时调用；原理：Unity 用 Reset 初始化组件默认字段。
    { // 作用：开始 Reset 方法体；原理：默认值初始化逻辑写在这里。

        lightSource = GetComponent<Light>(); // 作用：自动缓存当前物体上的 Light 组件；原理：方便编辑器中添加脚本后立即获得 Light 引用。
    } // 作用：结束 Reset 方法；原理：组件默认初始化完成。

    private void OnDisable() // 作用：当该脚本禁用或物体失活时自动调用；原理：Unity 在组件关闭时调用 OnDisable，适合做反注册和清理操作。
    { // 作用：开始 OnDisable 方法体；原理：禁用时的清理逻辑写在这里。

        if (_mainCam == null) // 作用：判断之前是否缓存过主相机；原理：如果 OnEnable 没有成功找到主相机，这里就不能继续访问。
        { // 作用：开始主相机为空的保护逻辑；原理：避免空引用错误。

            return; // 作用：直接结束禁用逻辑；原理：没有主相机就没有地方可以移除当前光源。
        } // 作用：结束主相机为空判断；原理：主相机存在时继续执行下面逻辑。

        MFLensFlare lensFlare = _mainCam.GetComponent<MFLensFlare>(); // 作用：重新获取主相机上的 MFLensFlare 管理器；原理：需要通过管理器把当前光源从光晕系统中移除。

        if (lensFlare == null) // 作用：判断 MFLensFlare 是否仍然存在；原理：场景关闭或对象销毁顺序不同，主相机上的组件可能已经不存在。
        { // 作用：开始管理器为空的保护逻辑；原理：避免调用 RemoveLight 时报错。

            return; // 作用：直接结束清理逻辑；原理：管理器不存在时无需移除。
        } // 作用：结束管理器为空判断；原理：管理器存在时继续执行移除。

        lensFlare.RemoveLight(this); // 作用：把当前光源从 MFLensFlare 系统中移除；原理：防止禁用后的光源继续参与屏幕坐标计算、遮挡检测和 Mesh 绘制。
    } // 作用：结束 OnDisable 方法；原理：当前光源禁用时的反注册流程完成。

} // 作用：结束 MFFlareLauncher 类；原理：该脚本定义完成。