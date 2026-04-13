// 引入系统基础命名空间，提供基础类型如Action、Convert等（本脚本未深用）
using System;
// 引入集合命名空间，提供List、Dictionary等数据结构
using System.Collections;
using System.Collections.Generic;
// 引入Unity引擎核心命名空间
using UnityEngine;

// 定义命名空间，规范代码管理
namespace RecaNoMaho
{
    // 添加该特性使得脚本可以在Unity编辑器的非运行模式下执行，方便美术实时预览调参效果，无需点击Play
    [ExecuteInEditMode]
    // 添加该特性强制要求该脚本所在的游戏对象上必须有一个Light组件，如果没有会自动帮你加上，防止配置错误
    [RequireComponent(typeof(Light))]
    // 声明体积光渲染器类，继承自MonoBehaviour，可以挂载到游戏对象上
    public class LightVolumeRenderer : MonoBehaviour
    {
        // 在Inspector面板中添加一个标题为"体积光基础参数"的分割线，方便UI归类
        [Header("体积光基础参数")]
        // 是否覆盖全局的Ray Marching步数设置。如果勾选，则使用下面的rayMarchingSteps，否则使用RenderFeature里的统一设置
        public bool stepOverride = false;
        // Ray Marching的步进次数。范围限制在0~64，步数越多光柱越细腻，性能消耗成比例增加
        [Tooltip("Ray Marching的步进次数")][Range(0, 64)] public int rayMarchingSteps = 8;

        // 控制入射光线在经过介质（雾）时的衰减程度。对应Shader中的_IncomingLoss
        [Tooltip("控制入射光线在经过介质时的衰减")][Range(0f, 1f)] public float inComingLoss = 0;
        // 设置方向光的理论距离（因为方向光没有衰减，但在Shader中计算透射率需要距离参数，所以人为设定一个极大值）
        [Tooltip("（仅对方向光源生效）")]public float dirLightDistance = 100;
        // 是否覆盖全局的消光系数设置
        public bool extinctionOverride = false;
        // 体积光的可见距离。这是一个"美术友好"的参数，数值越小雾越浓，对应Shader中的透射率计算
        [Tooltip("体积光的可见距离(影响介质透射率)")][Range(0.01f, 50f)]public float visibilityDistance = 50;
        // 吸收系数。代表光照射到介质微粒上不发生散射而被直接吸收能量的比例
        [Tooltip("吸收系数（非严格按照公式）")] [Range(0, 1)] public float absorption = 0.1f;
        
        // 整体的光源强度乘数，用于微调体积光与实时光的比例
        [Tooltip("控制光源强度的系数")][Range(0f, 2f)]public float intensityMultiplier = 1;

        // 在Inspector面板中添加一个标题为"风格化参数"的分割线
        [Header("风格化参数")]
        // 亮部强度。对应Shader中计算入射光时的乘数，影响体积光发光部分的亮度
        [Tooltip("体积光亮部强度")] [Range(0f, 10f)] public float brightIntensity = 1;
        // 暗部强度。对应Shader中计算光线穿过雾气到达相机的透射率衰减乘数（_DarkIntensity），影响光柱之外的暗部变暗程度（用于风格化压暗）
        [Tooltip("体积光暗部强度")] [Range(0f, 10f)] public float darkIntentsity = 1;

        // 公开只读属性，缓存当前物体上的Light组件引用
        public Light light { get; private set; }
        // 公开只读属性，缓存用于在Scene窗口显示体积范围的网格数据
        public Mesh volumeMesh { get; private set; }
        
        // 私有变量，用于记录上一帧光源的张角和范围，通过对比判断是否需要重新生成Mesh（脏标记优化）
        private float previousAngle, previousRange;
        // 私有列表，用于存储提取出来的体积边界平面的方程系数（格式为 Ax + By + Cz + D = 0）
        // 容量设为6，因为一个长方体/视锥体最多有6个面
        private List<Vector4> planes = new List<Vector4>(6);

        // 私有布尔属性，快速判断当前绑定的光源是否为聚光灯
        private bool isSpotLight => light.type == LightType.Spot;
        // 私有布尔属性，快速判断当前绑定的光源是否为方向光
        private bool isDirectionalLight => light.type == LightType.Directional;

        // Unity内置生命周期函数，当在Scene窗口选中该物体时调用，用于绘制辅助线框
        private void OnDrawGizmosSelected()
        {
            // 设置辅助线框的颜色为青色
            Gizmos.color = Color.cyan;
            // 以物体的位置、旋转、缩放为基准，绘制volumeMesh的线框。方便美术直观看到体积光计算的有效区域
            Gizmos.DrawWireMesh(volumeMesh, 0, transform.position, transform.rotation, transform.lossyScale);
        }

