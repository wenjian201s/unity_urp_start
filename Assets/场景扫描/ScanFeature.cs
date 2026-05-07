using Cysharp.Threading.Tasks; // 引入 UniTask 异步库；用于在 Unity 中用 async/await 等待帧、执行异步扫描生成逻辑，比普通 Task 更适合 Unity 主线程环境。
using DG.Tweening; // 引入 DOTween 动画库；用于对材质参数做渐变动画，例如扫描半径、亮度、透明度随时间变化。
using System; // 引入 System 命名空间；这里主要用到 Array.Clear 等基础 API。
using Unity.Profiling; // 引入 Unity Profiling 工具；用于 ProfilerMarker 统计生成地形标记的性能开销。
using UnityEngine; // 引入 UnityEngine 核心命名空间；提供 Vector3、Color、Material、GameObject、Physics、Camera 等 Unity 常用类型。
using UnityEngine.Rendering; // 引入 Unity 渲染命名空间；提供 CommandBuffer、RTHandle、GraphicsBuffer、RenderTextureDescriptor 等渲染相关类型。
using UnityEngine.Rendering.Universal; // 引入 URP 命名空间；提供 ScriptableRendererFeature、ScriptableRenderPass、RenderingData、RenderPassEvent 等 URP 扩展接口。
using UnityEngine.Serialization; // 引入序列化兼容工具；用于 FormerlySerializedAs，避免字段改名后 Inspector 中旧数据丢失。
using Random = UnityEngine.Random; // 给 UnityEngine.Random 起别名 Random；避免和 System.Random 产生歧义。
public class ScanFeature : ScriptableRendererFeature { // 定义一个 URP Renderer Feature；它可以向 URP 渲染流程中插入自定义 RenderPass，实现屏幕扫描后处理和地形标记渲染。
	//创建一个setting，用来从外部输入材质和参数 // 原注释：Settings 用来暴露材质和扫描参数，让用户能在 Renderer Feature Inspector 面板中配置。
	[System.Serializable] // 标记 Settings 可被 Unity 序列化；这样它的字段会显示在 Inspector，并保存到资源配置中。
	public class Settings { // 定义内部配置类；存放扫描效果材质、颜色、宽度、亮度、标记材质和粒子预制体等参数。
		public RenderPassEvent renderEvent = RenderPassEvent.BeforeRenderingTransparents; // 指定自定义 Pass 插入 URP 的时机；默认在透明物体渲染前执行扫描效果。
		[FormerlySerializedAs( "scanShader" )] // 字段改名兼容；以前如果字段叫 scanShader，Unity 会把旧序列化数据迁移到 scanMaterial。
		public Material scanMaterial; // 扫描后处理材质；通常使用前面那个 Unlit/Scan Shader，用深度纹理生成扫描线和外轮廓。

		[Header( "Static Settings" )] // Inspector 分组标题；下面是相对固定的扫描外观参数。
		public Color scanColorHead = Color.blue; // 扫描头颜色；传给 Shader 的 scanColorHead，用于最前沿扫描环颜色。
		public Color scanColor = Color.blue; // 普通扫描线和描边颜色；传给 Shader 的 scanColor。
		public float outlineWidth = 0.1f; // 外轮廓采样宽度；影响 Shader 中 Sobel 深度描边的 UV 采样偏移。
		public float scanLineWidth = 1f; // 普通扫描线宽度；控制扫描线在距离周期中的厚度。
		public float scanLineInterval = 1f; // 普通扫描线间隔；距离除以该值再 frac，形成一圈圈重复扫描线。
		public float headScanLineWidth = 1f; // 扫描头宽度；控制最前沿扫描环的厚度。

		[Header( "Dynamics Settings(control by code)" )] // Inspector 分组标题；下面参数运行时会被代码和 DOTween 动态修改。
		public float scanLineBrightness = 1f; // 普通扫描线亮度；传给 Shader 控制扫描线强度。
		public float scanRange = 1f; // 扫描线显示范围；控制扫描头后方多大范围内能看到普通扫描线。
		public float outlineBrightness = 1f; // 外轮廓亮度；控制深度描边叠加强度。
		public float headScanLineDistance = 8f; // 扫描头距离中心的半径；随时间增大，形成向外扩散的扫描波。
		public Vector3 scanCenterWS = new Vector3( 123.05f, 36.3f, 147.86f ); // 扫描中心世界坐标；Shader 根据每个像素到该点的距离生成扫描效果。
		public float outlineStarDistance = 30f; // 外轮廓开始出现的距离；传给 Shader 后控制描边在扫描过程中渐显。

		[Header( "Render Mark" )] // Inspector 分组标题；下面是地形标记渲染相关资源。
		public Material markMaterial; // 地形标记材质；通常使用 TerrianMarks Shader，通过 GPU Instancing 批量画图标。
		public GameObject markParticle3; // 类型 3 标记对应的粒子预制体；通常用于危险区域红叉特效。
		public GameObject markParticle2; // 类型 2 标记对应的粒子预制体；通常用于警告区域特效。
		public GameObject markParticle1; // 类型 1 标记对应的粒子预制体；通常用于安全区域或普通提示粒子。
	} // Settings 类结束。

