using UnityEngine; // 引入Unity基础命名空间，提供MonoBehaviour、Camera、Shader、Texture、Color等Unity常用类型。
using UnityEngine.Rendering; // 引入Unity渲染命名空间，提供RenderTexture、渲染相关基础类型。
using UnityEngine.Rendering.Universal; // 引入URP命名空间，提供UniversalAdditionalCameraData等URP专用组件。

// 强制该脚本所在GameObject必须挂载Camera组件（缺少则自动添加）。
// 原理：大气散射属于相机后处理效果，需要依赖相机的颜色缓冲和深度缓冲。
// URP版本说明：该脚本不再使用Built-in管线的OnRenderImage，而是只负责保存和传递大气散射参数；
// 真正的全屏后处理由AtmosphereRendererFeature注入URP渲染流程。
// 原因：URP属于Scriptable Render Pipeline，Built-in管线的OnRenderImage后处理入口不再是推荐/稳定方式。
[ExecuteAlways] // 让脚本在编辑器非运行状态下也执行，方便在Scene视图/Inspector调参时实时看到效果。
[RequireComponent(typeof(Camera))]
public class Atmosphere : MonoBehaviour { // 大气/雾/天空盒效果主控制脚本，挂在相机上保存所有大气参数。
    public Shader atmosphereShader; // 序列化字段：用于大气效果的Shader（在Inspector赋值）；URP版默认使用Hidden/AtmosphereURP。

    [Header("Skybox Settings")] // Inspector分组：天空盒相关参数。
    public Texture skyboxTex; // 天空盒立方体贴图；Shader中用它采样远处天空颜色。
    public Vector3 skyboxDirection = new Vector3(0.0f, -1.0f, 0.0f); // 天空盒流动的基础方向；用于模拟云层/天空纹理随时间缓慢移动。
    [Range(0.0f, 2.0f)] // 在Inspector中限制天空盒速度输入范围，避免过大导致流动不自然。
    public float skyboxSpeed = 0.1f; // 天空盒流动速度；Shader中会用_Time.y * skyboxSpeed作为流动时间。
    public GameObject sunObject;
    [Header("Sun Settings")] // Inspector分组：太阳相关参数。
    public Vector3 sunDirection = new Vector3(0.0f, 1.0f, 0.0f); // 太阳的世界空间方向；Shader中通过视线方向与太阳方向点乘生成太阳光晕。

    [ColorUsageAttribute(false, true)] // 颜色属性配置：false=不显示Alpha通道，true=启用HDR高动态范围，允许太阳颜色超过1。
    public Color sunColor = Color.white; // 太阳HDR颜色；值越亮，太阳光晕和水面反射中的太阳颜色越强。

    [Header("Fog Settings")] // Inspector分组：雾效相关参数。
    [Range(0.0f, 1000.0f)] // 限制雾高度范围，便于调参。
    public float fogHeight = 500.0f; // 雾的有效最大高度；世界坐标y越接近该值，雾的高度衰减越弱。

    [Range(0.01f, 5.0f)] // 避免衰减系数为0，防止Shader里出现除0。
    public float fogAttenuation = 1.2f; // 雾的高度衰减曲率；值越大，高处仍然能保留更多雾效。

    public Color fogColor = Color.gray; // 雾的基础颜色；最终画面会在原场景颜色和该雾颜色之间混合。
    
    [Range(0.0f, 2.0f)] // 控制雾密度范围；0表示基本无雾。
    public float fogDensity = 0.0f; // 雾的整体密度；Shader中会影响距离雾的指数衰减速度。

    [Range(0.0f, 1000.0f)] // 控制雾起始距离，避免近处物体立刻被雾覆盖。
    public float fogOffset = 0.0f; // 雾的起始距离偏移；相机到像素的距离小于该值时雾效较弱或没有。

    public static Atmosphere Active { get; private set; } // 当前启用的大气组件；RendererFeature可以通过它找到全局大气参数。

    private Camera cam; // 私有字段：缓存Camera组件，避免每帧重复GetComponent造成额外开销。

    public Vector3 GetSunDirection() { // 公共方法：供外部脚本获取太阳方向，例如水面Shader脚本需要太阳方向做高光/反射。
        return sunDirection; // 返回当前Inspector中设置的太阳方向。
    }

    public Vector3 GetSkyboxDirection() { // 公共方法：供外部脚本获取天空盒流动方向。
        return skyboxDirection; // 返回天空盒流动方向。
    }

    public float GetSkyboxSpeed() { // 公共方法：供外部脚本获取天空盒流动速度。
        return skyboxSpeed; // 返回天空盒流动速度。
    }

    public Color GetSunColor() { // 公共方法：供外部脚本获取太阳颜色，例如水面反射太阳高光。
        return sunColor; // 返回太阳HDR颜色。
    }

    public RenderTexture GetRenderTarget() { // 公共方法：保留旧Built-in版本接口，避免其他脚本调用时报错。
        // URP版不再手动创建colorTexture/depthTexture。
        // 原理：URP的相机颜色目标由ScriptableRenderer管理，RendererFeature通过cameraColorTargetHandle读取和写回。
        return null;
    }