        // Unity内置生命周期函数，在脚本实例化时最先调用（早于Start）
        private void Awake()
        {
            // 获取当前物体上的Light组件并赋值给缓存变量
            light = GetComponent<Light>();
            // 实例化一个新的空Mesh对象，准备用来构建锥体或方块网格
            volumeMesh = new Mesh();
            // 调用Reset方法，初始化Mesh为基础的1x1x1立方体
            Reset();
            // 记录当前光源的初始角度和范围，作为后续脏检查的基准
            previousAngle = light.spotAngle;
            previousRange = light.range;
        }

        // Unity内置生命周期函数，每帧调用
        private void Update()
        {
            // 检查光源参数是否发生了改变（是否变"脏"）
            if (IsDirty())
            {
                // 如果参数变了（比如美术拖动了Spot Angle滑块），重新生成表示体积范围的Mesh
                UpdateMesh();
            }
        }

        // 核心方法：获取当前光源体积范围的边界平面方程列表，供Shader进行射线求交计算
        // 参数camera：主相机，方向光时需要用到相机的近裁剪面
        public List<Vector4> GetVolumeBoundFaces(Camera camera)
        {
            // 清空上一帧计算出的平面列表
            planes.Clear();
            
            // 初始化一个单位矩阵作为基础
            Matrix4x4 lightViewProjection = Matrix4x4.identity;
            
            // 如果是聚光灯
            if (isSpotLight)
            {
                // 构建光源空间的VP矩阵（透视投影矩阵 * 缩放矩阵 * 光源的世界到局部矩阵）
                // 原理：这里乘以 Scale(1,1,-1) 是因为Unity是左手坐标系，而标准透视投影和裁剪平面提取算法通常基于右手坐标系，Z轴取反进行修正
                lightViewProjection = Matrix4x4.Perspective(light.spotAngle, 1, 0.03f, light.range)
                                 * Matrix4x4.Scale(new Vector3(1, 1, -1))
                                 * light.transform.worldToLocalMatrix;
                // 提取VP矩阵的每一行（行向量），矩阵转置后即为裁剪平面的法线系数
                var m0 = lightViewProjection.GetRow(0);
                var m1 = lightViewProjection.GetRow(1);
                var m2 = lightViewProjection.GetRow(2);
                var m3 = lightViewProjection.GetRow(3);
                
                // 根据图形学中的Lengyel算法，通过矩阵行向量的加减直接提取视锥体的6个裁剪平面（左、右、下、上、近、远）
                // 注意：因为外部定义了 planes.Add(-(m3 + m0))，所以这里实际上是提取方程的相反数，以符合Unity空间约定
                planes.Add(-(m3 + m0)); // 左平面
                planes.Add(-(m3 - m0)); // 右平面
                planes.Add(-(m3 + m1)); // 下平面
                planes.Add(-(m3 - m1)); // 上平面
                // 注释掉了近平面，因为Shader中已经用相机的Near Plane做了起始限制，这里不需要光源的近平面
                // planes.Add( -(m3 + m2)); // ignore near
                planes.Add(-(m3 - m2)); // 远平面 (光源的Range边界)
            }
            // 如果是方向光
            else if (isDirectionalLight)
            {
                // 获取相机的VP矩阵（投影矩阵 * 视图矩阵）
                // why camera? 解释：方向光没有"范围"限制，它充满整个空间。因此Ray Marching的有效范围就是相机的视锥体。这里只提取相机的近裁剪面作为起始边界。
                lightViewProjection = camera.projectionMatrix * camera.worldToCameraMatrix; 
                // 提取第三行和第四行
                var m2 = lightViewProjection.GetRow(2);
                var m3 = lightViewProjection.GetRow(3);
                // 仅添加近平面。这样Shader中方向光的Ray Marching就会从相机近裁剪面开始，到物体表面或远裁剪面结束
                planes.Add(-(m3 + m2)); // near plane only
            }

            // 返回计算好的平面方程列表给调用方（通常是RenderFeature）
            return planes;
        }