	public Settings settings = new Settings(); // 创建默认配置对象；Unity Inspector 会显示并序列化该对象中的字段。

	static ScanFeature _instance; // 保存当前 ScanFeature 的静态实例；静态方法 ExecuteScan/StartScan 通过它访问 settings。

	//新建一个CustomRenderPass // 原注释：自定义渲染 Pass 实例。
	CustomRenderPass _myPass; // 保存自定义 RenderPass；Create 中创建，AddRenderPasses 中注入 URP。

	readonly static int ScanColorHead = Shader.PropertyToID( "scanColorHead" ); // 将 Shader 属性名转成整数 ID；比每帧用字符串设置材质参数更高效。
	readonly static int ScanColor = Shader.PropertyToID( "scanColor" ); // 普通扫描颜色的 Shader 属性 ID。

	readonly static int OutlineWidth = Shader.PropertyToID( "outlineWidth" ); // 外描边宽度属性 ID。
	readonly static int OutlineBrightness = Shader.PropertyToID( "outlineBrightness" ); // 外描边亮度属性 ID。
	readonly static int OutlineStarDistance = Shader.PropertyToID( "outlineStarDistance" ); // 外描边开始距离属性 ID。

	readonly static int ScanLineWidth = Shader.PropertyToID( "scanLineWidth" ); // 普通扫描线宽度属性 ID。
	readonly static int ScanLineInterval = Shader.PropertyToID( "scanLineInterval" ); // 扫描线间隔属性 ID。
	readonly static int ScanLineBrightness = Shader.PropertyToID( "scanLineBrightness" ); // 扫描线亮度属性 ID。
	readonly static int ScanRange = Shader.PropertyToID( "scanRange" ); // 扫描线范围属性 ID。

	readonly static int HeadScanLineDistance = Shader.PropertyToID( "headScanLineDistance" ); // 扫描头半径属性 ID；DOTween 会不断改变这个值，让扫描波向外推进。
	readonly static int HeadScanLineWidth = Shader.PropertyToID( "headScanLineWidth" ); // 扫描头宽度属性 ID。
	readonly static int HeadScanLineBrightness = Shader.PropertyToID( "headScanLineBrightness" ); // 扫描头亮度属性 ID。
	readonly static int ScanCenterWs = Shader.PropertyToID( "scanCenterWS" ); // 扫描中心世界坐标属性 ID。

	// 地形标记的参数 // 原注释：下面是传给地形标记 Shader 的参数。
	readonly static int ColorAlpha = Shader.PropertyToID( "colorAlpha" ); // 地形标记整体透明度属性 ID；用于控制标记淡入淡出。


	static bool canScan = true; // 扫描冷却开关；true 表示当前允许触发扫描，false 表示扫描动画尚未结束，防止重复触发。
	static bool showMark = false; // 是否绘制地形标记；StartScan 时设为 true，标记淡出完成后设为 false。
	static Tween markTween; // 保存地形标记透明度淡出动画；下次扫描前可以 Kill 掉旧动画，避免多个 Tween 冲突。

	public static void ExecuteScan( Transform player ) { // 对外暴露的静态扫描入口；传入玩家 Transform 作为扫描中心和方向参考。
		StartScan( player ).Forget(); // 启动异步扫描流程；Forget 表示不等待返回值，同时忽略 UniTask 的 await。
	} // ExecuteScan 结束。