    void OnEnable() { // 生命周期方法：脚本启用/激活时调用。
        Active = this; // 记录当前启用的大气组件；RendererFeature会从这里读取参数。
        cam = GetComponent<Camera>(); // 获取并缓存当前GameObject上的Camera组件。
        sunDirection=sunObject.gameObject.transform.forward;
        if (atmosphereShader == null) { // 如果Inspector没有手动指定Shader，则自动查找。
            atmosphereShader = Shader.Find("Hidden/AtmosphereURP"); // 自动查找URP版本的大气后处理Shader。
        }

        SetupURPCameraDepthTexture(); // 开启URP相机深度纹理；雾效需要深度来重建世界坐标和计算距离。
    }

    void Update() { // 生命周期方法：每帧更新时调用。
        sunDirection=sunObject.gameObject.transform.forward;
        SetupURPCameraDepthTexture(); // 确保运行时相机仍然开启深度纹理，防止用户或其他脚本关闭该选项。
    }

    void OnValidate() { // Inspector参数变化时调用；编辑器下修改数值会触发。
        if (atmosphereShader == null) { // 如果Shader为空，自动补全。
            atmosphereShader = Shader.Find("Hidden/AtmosphereURP"); // 查找隐藏的URP后处理Shader。
        }

        if (cam == null) { // 如果还没缓存Camera，则重新获取。
            cam = GetComponent<Camera>(); // 获取当前物体上的Camera组件。
        }

        SetupURPCameraDepthTexture(); // 在编辑器中也尝试开启深度纹理，保证预览效果正确。
    }

    void OnDisable() { // 生命周期方法：脚本禁用/销毁时调用。
        if (Active == this) { // 如果全局Active引用指向当前组件，则需要清空。
            Active = null; // 当前组件被禁用时清空全局引用，避免RendererFeature使用失效对象。
        }
    }

    private void SetupURPCameraDepthTexture() { // 设置URP相机深度纹理开关。
        if (cam == null) return; // 没有相机则无法设置，直接退出。

        UniversalAdditionalCameraData cameraData = cam.GetComponent<UniversalAdditionalCameraData>(); // 获取URP相机附加数据。
        if (cameraData != null) { // 如果当前项目确实是URP，相机上通常会有该组件。
            cameraData.requiresDepthTexture = true; // 要求URP生成_CameraDepthTexture；Shader中用于深度采样、距离计算、世界坐标重建。
        }
    }

    public void ApplyToMaterial(Material material, Camera renderCamera) { // 将大气参数传递给RendererFeature中的后处理材质。
        if (material == null || renderCamera == null) return; // 材质或相机为空时无法传参，直接退出。

        // 获取GPU兼容的投影矩阵：
        // GL.GetGPUProjectionMatrix会把Unity的投影矩阵转换成当前图形API使用的投影矩阵。
        // 原理：DirectX、OpenGL、Metal等平台的NDC深度/Y翻转规则不同，直接用camera.projectionMatrix可能导致深度重建错误。
        Matrix4x4 projMatrix = GL.GetGPUProjectionMatrix(renderCamera.projectionMatrix, false);
        // 计算视图投影矩阵：投影矩阵 × 视图矩阵；worldToCameraMatrix表示世界空间到相机空间的变换。
        Matrix4x4 viewProjMatrix = projMatrix * renderCamera.worldToCameraMatrix;
        // 向材质传递「视图投影矩阵的逆矩阵」。
        // 原理：Shader中拿到屏幕UV和深度后，需要用VP逆矩阵把裁剪空间位置还原成世界空间位置。
        material.SetMatrix("_CameraInvViewProjection", viewProjMatrix.inverse);

        material.SetVector("_FogColor", fogColor); // 向Shader传递雾颜色，用作远处/低处雾的混合颜色。
        material.SetVector("_SunColor", sunColor); // 向Shader传递太阳颜色，用作太阳光晕颜色。
        material.SetVector("_SunDirection", sunDirection); // 向Shader传递太阳方向，用于通过dot(viewDir, sunDir)计算太阳高光。
        material.SetVector("_SkyboxDirection", skyboxDirection); // 向Shader传递天空盒流动方向，用于偏移Cubemap采样方向。
        material.SetFloat("_FogDensity", fogDensity); // 向Shader传递雾密度，控制距离雾强弱。
        material.SetFloat("_FogOffset", fogOffset); // 向Shader传递雾起始距离，控制近处从哪里开始出现雾。
        material.SetFloat("_FogHeight", Mathf.Max(0.0001f, fogHeight)); // 传递雾高度，并限制最小值，避免Shader除以0。
        material.SetFloat("_FogAttenuation", Mathf.Max(0.0001f, fogAttenuation)); // 传递高度衰减，并限制最小值，避免pow/除法异常。
        material.SetFloat("_SkyboxSpeed", skyboxSpeed); // 传递天空盒流动速度，Shader中乘以_Time.y得到动画时间。
        material.SetTexture("_SkyboxTex", skyboxTex); // 传递天空盒Cubemap纹理，Shader中用于天空区域采样。
    }
}