        // 私有方法：构建一个标准的1x1x1单位立方体Mesh作为默认边界（用于方向光或其他回退情况）
        private void Reset()
        {
            // 定义立方体的8个顶点局部坐标
            volumeMesh.vertices = new Vector3[]
            {
                new Vector3(-1, -1, -1), // 0: 左下后
                new Vector3(-1, 1, -1),  // 1: 左上后
                new Vector3(1, 1, -1),   // 2: 右上后
                new Vector3(1, -1, -1),  // 3: 右下后
                new Vector3(-1, -1, 1),  // 4: 左下前
                new Vector3(-1, 1, 1),   // 5: 左上前
                new Vector3(1, 1, 1),    // 6: 右上前
                new Vector3(1, -1, 1),   // 7: 右下前
            };
            // 定义构成6个面的12个三角形的顶点索引顺序（按照逆时针为正面）
            volumeMesh.triangles = new int[]
            {
                0, 1, 2, 0, 2, 3, // 后面
                0, 4, 5, 0, 5, 1, // 左面
                1, 5, 6, 1, 6, 2, // 上面
                2, 6, 7, 2, 7, 3, // 右面
                0, 3, 7, 0, 7, 4, // 下面
                4, 6, 5, 4, 7, 6, // 前面
            };
            // 根据顶点和三角形重新计算法线信息，保证Gizmos线框显示和Mesh碰撞/渲染正常
            volumeMesh.RecalculateNormals();
            // 立即调用UpdateMesh，如果是聚光灯，会将这个方块替换为锥体；如果是方向光，则保持方块
            UpdateMesh();
        }
        
        // 私有方法：根据当前光源类型和参数，重新生成具体的边界Mesh（目前只实现了聚光灯锥体）
        private void UpdateMesh()
        {
            // 如果是聚光灯，需要构建一个锥形网格来匹配光照范围
            if (isSpotLight)
            {
                // 根据聚光灯的张角计算在距离为1时，光照半径的正切值。 Deg2Rad将角度转弧度
                var tanFov = Mathf.Tan(light.spotAngle / 2 * Mathf.Deg2Rad);
                // 在局部空间（光源原点在(0,0,0)，向前照射为+Z轴）下，构建一个5个顶点的锥体：
                // 顶点0是光源中心，顶点1~4是在Z轴正方向(距离为light.range)的边界矩形
                var verts = new Vector3[]
                {
                    new Vector3(0, 0, 0), // 锥体顶点（光源位置）
                    new Vector3(-tanFov, -tanFov, 1) * light.range, // 左下角远端点
                    new Vector3(-tanFov, tanFov, 1) * light.range,  // 左上角远端点
                    new Vector3(tanFov, tanFov, 1) * light.range,   // 右上角远端点
                    new Vector3(tanFov, -tanFov, 1) * light.range,  // 右下角远端点
                };
                // 清空Mesh原来的数据
                volumeMesh.Clear();
                // 赋值新的顶点
                volumeMesh.vertices = verts;
                // 定义8个三角形来构成锥体的侧面和底面
                volumeMesh.triangles = new int[]
                {
                    0, 1, 2, // 侧面1
                    0, 2, 3, // 侧面2
                    0, 3, 4, // 侧面3
                    0, 4, 1, // 侧面4
                    1, 4, 3, // 底面三角1
                    1, 3, 2, // 底面三角2
                };
                // 重新计算法线
                volumeMesh.RecalculateNormals();
                
                // 更新记录的光照参数，标记为"干净"状态，避免下一帧重复生成Mesh
                previousAngle = light.spotAngle;
                previousRange = light.range;
            }
        }

        // 私有方法：判断光源参数是否发生了改变
        private bool IsDirty()
        {
            // 比较当前的SpotAngle和Range与记录的值是否不同。
            // 使用Mathf.Approximately而不是直接用==，是因为浮点数在编辑器中拖动时会产生极小的精度误差，直接==会失效
            return !Mathf.Approximately(light.spotAngle, previousAngle) ||
                   !Mathf.Approximately(light.range, previousRange);
        }
        
        // 公开方法：将面板上的"可见距离"转化为Shader中真正需要的"消光系数"
        public float GetExtinction()
        {
            // 核心物理数学公式：消光系数 σ = ln(10) / 可见距离 d
            // 原理：在物理的比尔-朗伯定律中，透射率 T = e^(-σ * d)。
            // 当我们定义"可见距离"时，通常指光衰减到原来的 1/10 时的距离（即 T=0.1）。
            // 代入公式：0.1 = e^(-σ * d) -> 两边取自然对数 ln(0.1) = -σ * d -> -ln(10) = -σ * d -> σ = ln(10) / d。
            // 这样将难懂的物理系数封装成了美术极易理解的"多少米外光消失"的距离参数。
            return Mathf.Log(10f) / visibilityDistance;
        }
    }
}