	static async UniTaskVoid StartScan( Transform player ) { // 扫描主流程；异步执行材质动画、生成地形标记，并且不返回结果。
		if( !canScan ) { // 如果当前正在扫描中，则不允许再次触发。
			return; // 直接退出，避免重复扫描导致材质动画和标记状态混乱。
		} // canScan 判断结束。
		canScan = false; // 进入扫描状态，禁止再次触发扫描。
		showMark = true; // 开启地形标记绘制；RenderPass 的 Execute 中会根据它决定是否 DrawMeshInstancedIndirect。

		// 万一上一个mark还没消失，手动取消 // 原注释：避免上一次标记淡出动画还在运行。
		markTween?.Kill(); // 如果 markTween 不为空，则停止旧的 Tween；防止旧动画继续修改 colorAlpha。
		var scanCenter = player.position - player.forward * 2; // 计算扫描中心；设置在玩家身后/脚下一点的位置，使扫描波从玩家附近扩散。

		var material = _instance.settings.scanMaterial; // 获取扫描后处理材质；后续修改它的 Shader 参数。
		var markMaterial = _instance.settings.markMaterial; // 获取地形标记材质；后续控制标记透明度和 GPU Buffer。
		material.SetVector( ScanCenterWs, scanCenter ); // 把本次扫描中心传给扫描 Shader；Shader 用世界坐标距离生成波纹。

		// 控制扫描线前进 // 原注释：控制扫描头半径从近处扩散到远处。
		material.SetFloat( HeadScanLineDistance, 4 ); // 初始化扫描头半径为 4；表示扫描从离中心不远的地方开始。
		material.DOFloat( 250, HeadScanLineDistance, 3.5f ).SetEase( Ease.InSine ).onComplete += () => { // 用 DOTween 在 3.5 秒内把扫描半径推进到 250，Ease.InSine 让前期较慢、后期加速；完成后执行回调。
			canScan = true; // 扫描推进完成后重新允许下一次扫描。
		}; // 扫描头半径 Tween 设置结束。

		// 随着距离前进，扫描范围变大 // 原注释：扫描扩散时，普通扫描线的影响范围也逐渐扩大。
		material.SetFloat( ScanRange, 1 ); // 初始化扫描范围为 1。
		material.DOFloat( 5, ScanRange, 1.5f ).SetEase( Ease.InSine ).SetDelay( 1 ); // 延迟 1 秒后，在 1.5 秒内把扫描范围从 1 增加到 5，让扫描后方线条覆盖更宽区域。

		// 控制扫描线和最前方的扫描线颜色颜色 // 原注释：控制普通扫描线和扫描头亮度的淡入淡出。
		material.SetFloat( ScanLineBrightness, 0.3f ); // 初始普通扫描线亮度为 0.3，避免开始时完全不可见。
		material.SetFloat( HeadScanLineBrightness, 0 ); // 初始扫描头亮度为 0，稍后快速淡入。
		material.DOFloat( 1, ScanLineBrightness, 0.2f ).SetDelay( 0.25f ); // 延迟 0.25 秒后，用 0.2 秒把普通扫描线亮度提升到 1。
		material.DOFloat( 1, HeadScanLineBrightness, 0.1f ).SetDelay( 0.25f ); // 延迟 0.25 秒后，用 0.1 秒把扫描头亮度提升到 1，形成瞬间亮起的扫描前沿。
		material.DOFloat( 0, ScanLineBrightness, 0.5f ).SetDelay( 2.25f ).SetEase( Ease.Linear ); // 2.25 秒后，用 0.5 秒把普通扫描线亮度淡出到 0。
		material.DOFloat( 0, HeadScanLineBrightness, 0.5f ).SetDelay( 2.25f ).SetEase( Ease.Linear ); // 2.25 秒后，用 0.5 秒把扫描头亮度淡出到 0。

		// 控制轮廓 // 原注释：控制扫描过程中物体边缘描边的显示。
		material.SetFloat( OutlineBrightness, 1 ); // 初始化描边亮度为 1，让扫描开始时边缘可见。
		material.SetFloat( OutlineStarDistance, 0 ); // 初始化描边开始距离为 0，表示描边从扫描中心附近开始出现。
		material.DOFloat( 0, OutlineBrightness, 0.5f ).SetDelay( 2.25f ).SetEase( Ease.Linear ); // 2.25 秒后把描边亮度淡出，避免扫描结束后轮廓仍停留。
		material.DOFloat( 30, OutlineStarDistance, 1f ).SetEase( Ease.InCubic ); // 在 1 秒内把描边开始距离推到 30，使描边区域随扫描波向外移动。

		// 控制地形标记的透明度 // 原注释：让地形标记出现后停留，再淡出。
		markMaterial.SetFloat( ColorAlpha, 0 ); // 初始标记透明度为 0，避免突然出现。
		markMaterial.DOFloat( 1, ColorAlpha, 1f ); // 1 秒内把标记透明度提升到 1，实现淡入。
		markTween = markMaterial.DOFloat( 0, ColorAlpha, 1f ).SetDelay( 7 ); // 延迟 7 秒后，用 1 秒淡出标记，并保存 Tween 句柄。
		markTween.onComplete += () => { // 标记淡出动画完成后执行回调。
			showMark = false; // 停止绘制地形标记，RenderPass 将不再执行 DrawMeshInstancedIndirect。
		}; // 标记淡出完成回调结束。

		//生成地形标记 // 原注释：开始根据地面碰撞结果生成扫描标记数据。
		await GenerateTerrainMarks( player ); // 异步生成地形标记；每生成一行等待一帧，避免一次性 Raycast 造成卡顿。
	} // StartScan 函数结束。


	static ProfilerMarker _generateTerrainMarks = new ProfilerMarker( "GenerateTerrainMarks" ); // 创建 Profiler 标记；用于在 Unity Profiler 中查看每行地形标记生成耗时。
	struct Marks { // 定义地形标记数据结构；需要和 TerrianMarks Shader 中的 StructuredBuffer<Marks> 布局对应。
		public Vector3 markPosition; // 标记位置；对应 Shader 中的 float3 position，表示图标中心世界坐标。
		public int markCategory; // 标记分类；对应 Shader 中的 int type，用于决定安全、警告、危险图案。
	} // Marks 结构体结束。
	static Marks[] _marks; // 存每个标记的数据 // CPU 端标记数组；每次扫描后写入，再上传到 ComputeBuffer 给 GPU 绘制。
	const int horizentalCount = 70; // 横向的列数 // 横向采样点数量；注意单词应为 horizontal，但拼写不影响功能。
	const int verticalCount = 50; // 向前的点行数 // 纵向采样点数量；总标记数为 70 * 50 = 3500。
	const float gridStep = 0.5f; // 两个点之间的距离 // Raycast 网格间距；值越小扫描越密集，但物理检测开销越高。

