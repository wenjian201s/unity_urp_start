using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;

// 引入 UnityEditor 命名空间。
// 注意：
// 只要脚本使用 UnityEditor，它就只能在 Unity 编辑器中运行，
// 不能被打包进最终游戏。
// 所以这个脚本通常要放在 Assets/Editor 文件夹下。
using UnityEditor;

using UnityEngine;

// 这里给 UnityEngine.Object 起了一个别名 Object。
// 原因：
// C# 自带 object 类型，Unity 也有 Object 类型。
// 为了避免命名冲突，这里明确指定 Object = UnityEngine.Object。
using Object = UnityEngine.Object;

/// <summary>
/// CustomEditor 表示这个类是某个类型的自定义 Inspector。
/// 
/// 这里的意思是：
/// 当你在 Project 面板中选中 MFFlareAssetCell 资源时，
/// Unity Inspector 面板不会使用默认绘制方式，
/// 而是使用 MFFlareCellAssetEditor 这个编辑器类来绘制。
/// 
/// 作用：
/// 给 MFFlareAssetCell 资产制作一个专用编辑界面。
/// 
/// 原理：
/// Unity 的 Editor 系统允许开发者重写 OnInspectorGUI，
/// 从而自定义 Inspector 面板上的按钮、滑条、贴图预览、颜色选择器等控件。
/// </summary>
[CustomEditor(typeof(MFFlareAssetCell))]
public class MFFlareCellAssetEditor : Editor
{
    /// <summary>
    /// 当前正在被编辑的 MFFlareAssetCell 资源对象。
    /// 
    /// 作用：
    /// Unity 的 Editor 类中有一个 target 字段，
    /// target 表示当前 Inspector 正在编辑的目标对象。
    /// 
    /// 这里把 target 转换成 MFFlareAssetCell，
    /// 后面就可以直接访问它的 flareSprite、modelCell、spriteBlocks 等字段。
    /// </summary>
    private MFFlareAssetCell _targetAssetCell;

    /// <summary>
    /// 当前编辑器自身的引用。
    /// 
    /// 作用：
    /// 从当前代码来看，这个字段并没有被实际使用。
    /// 
    /// 可能用途：
    /// 作者原本可能打算保存编辑器实例，方便后续调用自身方法。
    /// 但目前可以删除，不影响功能。
    /// </summary>
    private MFFlareCellAssetEditor _ins;

    /// <summary>
    /// 用来记录图集网格中每一个 Cell 按钮是否被点击。
    /// 
    /// 作用：
    /// PaintTable() 会根据 modelCell 画出一个二维按钮表格。
    /// 每个按钮对应图集中的一个 flare 小图块。
    /// 
    /// 当某个按钮被点击时，GUILayout.Button 会返回 true。
    /// 这些 true / false 会被存入 _tablelist。
    /// 
    /// 后面 OnInspectorGUI 会遍历 _tablelist，
    /// 如果某个位置为 true，就创建一个新的 MFFlareSpriteData。
    /// </summary>
    private List<bool> _tablelist;


    // -----------------------------------------------------------------------
    // 以下大段 STATIC_FlareRectModel 被注释掉了。
    // 它不会参与编译，也不会执行。
    // -----------------------------------------------------------------------

    // private static readonly List<Rect>[] STATIC_FlareRectModel = new[]
    // {
    //     ...
    // };

    /*
     * 这段被注释掉的 STATIC_FlareRectModel 原本的作用：
     * 
     * 它保存了几种固定图集模板的 UV Rect 数据。
     * 
     * 例如：
     * 1. 2x2 图集
     * 2. 4x4 图集
     * 3. Mega 特殊布局图集
     * 4. 1L4S 布局
     * 5. 1L2M8S 布局
     * 
     * Rect 的数据范围是 0 到 1，
     * 表示贴图 UV 空间中的区域。
     * 
     * 例如：
     * new Rect(0, 0.5f, 0.5f, 0.5f)
     * 表示采样贴图左上角 1/4 的区域。
     * 
     * 为什么后来被注释掉？
     * 
     * 因为现在代码改成了更加通用的 modelCell 方式。
     * 也就是通过：
     * 
     *     modelCell.x 表示列数
     *     modelCell.y 表示行数
     * 
     * 自动计算每个 Cell 的 UV Rect。
     * 
     * 这样就不需要提前写死 2x2、4x4、Mega 等固定模板。
     */


