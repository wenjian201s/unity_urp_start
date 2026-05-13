using System;
using System.Collections.Generic;
using System.IO;

// UnityEditor 命名空间只在 Unity 编辑器中可用。
// 只要脚本引用了 UnityEditor，这个脚本就不能被打包进最终游戏。
// 所以这个脚本应该放在 Assets/Editor 文件夹下。
using UnityEditor;

using UnityEngine;

/// <summary>
/// CustomEditor 表示这是一个自定义 Inspector 编辑器。
/// 
/// 作用：
/// 当 Unity Inspector 面板选中 MFFlareAssetSlicer 类型的资源时，
/// Unity 不再使用默认 Inspector，而是使用这个 MFFlareFreeAssetEditor 来绘制编辑界面。
/// 
/// 原理：
/// Unity 的 Editor 扩展系统允许开发者重写 OnInspectorGUI()，
/// 自定义按钮、贴图预览、滑条、颜色选择器等编辑器控件。
/// </summary>
[CustomEditor(typeof(MFFlareAssetSlicer))]
public class MFFlareFreeAssetEditor : Editor
{
    /// <summary>
    /// 当前正在编辑的 MFFlareAssetSlicer 资源。
    /// 
    /// 作用：
    /// 用来访问光晕资源中的数据，例如：
    /// 1. flareSprite 光晕图集
    /// 2. fadeWithScale 是否用缩放淡出
    /// 3. fadeWithAlpha 是否用透明度淡出
    /// 4. spriteBlocks 光晕块列表
    /// 
    /// 原理：
    /// Editor 类中自带 target 字段，表示当前 Inspector 正在编辑的对象。
    /// 在 Awake 中会把 target 转换成 MFFlareAssetSlicer。
    /// </summary>
    private MFFlareAssetSlicer _targetAssetSlicer;

    /// <summary>
    /// 当前代码中没有实际使用。
    /// 
    /// 可能是作者原本想保存另一个编辑器实例，
    /// 但后续没有用到。
    /// 
    /// 这行可以删除，不影响当前脚本功能。
    /// </summary>
    private MFFlareCellAssetEditor _ins;

    /// <summary>
    /// 用来记录 Sprite 预览按钮是否被点击。
    /// 
    /// 作用：
    /// Inspector 中会把所有切好的 Sprite 以按钮网格的形式显示出来。
    /// 每个按钮对应一个 Sprite。
    /// 如果某个按钮被点击，GUILayout.Button 会返回 true。
    /// 
    /// _tablelist 就用来保存这些按钮的点击状态。
    /// 后面会遍历这个列表，如果某一项为 true，
    /// 就创建一个新的 MFFlareSpriteData 添加到 spriteBlocks。
    /// </summary>
    private List<bool> _tablelist;

    /// <summary>
    /// 临时缓存当前正在使用的光晕图集。
    /// 
    /// 作用：
    /// 用来判断用户是否更换了 flareSprite。
    /// 
    /// 原理：
    /// 如果当前 flareSprite 和 _tmp 不一样，
    /// 说明用户换了一张图集。
    /// 这时就需要重新从该贴图资源中读取所有切片 Sprite。
    /// </summary>
    private Texture2D _tmp;

    /// <summary>
    /// 缓存当前图集中通过 Sprite Editor 切出来的所有 Sprite。
    /// 
    /// 作用：
    /// 每个 Sprite 对应图集中的一个光晕元素。
    /// 
    /// 原理：
    /// Unity 的一张 Texture2D 如果 Sprite Mode 设置为 Multiple，
    /// 并且在 Sprite Editor 里切片，
    /// 那么这些 Sprite 会作为子资源存储在同一个贴图资源路径下。
    /// 
    /// AssetDatabase.LoadAllAssetsAtPath(path)
    /// 可以把主贴图和它下面的所有子 Sprite 都加载出来。
    /// </summary>
    private Sprite[] _tmpSprites;


    // ---------------------------------------------------------------------
    // 以下 MenuItem 代码已经被注释掉，不会参与编译和执行。
    // ---------------------------------------------------------------------

    /*
    [MenuItem("Assets/Create/MFLensflare/Create MFFlareData split by SpriteEditor")]
    static void CreateFlareDataFree()
    {
        ...
    }

    static void LoopCreateFlareAssetFree(int serial, string path)
    {
        ...
    }
    */