	static void ShootParticle( Vector3 position, Vector3 normal, int index = 3 ) { // 在某个地形点生成粒子特效；position 是命中点，normal 是表面法线，index 决定使用哪个粒子预制体。
		float distanceToCamera01 = Vector3.Distance( position, Camera.main.transform.position ) / 20 + 0.5f; // 根据点到相机距离计算缩放倍率；距离越远粒子越大，保持屏幕视觉大小相对稳定。

		GameObject instance; // 声明即将实例化出来的粒子对象引用。
		switch( index ) { // 根据 index 选择不同粒子预制体。
			case 3: // index 为 3，通常表示危险粒子。
				instance = Instantiate( _instance.settings.markParticle3 ); // 实例化危险类型粒子预制体。
				break; // 跳出 switch。
			case 2: // index 为 2，通常表示警告粒子。
				instance = Instantiate( _instance.settings.markParticle2 ); // 实例化警告类型粒子预制体。
				break; // 跳出 switch。
			default: // 其他 index，默认使用普通粒子。
				instance = Instantiate( _instance.settings.markParticle1 ); // 实例化普通/安全类型粒子预制体。
				break; // 跳出 switch。
		} // switch 结束。
		instance.transform.position = position; // 把粒子放到 Raycast 命中的地形点上。
		instance.transform.localScale = Random.Range( 0.5f, 1.5f ) * Vector3.one * distanceToCamera01; // 随机设置粒子整体大小，并根据相机距离放大，增加视觉变化。
		instance.transform.GetChild( 0 ).localScale = Random.Range( 2f, 5f ) * Vector3.one * distanceToCamera01; // 随机设置子物体缩放，通常用于粒子内部光圈/扩散环，增强扫描反馈。
	} // ShootParticle 函数结束。