    // -----------------------------------------------------------------------
    // 以下 MenuItem 创建资源的代码也被注释掉了。
    // 当前不会执行。
    // -----------------------------------------------------------------------

    // [MenuItem("Assets/Create/MFLensflare/Create MFFlareData split by Cell")]
    // static void CreateFlareDataCell()
    // {
    //     ...
    // }

    /*
     * 这段被注释掉的 MenuItem 代码原本的作用：
     * 
     * 在 Unity 顶部菜单或者 Project 右键菜单中添加一个创建资源的入口，
     * 用来创建 FlareByCell.asset。
     * 
     * 但是当前项目里 MFFlareAssetCell 类已经使用了：
     * 
     * [CreateAssetMenu(fileName = "FlareAsset", menuName = "MFLensflare/Create FlareAsset split by Cell")]
     * 
     * 所以这里的 MenuItem 版本已经不需要了。
     * 
     * 另外：
     * 原代码里 CreateInstance<MFFlareCellAssetEditor>() 也不太合理。
     * 因为真正要创建的应该是 MFFlareAssetCell 数据资产，
     * 而不是 Editor 编辑器对象。
     */


    /// <summary>
    /// Awake 会在这个自定义 Inspector 初始化时调用。
    /// 
    /// 作用：
    /// 1. 获取当前正在编辑的 MFFlareAssetCell 资源。
    /// 2. 初始化按钮点击状态列表 _tablelist。
    /// 
    /// 原理：
    /// Editor.target 是 Unity 提供的当前编辑对象。
    /// 这里通过 as 转换成 MFFlareAssetCell 类型。
    /// </summary>
    private void Awake()
    {
        // 把当前 Inspector 正在编辑的对象转换成 MFFlareAssetCell。
        _targetAssetCell = target as MFFlareAssetCell;

        // 初始化 Cell 按钮状态列表。
        // 后面绘制图集表格时，每个 Cell 按钮都会对应一个 bool。
        _tablelist = new List<bool>();
    }


    /// <summary>
    /// 根据图集 Cell 的 index 计算该 Cell 对应的 UV Rect。
    /// 
    /// 作用：
    /// 从 flareSprite 图集中取出指定编号的小图案。
    /// 
    /// 参数：
    /// index 表示第几个 Cell。
    /// 
    /// 例如：
    /// 如果 modelCell = (4, 4)，说明图集被切成 4 列 4 行。
    /// 那么 index = 0 表示第 1 个格子，
    /// index = 1 表示第 2 个格子，
    /// index = 4 表示第 2 行第 1 个格子。
    /// 
    /// 原理：
    /// Unity 的 GUI.DrawTextureWithTexCoords 需要一个 Rect 作为 UV 范围。
    /// Rect 的 x、y、width、height 都是 0 到 1 的归一化坐标。
    /// 
    /// width = 1 / 列数
    /// height = 1 / 行数
    /// 
    /// x = 当前列编号 / 列数
    /// y = 当前行编号 / 行数
    /// 
    /// 注意：
    /// Unity 的贴图 UV 坐标通常从左下角开始，
    /// 而编辑器表格绘制一般从左上角开始，
    /// 所以这里对 y 做了翻转处理。
    /// </summary>
    private Rect GetFlareRect(int index)
    {
        return new Rect(
            // 计算当前 index 所在的列，并转成 UV 的 x 坐标。
            // index % modelCell.x 得到当前列号。
            // 再除以 modelCell.x，把像素/格子编号转换到 0~1 的 UV 空间。
            (float)index % _targetAssetCell.modelCell.x / _targetAssetCell.modelCell.x,

            // 计算当前 index 所在的行，并转成 UV 的 y 坐标。
            // 这里做了上下翻转，因为 GUI 表格是从上往下显示，
            // 但 UV 坐标通常是从下往上计算。
            //
            // 注意：
            // 这里原代码使用 index / _targetAssetCell.modelCell.y。
            // 如果 modelCell.x 和 modelCell.y 相等，比如 4x4，就不会出问题。
            // 但如果图集不是正方形，比如 4x2，这里可能会算错。
            //
            // 更合理的写法通常应该是：
            // index / _targetAssetCell.modelCell.x
            //
            // 因为 index 是按列数递增的，计算行号时应该除以列数。
            (float)(_targetAssetCell.modelCell.y - index / _targetAssetCell.modelCell.y - 1)
            / _targetAssetCell.modelCell.y,

            // 每个 Cell 的 UV 宽度。
            // 例如 4 列，则每个 Cell 宽度为 1/4 = 0.25。
            (float)1 / _targetAssetCell.modelCell.x,

            // 每个 Cell 的 UV 高度。
            // 例如 4 行，则每个 Cell 高度为 1/4 = 0.25。
            (float)1 / _targetAssetCell.modelCell.y
        );
    }