    /*
     * 这段旧代码原本的作用：
     * 
     * 在 Unity 菜单中创建一个入口，
     * 用来生成一个基于 Sprite Editor 切片方式的 FlareAsset 资源。
     * 
     * 但是目前这段代码被注释掉了，
     * 说明当前项目可能已经改用 [CreateAssetMenu] 的方式创建资源，
     * 或者创建资源的逻辑已经迁移到了别处。
     * 
     * 另外，这段旧代码里 CreateInstance<MFFlareAssetFree>()，
     * 说明早期可能存在一个名叫 MFFlareAssetFree 的类，
     * 后来可能被 MFFlareAssetSlicer 替代。
     */


    /// <summary>
    /// Awake 会在自定义 Inspector 初始化时调用。
    /// 
    /// 作用：
    /// 1. 获取当前被编辑的 MFFlareAssetSlicer 资源。
    /// 2. 初始化按钮点击状态列表。
    /// 
    /// 原理：
    /// Editor.target 是 Unity 提供的当前编辑对象。
    /// 因为这个 Editor 是给 MFFlareAssetSlicer 用的，
    /// 所以可以把 target 转换成 MFFlareAssetSlicer。
    /// </summary>
    private void Awake()
    {
        // 把当前 Inspector 正在编辑的对象转换成 MFFlareAssetSlicer。
        _targetAssetSlicer = target as MFFlareAssetSlicer;

        // 初始化按钮点击状态列表。
        _tablelist = new List<bool>();
    }