	static async UniTask GenerateTerrainMarks( Transform player ) { // 异步生成地形标记；通过从上往下 Raycast 扫描玩家前方地形。
		// 每次扫描前清空数组 // 原注释：避免上一轮扫描遗留标记数据。
		Array.Clear( _marks, 0, _marks.Length ); // 把 _marks 数组清零；markPosition 变为 Vector3.zero，markCategory 变为 0。
		var forward = player.forward; // 获取玩家前方向；用于决定扫描网格向前展开的方向。
		var right = player.right; // 获取玩家右方向；用于决定扫描网格横向展开的方向。


		// 把撒点的初始位置顶到角色头顶的左后方 // 原注释：从玩家附近上方开始，向下投射射线寻找地面。
		Vector3 position = player.position - forward * 2 + Vector3.up * 100; // 设置射线起始基准点：玩家身后 2 米、向上 100 米，确保可以向下打到地面。
		var rayCastPos = position - right * horizentalCount / 2 * gridStep - forward * ( 3 * gridStep ); // 计算第一行第一个采样点：从基准点向左移动半个网格宽度，并稍微向后偏移。

		// 横向纵向套两个循环，不断碰撞检测和写入数组 // 原注释：用二维网格 Raycast 采样地形。
		for( int i = 0; i < verticalCount; i++ ) { // 外层循环控制向前的行数；每一行对应一个前后方向的位置。
			_generateTerrainMarks.Begin(); // 开始 Profiler 采样；统计当前行 Raycast 和标记分类开销。
			for( int j = 0; j < horizentalCount; j++ ) { // 内层循环控制横向列数；每一列对应一个左右方向的位置。
				Physics.Raycast( rayCastPos, Vector3.down, out RaycastHit hit, 300, LayerMask.GetMask( "Scan", "Road" ) ); // 从当前网格点向下发射 300 米射线，只检测 Scan 和 Road 图层，用于找地面或扫描区域。
				if( hit.collider is null ) { // 如果射线没有打到任何碰撞体。
					rayCastPos += right * gridStep; // 横向移动到下一个采样点。
					continue; // 跳过当前点，不写入标记数据。
				} // 未命中判断结束。
				var normal = hit.normal; // 获取命中表面的法线；normal.y 越接近 1，表示表面越平坦朝上。

				// 根据法线的纵向值来判断斜率，设置该点的标志是什么 // 原注释：用地面坡度判断安全/警告/危险。
				if( hit.collider.isTrigger ) { // 如果先命中的是 Trigger 碰撞体，通常表示特殊扫描区域或标记区域。
					Physics.Raycast( rayCastPos, Vector3.down, out hit, 300, LayerMask.GetMask( "Scan" ) ); // 再只对 Scan 图层做一次 Raycast，获取真正要显示标记的位置。
					_marks[i * horizentalCount + j].markCategory = 0; // 设置类型 0；在 TerrianMarks Shader 中通常绘制安全圆环。
					_marks[i * horizentalCount + j].markPosition = hit.point; // 保存标记世界坐标为命中点。
				} else if( normal.y < 0.75f ) { // 如果表面法线 y 小于 0.75，说明坡度较陡或接近垂直，归为危险区域。
					_marks[i * horizentalCount + j].markCategory = 3; // 设置类型 3；在标记 Shader 中通常绘制危险红叉。
					// 红叉只有33%的概率出现 // 原注释写 33%，实际判断是 0.3，即 30% 概率。
					if( Random.Range( 0f, 1f ) < 0.3f ) { // 以 30% 概率真正写入危险标记位置，降低红叉数量，避免画面过密。
						_marks[i * horizentalCount + j].markPosition = hit.point; // 保存危险标记位置。
						ShootParticle( hit.point, normal, 3 ); // 在危险点生成类型 3 粒子特效，加强危险反馈。
					} // 危险点随机显示判断结束。
				} else if( normal.y < 0.85f ) { // 如果法线 y 小于 0.85 但大于等于 0.75，说明坡度中等，归为警告区域。
					_marks[i * horizentalCount + j].markCategory = 2; // 设置类型 2；在标记 Shader 中通常显示黄色警告点。
					_marks[i * horizentalCount + j].markPosition = hit.point; // 保存警告标记位置。
					if( Random.Range( 0f, 1f ) < 0.0003 ) { // 极低概率生成额外粒子，避免普通区域特效过多。
						ShootParticle( hit.point, normal, 1 ); // 生成普通类型粒子特效。
					} // 警告点随机粒子判断结束。
				} else { // 其他情况说明表面较平坦，归为安全区域。
					_marks[i * horizentalCount + j].markCategory = 1; // 设置类型 1；在标记 Shader 中通常显示安全圆点。
					_marks[i * horizentalCount + j].markPosition = hit.point; // 保存安全标记位置。
					if( Random.Range( 0f, 1f ) < 0.0002 ) { // 极低概率生成安全粒子，增加细节但控制性能和视觉密度。
						ShootParticle( hit.point, normal, 1 ); // 生成普通粒子特效。
					} // 安全点随机粒子判断结束。
				} // 地形分类判断结束。

				rayCastPos += right * gridStep; // 当前列处理完成后，射线位置向右移动一个网格间隔。

				// debug 显示绘制 // 原注释：下面被注释的代码用于 Scene 视图调试法线和坡度分类。
				// if( hit.normal.y < 0.8f ) { // 如果坡度较陡，则画红色法线调试线。
				// 	Debug.DrawLine( hit.point, hit.point + hit.normal * 0.2f, Color.red, 10 ); // 绘制从命中点沿法线方向的红线，持续 10 秒。
				// } else if( hit.normal.y < 0.9f ) { // 如果坡度中等，则画黄色法线调试线。
				// 	Debug.DrawLine( hit.point, hit.point + hit.normal * 0.2f, Color.yellow, 10 ); // 绘制黄色法线，辅助观察警告区域。
				// } else { // 如果较平坦，则画青色法线调试线。
				// 	Debug.DrawLine( hit.point, hit.point + hit.normal * 0.2f, Color.cyan, 10 ); // 绘制青色法线，辅助观察安全区域。
				// } // 调试绘制条件结束。
			} // 内层横向循环结束。
			_generateTerrainMarks.End(); // 结束当前行 Profiler 采样。

			rayCastPos -= right * horizentalCount * gridStep; // 一行结束后，把采样点从最右侧移回最左侧。
			rayCastPos += forward * gridStep; // 再向玩家前方移动一格，准备扫描下一行。
			
			//每次生成一行地形标记后，等待一帧，并绘制当前帧的地形标记 // 原注释：分帧生成，降低单帧卡顿。
			await UniTask.Yield(); // 等待一帧；这样 50 行 Raycast 会分 50 帧完成，扫描标记可以逐行出现。

		
		} // 外层纵向循环结束。
	} // GenerateTerrainMarks 函数结束。


	/// <summary> // XML 文档注释开始；用于描述下面的内部类。
	/// 这里是自定义的渲染pass // 注释内容：CustomRenderPass 是真正插入 URP 渲染流程的自定义 Pass。
	/// </summary> // XML 文档注释结束。
	class CustomRenderPass : ScriptableRenderPass { // 定义自定义渲染 Pass；继承 ScriptableRenderPass，重写 OnCameraSetup、Execute 等方法。
		//创建RTHandle,用来存储相机的颜色和深度缓冲区 // 原注释：下面保存渲染目标句柄。
		RTHandle _cameraColor; // 相机颜色缓冲句柄；扫描效果最终会写到这里。
		RTHandle _cameraDepth; // 相机深度缓冲句柄；扫描 Shader 会把它作为输入采样，同时标记绘制也使用它做深度测试。
		RTHandle _cameraNormal; // 相机法线缓冲句柄；当前代码没有实际赋值和使用，可能是预留给法线描边或调试。
		RTHandle _tempTex; // 临时渲染纹理句柄；当前 OnCameraSetup 分配了它，但 Execute 中实际没有使用它作为最终 Blit 目标。
		//纹理描述器 // 原注释：描述临时 RT 的尺寸、格式、深度位等。
		RenderTextureDescriptor m_Descriptor; // 临时纹理描述器；用于 ReAllocateIfNeeded 创建 _tempTex。
		//cmd name // 原注释：CommandBuffer 名称。
		string _passName; // Pass 名称；用于 CommandBuffer 和 Frame Debugger/Profiler 显示。
		Settings settings; // 保存外部传入的配置引用；Execute 中需要访问 scanMaterial、markMaterial 等。