    /// <summary>
    /// 重写 Unity 默认 Inspector 绘制函数。
    /// 
    /// 作用：
    /// 这个函数决定 MFFlareAssetCell 在 Inspector 面板中显示什么内容。
    /// 
    /// 这里绘制的内容包括：
    /// 1. Save 按钮
    /// 2. Fade With Scale 开关
    /// 3. Fade With Alpha 开关
    /// 4. 贴图选择框
    /// 5. Cell 行列数设置
    /// 6. 图集切片预览按钮表格
    /// 7. 每个 flare block 的详细参数编辑面板
    /// 
    /// 原理：
    /// Unity EditorGUILayout / GUILayout 用于创建编辑器 UI 控件。
    /// 每帧 Inspector 刷新时都会重新调用 OnInspectorGUI。
    /// </summary>
    public override void OnInspectorGUI()
    {
        // 绘制一个 Save 按钮。
        // 当用户点击按钮时，保存当前所有 Asset 修改。
        if (GUILayout.Button("Save"))
        {
            // 保存所有被标记为 Dirty 的资源到磁盘。
            AssetDatabase.SaveAssets();
        }

        // 开始检测 Inspector 中的数据是否发生变化。
        // 后面会配合 EditorGUI.EndChangeCheck 使用。
        EditorGUI.BeginChangeCheck();

        // 绘制 Fade With Scale 开关。
        // 用来控制镜头光晕淡出时是否通过缩放变小来消失。
        _targetAssetCell.fadeWithScale =
            EditorGUILayout.Toggle("Fade With Scale", _targetAssetCell.fadeWithScale);

        // 绘制 Fade With Alpha 开关。
        // 用来控制镜头光晕淡出时是否通过透明度降低来消失。
        _targetAssetCell.fadeWithAlpha =
            EditorGUILayout.Toggle("Fade With Alpha", _targetAssetCell.fadeWithAlpha);

        // 绘制图集贴图选择框，以及 Cell 行列数量输入框。
        PaintSplitType();

        // 绘制图集切分后的 Cell 预览表格。
        // 每个 Cell 都是一个按钮，点击后会添加一个 flare 元素。
        PaintTable();

        // 计算当前图集被切分成多少个 Cell。
        // 例如 modelCell = (4,4)，cellCount = 16。
        int cellCount = _targetAssetCell.modelCell.x * _targetAssetCell.modelCell.y;

        // 遍历表格按钮点击状态。
        // 如果某个 Cell 按钮被点击，就把对应 Cell 添加为一个新的光晕块数据。
        for (int i = 0; i < _tablelist.Count; i++)
        {
            if (_tablelist[i])
            {
                // 创建一个新的 MFFlareSpriteData，并加入 spriteBlocks。
                // spriteBlocks 是真正用于运行时渲染 Lens Flare 的光晕块列表。
                _targetAssetCell.spriteBlocks.Add(new MFFlareSpriteData()
                {
                    // 默认不叠加光源颜色。
                    useLightColor = 0,

                    // 默认不根据屏幕中心方向旋转。
                    useRotation = false,

                    // 当前使用的图集 Cell 序号。
                    index = i,

                    // 根据 index 和 modelCell 自动计算这个 Cell 的 UV Rect。
                    block = GetFlareRect(i),

                    // 默认缩放为 1。
                    scale = 1,

                    // 默认偏移为 0，通常表示位于屏幕中心附近。
                    offset = 0,

                    // 默认颜色为白色。
                    color = Color.white
                });
            }
        }

        // 遍历当前已经添加的所有 flare sprite block，
        // 并为每个 block 绘制可编辑参数。
        for (int i = 0; i < _targetAssetCell.spriteBlocks.Count;)
        {
            // 添加一点垂直间距，让每个 block 之间分开。
            EditorGUILayout.Space(5);

            // 取出当前第 i 个光晕块数据。
            // 因为 MFFlareSpriteData 是 struct 值类型，
            // 所以这里取出来的是一份拷贝。
            // 修改完成后，必须重新赋值回 spriteBlocks[i]。
            MFFlareSpriteData data = _targetAssetCell.spriteBlocks[i];

            // 开始一行横向布局。
            // 返回的 Rect t 表示这行 UI 在 Inspector 中的位置。
            // 后面会用这个位置绘制贴图预览。
            Rect t = EditorGUILayout.BeginHorizontal();

            // 占一个 60x60 的位置，用来放贴图预览。
            EditorGUILayout.LabelField(" ", new[] { GUILayout.Height(60), GUILayout.Width(60) });

            // 开始右侧纵向布局。
            // 右侧会放 index、rotation、lightColor 等参数。
            EditorGUILayout.BeginVertical();

            // 限制 index 的范围，避免超出图集 Cell 数量。
            // 例如一共 16 个 Cell，那么 index 只能是 0~15。
            data.index = Mathf.Clamp(data.index, 0, cellCount - 1);

            // 根据当前 index 重新计算 block UV。
            // 这样当用户拖动 Index Slider 时，贴图预览和 block 数据会自动更新。
            data.block = GetFlareRect(data.index);

            // 绘制当前 flare block 对应的贴图预览。
            //
            // GUI.DrawTextureWithTexCoords 参数说明：
            // 1. 第一个 Rect：贴图在 Inspector 面板上的显示位置
            // 2. 第二个参数：要显示的原始贴图 flareSprite
            // 3. 第三个参数：从原始贴图中采样哪一块 UV 区域
            //
            // 原理：
            // 它不是显示整张图集，
            // 而是根据 data.block 只显示当前 Cell 对应的小图案。
            GUI.DrawTextureWithTexCoords(
                new Rect(
                    // t.position 表示当前横向布局起始位置。
                    // 加上 Vector2 用于调整预览图的位置。
                    t.position + new Vector2(
                        0,
                        30 * (1 - data.block.height / data.block.width)
                    ),

                    // 根据 UV 的宽高比例调整显示大小。
                    // 这样可以尽量保持原始图块比例。
                    new Vector2(
                        60,
                        60 * data.block.height / data.block.width
                    )
                ),
                _targetAssetCell.flareSprite,
                data.block
            );

            // 绘制 Index 滑条。
            // 用户可以通过它切换该 flare block 使用图集中的哪个 Cell。
            data.index = EditorGUILayout.IntSlider("Index", data.index, 0, cellCount - 1);

            // 绘制 Rotation 开关。
            // 开启后，该 flare block 运行时可能会根据光源到屏幕中心的方向旋转。
            data.useRotation = EditorGUILayout.Toggle("Rotation", data.useRotation);

            // 绘制 LightColor 滑条。
            // 取值范围 0~1。
            // 0 表示不受光源颜色影响，
            // 1 表示完全叠加或使用光源颜色。
            data.useLightColor = EditorGUILayout.Slider("LightColor", data.useLightColor, 0, 1);

            // 结束右侧纵向布局。
            EditorGUILayout.EndVertical();

            // 结束当前横向布局。
            EditorGUILayout.EndHorizontal();

            // 绘制 Offset 滑条。
            // 用来控制该 flare block 沿着镜头光晕方向线的位置。
            //
            // 常见原理：
            // 光源屏幕坐标和屏幕中心形成一条方向线，
            // offset 决定这个光斑位于这条线上的哪个位置。
            data.offset = EditorGUILayout.Slider("Offset", data.offset, -1.5f, 1f);

            // 绘制颜色选择器。
            // 用于设置该 flare block 自身颜色。
            data.color = EditorGUILayout.ColorField("Color", data.color);

            // 绘制缩放输入框。
            // 用于设置该 flare block 的基础大小。
            data.scale = EditorGUILayout.FloatField("Scale", data.scale);

            // 绘制 Remove 按钮。
            // 如果点击，就从 spriteBlocks 中移除当前光晕块。
            if (GUILayout.Button("Remove"))
            {
                _targetAssetCell.spriteBlocks.RemoveAt(i);

                // 注意：
                // 删除当前元素后，不递增 i。
                // 因为原本 i+1 的元素会移动到当前位置。
            }
            else
            {
                // 如果没有删除，就把修改后的 data 写回列表。
                // 因为 data 是 struct 拷贝，不写回就不会保存修改。
                _targetAssetCell.spriteBlocks[i] = data;

                // 处理下一个光晕块。
                i++;
            }
        }

        // 如果 Inspector 中任意字段发生变化，
        // 就把目标资源标记为 Dirty。
        // 
        // 作用：
        // 告诉 Unity 这个资源已经被修改，需要保存。
        if (EditorGUI.EndChangeCheck())
        {
            EditorUtility.SetDirty(_targetAssetCell);
        }

        // 记录 Undo 操作。
        // 
        // 作用：
        // 让用户在编辑 Inspector 参数后，可以使用 Ctrl + Z 撤销。
        //
        // 注意：
        // 更规范的写法通常是在修改数据之前调用 Undo.RecordObject。
        // 当前代码放在最后也能记录一部分修改，但不是最理想的位置。
        Undo.RecordObject(_targetAssetCell, "Change Flare Asset Data");
    }


