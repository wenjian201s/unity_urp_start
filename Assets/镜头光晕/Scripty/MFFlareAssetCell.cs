using System;
using System.Collections.Generic;
using UnityEngine;

// 下面这个枚举被注释掉了，目前不会参与编译。
// 
// 原本它的作用可能是：
// 用枚举的方式预设几种常见的光晕图集切分模板。
// 
// 比如：
// _2x2      表示图集被切成 2 行 2 列
// _4x4      表示图集被切成 4 行 4 列
// _Mega     可能表示更大的复杂图集
// _1L4S     可能表示 1 个大光斑 + 4 个小光斑
// _1L2M8S   可能表示 1 个大光斑 + 2 个中光斑 + 8 个小光斑
// 
// 但是现在这段枚举被注释掉，说明当前系统不再使用固定模板，
// 而是改成通过 modelCell 手动指定图集切分方式。
// public enum FlareTexModel
// {
//    _2x2 = 0,
//    _4x4 = 1,
//    _Mega = 2,
//    _1L4S = 3,
//    _1L2M8S = 4,
// }

/// <summary>
/// CreateAssetMenu 的作用：
/// 让这个 ScriptableObject 类型可以在 Unity Project 面板中通过右键菜单创建。
/// 
/// 在 Unity 中的创建路径为：
/// Create / MFLensflare / Create FlareAsset split by Cell
/// 
/// 作用：
/// 开发者或美术可以直接创建一个 MFFlareAssetCell 资源文件，
/// 用来配置一套按网格 Cell 切分的 Lens Flare 镜头光晕资源。
/// </summary>
[CreateAssetMenu(
    fileName = "FlareAsset", 
    menuName = "MFLensflare/Create FlareAsset split by Cell"
)]

// <summary>
// Serializable 的作用：
// 允许该类的数据被 Unity 序列化保存。
// 
// 对 ScriptableObject 来说，Unity 本身已经支持序列化，
// 这里加上 [Serializable] 可以进一步明确这个类是可序列化的数据类型。
// </summary>
[Serializable]

// <summary>
// MFFlareAssetCell 继承自 MFFlareAsset。
// 
// 作用：
// 在原本 MFFlareAsset 的基础上，增加“按 Cell 网格切分图集”的能力。
// 
// MFFlareAsset 已经提供了这些基础数据：
// 1. flareSprite：光晕贴图图集
// 2. fadeWithScale：是否用缩放控制淡入淡出
// 3. fadeWithAlpha：是否用透明度控制淡入淡出
// 4. spriteBlocks：组成镜头光晕的所有光晕块数据
// 
// MFFlareAssetCell 额外增加：
// modelCell：表示图集被切成多少列、多少行
// 
// 原理：
// 如果一张 flareSprite 是一个规则图集，例如 4x4，
// 那么就可以通过 modelCell = (4, 4) 自动计算每个小光晕图案的 Rect 区域。
// 
// 这样就不需要手动给每个 flare 元素填写 UV Rect。
// 系统可以根据 index 和 modelCell 自动算出它在图集中的位置。
// </summary>
public class MFFlareAssetCell : MFFlareAsset
{
    /// <summary>
    /// modelCell 表示 flareSprite 图集的网格切分数量。
    /// 
    /// Vector2Int 是 Unity 中的二维整数向量。
    /// 通常：
    /// modelCell.x 表示横向切分数量，也就是列数。
    /// modelCell.y 表示纵向切分数量，也就是行数。
    /// 
    /// 例如：
    /// modelCell = new Vector2Int(2, 2);
    /// 表示图集被切成 2 列 2 行，总共 4 个小图案。
    /// 
    /// modelCell = new Vector2Int(4, 4);
    /// 表示图集被切成 4 列 4 行，总共 16 个小图案。
    /// 
    /// 原理：
    /// 假设图集大小为 textureWidth x textureHeight，
    /// 那么每个 Cell 的大小为：
    /// 
    /// cellWidth  = textureWidth  / modelCell.x
    /// cellHeight = textureHeight / modelCell.y
    /// 
    /// 然后可以根据 MFFlareSpriteData.index 找到对应图案的位置。
    /// 
    /// 例如：
    /// int column = index % modelCell.x;
    /// int row    = index / modelCell.x;
    /// 
    /// 再计算该图案在贴图中的 Rect 区域：
    /// x = column * cellWidth
    /// y = row * cellHeight
    /// width = cellWidth
    /// height = cellHeight
    /// 
    /// 这样就能从整张 flareSprite 图集中取出指定的小光晕图案。
    /// </summary>
    [SerializeField]
    public Vector2Int modelCell;
}