		GraphicsBuffer _graphicsBuffer; // 间接绘制参数 Buffer；DrawMeshInstancedIndirect 会从这里读取实例数量和索引数量。
		GraphicsBuffer.IndirectDrawIndexedArgs[] _commandData; // CPU 端间接绘制命令数组；之后上传到 _graphicsBuffer。
		ComputeBuffer _computeBuffer; // 存放地形标记数据的 GPU Buffer；传给 markMaterial 的 StructuredBuffer<Marks>。
		//初始类的时候传入材质 // 原注释：构造函数中初始化材质参数和 GPU 资源。

		Mesh mesh; // 用于绘制每个标记的基础网格；这里手动创建一个由 6 个顶点组成的矩形，两组三角形。
		public CustomRenderPass( Settings settings ) { // CustomRenderPass 构造函数；创建 Buffer、Mesh，并初始化扫描材质参数。
			_graphicsBuffer = new GraphicsBuffer( GraphicsBuffer.Target.IndirectArguments, 1, GraphicsBuffer.IndirectDrawIndexedArgs.size ); // 创建间接绘制参数 Buffer；目标类型为 IndirectArguments，包含 1 条绘制命令。
			_commandData = new GraphicsBuffer.IndirectDrawIndexedArgs[1]; // 创建 CPU 端绘制命令数组；长度为 1，对应一次间接实例化绘制。
			_computeBuffer = new ComputeBuffer( horizentalCount * verticalCount, sizeof( float ) * 4 ); // 创建标记数据 Buffer；每个 Marks 约等于 float3 + int，即 4 个 32 位数。

			mesh = new Mesh{ // 创建一个新 Mesh；用于作为每个标记实例的基础四边形。
				vertices = new Vector3[6], // 创建 6 个顶点位置；因为 TerrianMarks Shader 顶点阶段主要使用 UV 和 instanceID，顶点坐标本身可以为空默认值。
				uv = new[]{ // 定义 6 个顶点 UV；两个三角形组成一个完整方形。
					new Vector2( 0, 0 ), // 第 1 个顶点 UV，左下角。
					new Vector2( 1, 1 ), // 第 2 个顶点 UV，右上角。
					new Vector2( 0, 1 ), // 第 3 个顶点 UV，左上角。
					new Vector2( 0, 0 ), // 第 4 个顶点 UV，左下角，第二个三角形复用。
					new Vector2( 1, 0 ), // 第 5 个顶点 UV，右下角。
					new Vector2( 1, 1 ), // 第 6 个顶点 UV，右上角。
				} // UV 数组结束。
			}; // Mesh 初始化结束。

			var scanMaterial = settings.scanMaterial; // 缓存扫描材质引用，减少重复访问 settings。

			scanMaterial.SetColor( ScanColorHead, settings.scanColorHead ); // 把扫描头颜色写入材质，对应 Shader 的 scanColorHead。
			scanMaterial.SetColor( ScanColor, settings.scanColor ); // 把普通扫描线/描边颜色写入材质。
			scanMaterial.SetFloat( OutlineWidth, settings.outlineWidth ); // 初始化描边宽度参数。
			scanMaterial.SetFloat( OutlineBrightness, settings.outlineBrightness ); // 初始化描边亮度参数。
			scanMaterial.SetFloat( OutlineStarDistance, settings.outlineStarDistance ); // 初始化描边开始距离参数。

			scanMaterial.SetFloat( ScanLineWidth, settings.scanLineWidth ); // 初始化普通扫描线宽度参数。
			scanMaterial.SetFloat( ScanLineInterval, settings.scanLineInterval ); // 初始化普通扫描线间隔参数。
			scanMaterial.SetFloat( ScanLineBrightness, settings.scanLineBrightness ); // 初始化普通扫描线亮度参数。
			scanMaterial.SetFloat( ScanRange, settings.scanRange ); // 初始化扫描线范围参数。

			scanMaterial.SetFloat( HeadScanLineDistance, settings.headScanLineDistance ); // 初始化扫描头距离参数。
			scanMaterial.SetFloat( HeadScanLineWidth, settings.headScanLineWidth ); // 初始化扫描头宽度参数。

			scanMaterial.SetVector( ScanCenterWs, settings.scanCenterWS ); // 初始化扫描中心世界坐标。
			_passName = "ScanEffect"; // 设置 Pass/CommandBuffer 名称，方便 Frame Debugger 和 Profiler 中识别。
			this.settings = settings; // 保存设置对象引用，供 Execute 阶段访问。
		} // CustomRenderPass 构造函数结束。