    /// <summary>
    /// 绘制图集贴图和 Cell 切分数量设置区域。
    /// 
    /// 作用：
    /// 让用户在 Inspector 中选择 flareSprite 图集，
    /// 并设置该图集被切成几列几行。
    /// 
    /// 原理：
    /// modelCell 决定 GetFlareRect 如何计算每个 Cell 的 UV。
    /// </summary>
    public void PaintSplitType()
    {
        // 绘制 Texture2D 资源选择框。
        // 用户可以把 Lens Flare 图集拖到这里。
        _targetAssetCell.flareSprite =
            (Texture2D)EditorGUILayout.ObjectField(
                "Texture",
                _targetAssetCell.flareSprite,
                typeof(Texture2D),
                true
            );

        // 绘制 Vector2Int 输入框。
        // x 表示列数，y 表示行数。
        //
        // 例如：
        // Cell num = (4, 4)
        // 表示把图集分成 4 列 4 行，共 16 个 Cell。
        _targetAssetCell.modelCell =
            EditorGUILayout.Vector2IntField("Cell num", _targetAssetCell.modelCell);
    }


    /// <summary>
    /// 绘制图集 Cell 预览表格。
    /// 
    /// 作用：
    /// 根据 modelCell 把整张 flareSprite 画成一个可点击的网格。
    /// 每个格子代表一个 flare 图案。
    /// 
    /// 用户点击某个格子后，
    /// 对应的 bool 会被记录到 _tablelist，
    /// 然后 OnInspectorGUI 会根据这个点击状态添加新的 MFFlareSpriteData。
    /// 
    /// 原理：
    /// 1. 先画按钮。
    /// 2. 再用 GUI.DrawTextureWithTexCoords 把对应 Cell 的图案画到按钮区域上。
    /// 3. 按钮负责交互，贴图负责视觉预览。
    /// </summary>
    public void PaintTable()
    {
        // 每次重绘 Inspector 时，先清空按钮状态列表。
        // 因为 GUILayout.Button 的点击结果只在当前 GUI 事件中有效。
        if (_tablelist != null)
            _tablelist.Clear();

        // 如果 spriteBlocks 为空，就初始化。
        // 防止后续 Add 或 Count 操作出现空引用错误。
        if (_targetAssetCell.spriteBlocks == null)
            _targetAssetCell.spriteBlocks = new List<MFFlareSpriteData>();

        // 开始纵向布局。
        // 每一行对应图集中的一行 Cell。
        EditorGUILayout.BeginVertical();

        // 遍历行。
        // modelCell.y 表示图集被切成多少行。
        for (int i = 0; i < _targetAssetCell.modelCell.y; i++)
        {
            // 开始横向布局。
            // 一行中会绘制多个按钮。
            // 返回 Rect r，用来确定这一行在 Inspector 中的位置。
            Rect r = (Rect)EditorGUILayout.BeginHorizontal();

            // 遍历列。
            // modelCell.x 表示图集被切成多少列。
            for (int j = 0; j < _targetAssetCell.modelCell.x; j++)
            {
                // 绘制一个 60x60 的按钮。
                //
                // 按钮文字：
                // i * modelCell.x + j + 1
                // 表示从 1 开始显示当前 Cell 编号。
                //
                // ToString("00") 表示两位数显示。
                // 例如 1 显示为 01，2 显示为 02。
                //
                // GUILayout.Button 返回 bool：
                // 当前帧如果按钮被点击，返回 true；
                // 没有点击，返回 false。
                //
                // 这个 bool 会被加入 _tablelist。
                _tablelist.Add(
                    GUILayout.Button(
                        (i * _targetAssetCell.modelCell.x + j + 1).ToString("00"),
                        new[] { GUILayout.Height(60), GUILayout.Width(60) }
                    )
                );
            }

            // 结束当前横向布局。
            EditorGUILayout.EndHorizontal();

            // 如果用户已经指定了 flareSprite 图集，
            // 就在按钮区域上绘制对应的贴图 Cell 预览。
            if (_targetAssetCell.flareSprite)
            {
                // 遍历当前行中的每一列。
                for (int j = 0; j < _targetAssetCell.modelCell.x; j++)
                {
                    // 计算当前 Cell 的整体 index。
                    int index = i * _targetAssetCell.modelCell.x + j;

                    // 在按钮位置上绘制贴图切片。
                    //
                    // new Rect(r.position.x + j * 63, r.position.y, 60, 60)
                    // 表示每个 Cell 预览图的屏幕位置。
                    //
                    // j * 63 中的 63 是为了让每个 60 宽的格子之间留一点间距。
                    //
                    // GetFlareRect(index) 负责计算当前 index 对应的 UV Rect。
                    GUI.DrawTextureWithTexCoords(
                        new Rect(
                            r.position.x + j * 63,
                            r.position.y,
                            60,
                            60
                        ),
                        _targetAssetCell.flareSprite,
                        GetFlareRect(index)
                    );
                }
            }
        }

        // 结束纵向布局。
        EditorGUILayout.EndVertical();


        // -------------------------------------------------------------------
        // 后面被注释掉的大段 switch 代码是旧版绘制逻辑。
        // 当前不会执行。
        // -------------------------------------------------------------------

        /*
         * 旧版逻辑的作用：
         * 
         * 根据 FlareTexModel 枚举判断图集模板类型，
         * 然后手动绘制不同布局的图集预览。
         * 
         * 例如：
         * 
         * case FlareTexModel._2x2:
         *     按 2x2 布局绘制按钮和贴图预览。
         * 
         * case FlareTexModel._4x4:
         *     按 4x4 布局绘制按钮和贴图预览。
         * 
         * case FlareTexModel._Mega:
         *     按特殊大小混合布局绘制按钮和贴图预览。
         * 
         * case FlareTexModel._1L4S:
         *     按 1 个大图 + 4 个小图的布局绘制。
         * 
         * case FlareTexModel._1L2M8S:
         *     按 1 个大图 + 2 个中图 + 8 个小图的布局绘制。
         * 
         * 为什么现在不用？
         * 
         * 因为旧版逻辑需要为每一种图集布局写一套固定代码，
         * 维护成本高，扩展麻烦。
         * 
         * 现在使用 modelCell 后，任意规则网格都可以统一处理：
         * 
         *     modelCell = (2, 2)
         *     modelCell = (4, 4)
         *     modelCell = (8, 4)
         * 
         * 都可以通过同一个 GetFlareRect 函数自动计算 UV。
         */
    }
}