    /// <summary>
    /// 自定义 Inspector 的核心函数。
    /// 
    /// 作用：
    /// Unity 每次绘制 Inspector 面板时都会调用这个函数。
    /// 当前函数负责绘制：
    /// 1. Save 保存按钮
    /// 2. Fade With Scale 开关
    /// 3. Fade With Alpha 开关
    /// 4. 光晕贴图选择框
    /// 5. Sprite 切片预览按钮
    /// 6. 已添加光晕块的详细参数编辑区
    /// 
    /// 原理：
    /// 这个编辑器读取 flareSprite 中的所有 Sprite 子资源，
    /// 把它们显示成一个个按钮。
    /// 点击按钮后，就把对应 Sprite 生成一个 MFFlareSpriteData。
    /// </summary>
    public override void OnInspectorGUI()
    {
        // 绘制 Save 按钮。
        // 点击后保存当前所有被修改过的 Unity 资源。
        if (GUILayout.Button("Save"))
        {
            AssetDatabase.SaveAssets();
        }

        // 开始检测 Inspector 中是否有字段发生变化。
        // 后面会配合 EditorGUI.EndChangeCheck() 使用。
        EditorGUI.BeginChangeCheck();

        // 每次重绘 Inspector 时，清空按钮点击状态。
        // GUILayout.Button 的点击结果只在当前 GUI 事件中有效。
        if (_tablelist != null)
            _tablelist.Clear();

        // 绘制 Fade With Scale 开关。
        // 作用：
        // 控制 Lens Flare 淡出时是否通过缩放变小来消失。
        _targetAssetSlicer.fadeWithScale =
            EditorGUILayout.Toggle("Fade With Scale", _targetAssetSlicer.fadeWithScale);

        // 绘制 Fade With Alpha 开关。
        // 作用：
        // 控制 Lens Flare 淡出时是否通过 Alpha 透明度降低来消失。
        _targetAssetSlicer.fadeWithAlpha =
            EditorGUILayout.Toggle("Fade With Alpha", _targetAssetSlicer.fadeWithAlpha);

        // 绘制 Texture2D 资源选择框。
        // 用户可以把一张已经通过 Sprite Editor 切片的光晕图集拖进来。
        _targetAssetSlicer.flareSprite =
            (Texture2D)EditorGUILayout.ObjectField(
                "Texture",
                _targetAssetSlicer.flareSprite,
                typeof(Texture2D),
                true
            );

        // 如果当前已经指定了光晕贴图。
        if (_targetAssetSlicer.flareSprite != null)
        {
            // 判断当前贴图是否和缓存的 _tmp 不一样。
            // 如果不一样，说明用户刚刚换了贴图，需要重新加载 Sprite 子资源。
            if (!_targetAssetSlicer.flareSprite.Equals(_tmp))
            {
                // 更新缓存贴图。
                _tmp = _targetAssetSlicer.flareSprite;

                // 根据贴图名称查找资源 GUID。
                //
                // 原理：
                // AssetDatabase.FindAssets 会在项目资源中搜索匹配名称的资源。
                //
                // 注意：
                // 这里使用 _tmp.name 搜索，如果项目中有同名贴图，
                // 可能会找到错误的资源。
                // 更安全的写法是直接使用 AssetDatabase.GetAssetPath(_tmp)。
                var guid = AssetDatabase.FindAssets(_tmp.name)[0];

                // 通过 GUID 获取资源路径。
                var path = AssetDatabase.GUIDToAssetPath(guid);

                // 加载该路径下的所有资源。
                //
                // 如果这张图是 Sprite Mode = Multiple，
                // 那么这里通常会返回：
                // 1. 主 Texture2D
                // 2. 子 Sprite 1
                // 3. 子 Sprite 2
                // 4. 子 Sprite 3
                // ...
                var targetLoader = AssetDatabase.LoadAllAssetsAtPath(path);

                // 创建 Sprite 数组。
                //
                // targetLoader.Length - 1 的原因：
                // 通常第 0 个资源是主贴图 Texture2D，
                // 从第 1 个开始才是 Sprite 子资源。
                _tmpSprites = new Sprite[targetLoader.Length - 1];

                // 从 targetLoader[1] 开始，把所有子资源转换成 Sprite。
                for (int i = 1; i < targetLoader.Length; i++)
                {
                    _tmpSprites[i - 1] = targetLoader[i] as Sprite;
                }
            }
        }
        else
        {
            // 如果没有指定贴图，则清空缓存。
            _tmp = null;
            _tmpSprites = null;
        }

        // 如果没有成功读取到 Sprite 切片，直接返回。
        // 后面的预览和编辑逻辑都依赖 _tmpSprites。
        if (_tmpSprites == null)
            return;

        // 获取整张图集的宽高。
        //
        // 作用：
        // 后面需要用 Sprite.rect 的像素坐标除以图集宽高，
        // 转换成 0~1 的 UV 坐标。
        Vector2 wh = new Vector2(
            _targetAssetSlicer.flareSprite.width,
            _targetAssetSlicer.flareSprite.height
        );

        // 绘制 Sprite 切片预览按钮。
        //
        // 每行显示 5 个 Sprite。
        // Mathf.Ceil 用于计算总共需要多少行。
        for (int i = 0; i < Mathf.Ceil((float)_tmpSprites.Length / 5); i++)
        {
            // 创建一行横向布局。
            //
            // fixedHeight = 60 表示这一行高度固定为 60。
            // fixedWidth = 320 大约对应 5 个 60 宽按钮加间距。
            using (new EditorGUILayout.HorizontalScope(
                new GUIStyle()
                {
                    fixedHeight = 60,
                    stretchHeight = false,
                    fixedWidth = 320,
                    stretchWidth = false
                }))
            {
                // 开始横向布局，并记录该行的 Rect。
                // 这个 Rect 后面用于计算贴图预览绘制的位置。
                Rect t = EditorGUILayout.BeginHorizontal();

                // 当前行最多绘制 5 个 Sprite。
                for (int j = 5 * i; j < 5 * i + 5; j++)
                {
                    // 防止最后一行越界。
                    if (j < _tmpSprites.Length)
                    {
                        // 绘制按钮。
                        //
                        // 按钮文字是 Sprite 的序号，从 1 开始显示。
                        // GUILayout.Button 返回 true 表示按钮被点击。
                        //
                        // 点击后会在后面创建一个新的 MFFlareSpriteData。
                        _tablelist.Add(
                            GUILayout.Button(
                                (j + 1).ToString(),
                                new[] { GUILayout.Height(60), GUILayout.Width(60) }
                            )
                        );

                        // 把当前 Sprite 的像素矩形转换为 UV 矩形。
                        //
                        // _tmpSprites[j].rect 是像素坐标。
                        // 例如：
                        // x = 256
                        // y = 512
                        // width = 128
                        // height = 128
                        //
                        // GUI.DrawTextureWithTexCoords 需要的是 0~1 的 UV 坐标。
                        // 所以要除以整张图集的宽高。
                        Rect r = new Rect(
                            _tmpSprites[j].rect.x / wh.x,
                            _tmpSprites[j].rect.y / wh.y,
                            _tmpSprites[j].rect.width / wh.x,
                            _tmpSprites[j].rect.height / wh.y
                        );

                        // 在按钮区域上绘制当前 Sprite 的贴图预览。
                        //
                        // 第一个 Rect：
                        // 控制预览图在 Inspector 中显示的位置和大小。
                        //
                        // 第二个参数：
                        // 原始整张光晕图集。
                        //
                        // 第三个参数：
                        // 当前 Sprite 在图集中的 UV 区域。
                        //
                        // 原理：
                        // 不是单独显示 Sprite 资源，
                        // 而是从整张 Texture2D 中用 UV 裁剪出 Sprite 对应区域。
                        GUI.DrawTextureWithTexCoords(
                            new Rect(
                                t.position + new Vector2(
                                    63 * (j - 5 * i) + 1,
                                    1
                                ),
                                new Vector2(58, 58)
                            ),
                            _targetAssetSlicer.flareSprite,
                            r
                        );
                    }
                }

                // 结束当前横向布局。
                EditorGUILayout.EndHorizontal();
            }
        }

        // 在 Sprite 预览区和下方详细参数区之间留一点距离。
        EditorGUILayout.Space(30);

        // 遍历所有按钮点击状态。
        // 如果某个按钮被点击，就把对应 Sprite 添加为一个光晕块。
        for (int i = 0; i < _tablelist.Count; i++)
        {
            if (_tablelist[i])
            {
                // 创建一个新的光晕块数据。
                _targetAssetSlicer.spriteBlocks.Add(new MFFlareSpriteData()
                {
                    // 默认不受光源颜色影响。
                    useLightColor = 0,

                    // 默认不随屏幕中心方向旋转。
                    useRotation = false,

                    // 当前 Sprite 在 _tmpSprites 中的索引。
                    index = i,

                    // 当前这里保存的是 Sprite 的像素 rect。
                    //
                    // 注意：
                    // 后面编辑详细参数时会重新把它转换成 UV Rect。
                    // 如果运行时渲染系统需要的是 UV Rect，
                    // 那么这里更推荐直接保存归一化后的 Rect。
                    block = _tmpSprites[i].rect,

                    // 默认缩放大小为 1。
                    scale = 1,

                    // 默认偏移为 0。
                    // 运行时一般会沿着“光源屏幕位置 - 屏幕中心”的方向线计算位置。
                    offset = 0,

                    // 默认颜色为白色。
                    color = Color.white
                });
            }
        }

        // 如果没有 Sprite，直接返回。
        if (_tmpSprites == null || _tmpSprites.Length == 0)
            return;

        // 遍历当前已经添加到 spriteBlocks 中的所有光晕块。
        //
        // 这里使用 for 循环而不是 foreach，
        // 因为循环内部可能会 Remove 当前元素。
        for (int i = 0; i < _targetAssetSlicer.spriteBlocks.Count;)
        {
            // 每个光晕块之间留一点间距。
            EditorGUILayout.Space(5);

            // 取出当前光晕块数据。
            //
            // MFFlareSpriteData 是 struct 值类型，
            // 所以这里拿到的是一份拷贝。
            // 修改完成后必须重新赋值回 spriteBlocks[i]。
            MFFlareSpriteData data = _targetAssetSlicer.spriteBlocks[i];

            // 开始一行横向布局。
            // 返回 Rect t，用来确定当前行在 Inspector 中的位置。
            Rect t = EditorGUILayout.BeginHorizontal();

            // 占一个 60x60 的空位，用来放当前光晕块的贴图预览。
            EditorGUILayout.LabelField(
                " ",
                new[] { GUILayout.Height(60), GUILayout.Width(60) }
            );

            // 开始右侧纵向布局。
            EditorGUILayout.BeginVertical();

            // 限制 index 范围，避免超出 _tmpSprites 数组长度。
            data.index = Mathf.Clamp(data.index, 0, _tmpSprites.Length - 1);

            // 根据当前 index 重新计算 block。
            //
            // 这里把 Sprite.rect 的像素坐标转换成 0~1 的 UV 坐标。
            // 这个 Rect 才是渲染时更常用的数据。
            data.block = new Rect(
                _tmpSprites[data.index].rect.x / wh.x,
                _tmpSprites[data.index].rect.y / wh.y,
                _tmpSprites[data.index].rect.width / wh.x,
                _tmpSprites[data.index].rect.height / wh.y
            );

            // 绘制当前光晕块使用的 Sprite 预览。
            GUI.DrawTextureWithTexCoords(
                new Rect(
                    t.position,
                    new Vector2(60, 60)
                ),
                _targetAssetSlicer.flareSprite,
                data.block
            );

            // 绘制 Index 滑条。
            //
            // 作用：
            // 用户可以修改当前光晕块使用第几个 Sprite。
            //
            // 原理：
            // 改变 index 后，会重新根据 _tmpSprites[index].rect 计算 UV。
            data.index = EditorGUILayout.IntSlider(
                "Index",
                data.index,
                0,
                _tmpSprites.Length - 1
            );

            // 绘制 Rotation 开关。
            //
            // 作用：
            // 控制该光晕块运行时是否根据屏幕方向旋转。
            //
            // 常见原理：
            // 计算当前 flare 到屏幕中心的方向向量，
            // 再用 atan2 求角度，
            // 让图案的朝向跟随光源和屏幕中心的连线。
            data.useRotation =
                EditorGUILayout.Toggle("Rotation", data.useRotation);

            // 绘制 LightColor 滑条。
            //
            // 作用：
            // 控制该光晕块受光源颜色影响的程度。
            //
            // 0 表示完全不使用光源颜色。
            // 1 表示完全使用或强烈叠加光源颜色。
            //
            // 运行时可能类似：
            // finalColor = flareColor * lerp(Color.white, lightColor, useLightColor);
            data.useLightColor =
                EditorGUILayout.Slider("LightColor", data.useLightColor, 0, 1);

            // 结束右侧纵向布局。
            EditorGUILayout.EndVertical();

            // 结束当前横向布局。
            EditorGUILayout.EndHorizontal();

            // 绘制 Offset 滑条。
            //
            // 作用：
            // 控制这个光晕块在镜头光晕线上的位置。
            //
            // 常见原理：
            // Lens Flare 通常沿着光源屏幕坐标和屏幕中心之间的方向排列。
            // offset 决定它在这条线上的相对位置。
            data.offset =
                EditorGUILayout.Slider("Offset", data.offset, -1.5f, 1f);

            // 绘制颜色选择器。
            //
            // 作用：
            // 设置该光晕块自身颜色。
            //
            // 运行时通常会用：
            // finalColor = textureColor * data.color;
            data.color =
                EditorGUILayout.ColorField("Color", data.color);

            // 绘制缩放输入框。
            //
            // 作用：
            // 设置该光晕块的基础大小。
            //
            // 如果 fadeWithScale 开启，
            // 最终缩放可能会是：
            // finalScale = data.scale * fadeValue;
            data.scale =
                EditorGUILayout.FloatField("Scale", data.scale);

            // 绘制 Remove 按钮。
            // 点击后删除当前光晕块。
            if (GUILayout.Button("Remove"))
            {
                _targetAssetSlicer.spriteBlocks.RemoveAt(i);

                // 删除后不递增 i。
                // 因为后面的元素会自动移动到当前 i 位置。
            }
            else
            {
                // 如果没有删除，就把修改后的 struct 写回列表。
                //
                // 因为 MFFlareSpriteData 是值类型，
                // 不写回的话，Inspector 中的修改不会真正保存到列表。
                _targetAssetSlicer.spriteBlocks[i] = data;

                // 继续处理下一个光晕块。
                i++;
            }
        }

        // 如果 Inspector 中有任何数据发生改变，
        // 就把当前资源标记为 Dirty。
        //
        // 作用：
        // 告诉 Unity：
        // 这个 ScriptableObject 已经被修改，需要保存到磁盘。
        if (EditorGUI.EndChangeCheck())
        {
            EditorUtility.SetDirty(_targetAssetSlicer);
        }

        // 记录 Undo 操作。
        //
        // 作用：
        // 让用户可以使用 Ctrl + Z 撤销 Inspector 中的修改。
        //
        // 注意：
        // 更规范的写法通常是在修改数据之前调用 Undo.RecordObject。
        // 当前代码放在最后，虽然不一定完全失效，
        // 但不是最标准的位置。
        Undo.RecordObject(_targetAssetSlicer, "Change Flare Asset Data");
    }
}