		//在执行pass前执行，用来构造渲染目标和清除状态 // 原注释：OnCameraSetup 在 Pass 执行前被 URP 调用。
		//同样用来创建临时RT // 原注释：这里也分配临时纹理。
		//如果为空，则会渲染到激活的RT上 // 原注释：如果不配置目标，则使用当前活动渲染目标。
		public override void OnCameraSetup( CommandBuffer cmd, ref RenderingData renderingData ) { // Pass 执行前的设置函数；可以获取相机目标并分配临时 RT。
			//获得相机颜色缓冲区，存到_cameraColor里 // 原注释：获取当前相机颜色目标。
			_cameraColor = renderingData.cameraData.renderer.cameraColorTargetHandle; // 获取相机颜色 RTHandle；后续把扫描效果 Blit 到这里。
			_cameraDepth = renderingData.cameraData.renderer.cameraDepthTargetHandle; // 获取相机深度 RTHandle；用于扫描 Shader 采样深度和标记绘制深度测试。
			//获取屏幕纹理的描述器  // 原注释：创建与屏幕大小匹配的临时纹理描述。
			m_Descriptor = new RenderTextureDescriptor( Screen.width, Screen.height, RenderTextureFormat.Default, 0 ){ // 创建临时 RT 描述器；宽高使用屏幕尺寸，颜色格式为默认格式，不带深度。
				depthBufferBits = 0 //不需要深度缓冲区 // 临时纹理只存颜色，不需要自己的深度缓冲。
			}; // RenderTextureDescriptor 初始化结束。
			//新建纹理_tempTex // 原注释：按描述器创建或复用临时 RT。
			RenderingUtils.ReAllocateIfNeeded( ref _tempTex, m_Descriptor, FilterMode.Bilinear, TextureWrapMode.Clamp, name:"_TempTex" ); // 如果 _tempTex 不存在或描述不匹配，则重新分配；双线性过滤，Clamp 包裹，命名为 _TempTex。

			//这个用来在blit的时候指定目标RT（如果不指定，则默认为激活的RT） // 原注释：配置当前 Pass 的渲染目标。
			//blit如果不指定目标RT，则为这个RT // 原注释：设置默认渲染目标为 _tempTex。
			ConfigureTarget( _tempTex ); // 告诉 URP 当前 Pass 默认渲染到 _tempTex；但 Execute 中显式 Blit 到 _cameraColor，所以这里的实际作用较弱。
		} // OnCameraSetup 结束。

		//每帧会调用一次，应用Pass // 原注释：Execute 是自定义 Pass 的核心执行函数。
		public override void Execute( ScriptableRenderContext context, ref RenderingData renderingData ) { // 每个相机、每帧在指定 renderPassEvent 时机执行。
			//如果不是Game视图，就不执行 // 原注释：避免 SceneView 或 Preview 相机执行效果。
			if( renderingData.cameraData.camera.cameraType != CameraType.Game ) return; // 只在 Game 相机执行，防止编辑器 Scene 视图也出现扫描。
			//如果没有材质，就不执行 // 原注释：缺少扫描材质时直接跳过。
			if( settings.scanMaterial == null ) return; // 防止空引用异常。

			//新建一个CommandBuffer // 原注释：开始记录渲染命令。
			//CommandBufferPool.Get()会从一个池子里获取CommandBuffer，如果池子里没有可用的CommandBuffer，就会新建一个 // 原注释：使用池化降低 GC 和分配开销。
			CommandBuffer cmd = CommandBufferPool.Get( name:_passName ); // 从命令缓冲池取一个 CommandBuffer，并命名为 ScanEffect。

			//创建一个frame debugger的作用域 // 原注释：在 Frame Debugger/Profiler 中形成可见分组。
			using( new ProfilingScope( cmd, new ProfilingSampler( cmd.name ) ) ) { // 创建 ProfilingScope；其中记录的命令会归到该采样名称下。
				Blitter.BlitCameraTexture( cmd, _cameraDepth, _cameraColor, settings.scanMaterial, 0 ); // 把相机深度纹理作为源，经过 scanMaterial 的第 0 个 Pass 处理后写入相机颜色缓冲；这是扫描后处理的核心。

				if( showMark ) { // 如果当前需要显示地形标记，则执行 GPU 实例化绘制。
					cmd.SetRenderTarget( _cameraColor, _cameraDepth ); // 设置绘制目标为相机颜色和相机深度；颜色用于显示标记，深度用于和场景遮挡关系配合。
					var matProp = new MaterialPropertyBlock(); // 创建材质属性块；用于给本次绘制单独传入 markBuffer，不直接改材质资源。
					_computeBuffer.SetData( _marks ); // 将 CPU 端 _marks 数组上传到 GPU ComputeBuffer；Shader 的 StructuredBuffer 会读取这些标记位置和类型。
					matProp.SetBuffer( "markBuffer", _computeBuffer ); // 把 ComputeBuffer 绑定到材质属性块中的 markBuffer，对应 TerrianMarks Shader 的 StructuredBuffer<Marks>。
					_commandData[0].indexCountPerInstance = 6; // 设置每个实例绘制 6 个索引/顶点；对应一个由两个三角形组成的方形图标。
					_commandData[0].instanceCount = horizentalCount * verticalCount; // 设置实例数量为全部采样点数量，即 3500 个标记实例。
					_graphicsBuffer.SetData( _commandData ); // 把间接绘制参数上传到 GPU GraphicsBuffer。
					cmd.DrawMeshInstancedIndirect( mesh, 0, settings.markMaterial, 0, _graphicsBuffer, 0, matProp ); // 使用间接实例化绘制标记 Mesh；GPU 根据 instanceID 从 markBuffer 中读取每个标记的数据。
				} // showMark 判断结束。
			} // ProfilingScope 结束。

			//Blitter.BlitCameraTexture( cmd, _cameraColor, _tempTex );//blit效果到屏幕的color buffer上（后处理） // 被注释代码：原本可能用于把颜色缓冲复制到临时纹理，当前不执行。
			//执行、清空、释放 CommandBuffer // 原注释：提交命令并回收 CommandBuffer。
			context.ExecuteCommandBuffer( cmd ); // 把记录好的渲染命令提交给 ScriptableRenderContext 执行。
			cmd.Clear(); // 清空 CommandBuffer 内容，避免残留命令。
			CommandBufferPool.Release( cmd ); // 把 CommandBuffer 归还池中，减少频繁分配。
		} // Execute 结束。

		//清除任何分配的临时RT // 原注释：可在这里释放临时资源。
		public override void OnCameraCleanup( CommandBuffer cmd ) { // Pass 执行后清理函数；当前没有释放 _tempTex，因为 RTHandle 通常需要显式 Release 或生命周期管理。

		} // OnCameraCleanup 结束。

		~CustomRenderPass() { // 析构函数；对象被 GC 回收时调用，但 Unity 中不建议依赖析构函数释放 GPU 资源，因为时机不可控。
			_graphicsBuffer.Dispose(); // 释放间接绘制参数 GraphicsBuffer，避免 GPU 内存泄漏。
			_computeBuffer.Dispose(); // 释放标记数据 ComputeBuffer，避免 GPU 内存泄漏。
			Debug.Log( "释放buffer" ); // 输出日志，提示 Buffer 已释放。
		} // 析构函数结束。

	} // CustomRenderPass 类结束。

	/*************************************************************************/ // 分隔符注释；区分 RenderPass 内部类和 RendererFeature 生命周期方法。


	//当RendererFeature被创建、激活、改变参数时调用 // 原注释：Create 是 Renderer Feature 生命周期入口。
	public override void Create() { // URP 创建或刷新 Renderer Feature 时调用；通常在这里初始化自定义 Pass。
		if( settings.scanMaterial == null ) return; // 如果没有扫描材质，直接退出，避免创建无效 Pass。
		if( !Application.isPlaying ) return; // 如果不是播放模式，直接退出；因此该效果不会在编辑模式预览中初始化。

		_marks = new Marks[horizentalCount * verticalCount]; // 创建 CPU 端标记数组；总数量为横向列数乘纵向行数。
		//初始化CustomRenderPass // 原注释：创建自定义渲染 Pass。
		_myPass = new CustomRenderPass( settings ); // 创建 CustomRenderPass，并把配置传入构造函数。
		_instance = this; // 保存静态实例，让静态扫描入口能够访问当前 RendererFeature 的 settings。
	} // Create 结束。

	public override void SetupRenderPasses( ScriptableRenderer renderer, in RenderingData renderingData ) { // URP 14/Unity 2022 中用于在添加 Pass 前配置输入资源和 Pass 参数。
		if( settings.scanMaterial == null ) return; // 如果没有扫描材质，跳过配置。
		if( !Application.isPlaying ) return; // 非播放模式不执行配置。

		if( renderingData.cameraData.cameraType == CameraType.Game ) { // 只对 Game 相机配置扫描 Pass。
			_myPass.renderPassEvent = settings.renderEvent; // 设置 Pass 插入渲染管线的时机，例如透明物体前。
			//声明要使用的颜色和深度缓冲区 // 原注释：告诉 URP 这个 Pass 需要哪些相机纹理输入。
			_myPass.ConfigureInput( ScriptableRenderPassInput.Color ); // 声明需要相机颜色输入；URP 会确保颜色纹理可用。
			_myPass.ConfigureInput( ScriptableRenderPassInput.Normal ); // 声明需要法线输入；URP 会生成/提供法线纹理，但当前 C# 中没有直接读取，可能供 Shader 使用或预留。
			_myPass.ConfigureInput( ScriptableRenderPassInput.Depth ); // 声明需要深度输入；这是扫描 Shader 从深度重建世界坐标的关键。
		} // Game 相机判断结束。
	} // SetupRenderPasses 结束。

	//对每个相机调用一次，用来注入ScriptableRenderPass  // 原注释：把自定义 Pass 加入当前相机的渲染队列。
	public override void AddRenderPasses( ScriptableRenderer renderer, // AddRenderPasses 是 RendererFeature 注入 Pass 的入口；第一个参数是当前 Renderer。
		ref RenderingData renderingData ) { // 第二个参数包含当前相机和渲染帧数据。
		if( settings.scanMaterial == null ) return; // 如果没有扫描材质，跳过注入。
		if( !Application.isPlaying ) return; // 非播放模式不注入。

		//注入CustomRenderPass，这样每帧就会调用CustomRenderPass的Execute()方法 // 原注释：把 Pass 加入 URP 执行队列。
		renderer.EnqueuePass( _myPass ); // 将自定义扫描 Pass 加入当前 Renderer；到指定 renderPassEvent 时 URP 会调用 Execute。
	} // AddRenderPasses 结束。
} // ScanFeature 类结束。
