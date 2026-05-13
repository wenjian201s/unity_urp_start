using System.Collections;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// MFFlareAsset 是一个 ScriptableObject 资源类。
/// 
/// 作用：
/// 用来保存一整套 Lens Flare 镜头光晕的数据。
/// 比如：
/// 1. 光晕使用的贴图图集
/// 2. 光晕淡入淡出的方式
/// 3. 光晕由哪些 flare 小块组成
/// 
/// 原理：
/// ScriptableObject 可以把数据作为 Unity 资源文件保存到 Project 面板中。
/// 这样不同的光源可以复用同一份光晕配置，不需要每个光源都单独写一份数据。
/// 
/// 注意：
/// 这个类只是“数据资产”，并不会自己渲染光晕。
/// 真正的渲染逻辑一般会在另一个 MonoBehaviour 或 RenderPass 中读取它。
/// </summary>
public class MFFlareAsset : ScriptableObject
{
    /// <summary>
    /// 存放镜头光晕使用的贴图图集。
    /// 
    /// 作用：
    /// 一张 flareSprite 贴图中通常会包含多个不同形状的光晕元素。
    /// 例如：
    /// 圆形光斑、六边形光斑、条纹、鬼影、光圈等。
    /// 
    /// 原理：
    /// 每一个 MFFlareSpriteData 通过自己的 Rect block 数据，
    /// 从这张图集中裁剪出对应的小图案。
    /// 这类似于 Sprite Atlas 的使用方式。
    /// </summary>
    public Texture2D flareSprite;

    /// <summary>
    /// 是否使用缩放方式控制光晕淡入淡出。
    /// 
    /// 作用：
    /// 如果开启，当光晕逐渐消失时，
    /// 每个 flare 面片的 scale 会逐渐变小，最后缩放到 0。
    /// 
    /// 原理：
    /// 通过改变 Quad 面片的顶点位置或模型矩阵缩放值，
    /// 让光晕元素看起来逐渐缩小，达到淡出效果。
    /// 
    /// 例如：
    /// fade = 1 时：正常大小
    /// fade = 0.5 时：缩小一半
    /// fade = 0 时：完全不可见
    /// </summary>
    public bool fadeWithScale;

    /// <summary>
    /// 是否使用透明度方式控制光晕淡入淡出。
    /// 
    /// 作用：
    /// 如果开启，当光晕逐渐消失时，
    /// 每个 flare 面片的 Alpha 透明度会逐渐降低。
    /// 
    /// 原理：
    /// 在渲染时修改材质颜色或顶点颜色中的 Alpha 通道，
    /// 再通过透明混合 Blend 实现逐渐消失的效果。
    /// 
    /// 例如：
    /// Alpha = 1 时：完全显示
    /// Alpha = 0.5 时：半透明
    /// Alpha = 0 时：完全透明
    /// </summary>
    public bool fadeWithAlpha;

    /// <summary>
    /// 存储组成一条 Lens Flare 的所有光晕块数据。
    /// 
    /// 作用：
    /// 一条镜头光晕通常不是一个单独的图片，
    /// 而是由多个 flare 元素沿着“光源屏幕位置 - 屏幕中心”这条线分布形成。
    /// 
    /// 每一个 MFFlareSpriteData 表示一个光晕元素。
    /// 它包含：
    /// 1. 使用图集中的哪一块
    /// 2. 缩放大小
    /// 3. 位置偏移
    /// 4. 颜色
    /// 5. 是否旋转
    /// 6. 是否叠加光源颜色
    /// 
    /// 原理：
    /// 渲染时会遍历这个 List，
    /// 根据每个元素的 offset 计算它在屏幕上的位置，
    /// 再根据 block 计算 UV，
    /// 最后绘制一个面向相机的 Quad 面片。
    /// 
    /// 注意：
    /// 这里使用的是 List，不是真正的 Queue。
    /// 它表示一个有序列表，渲染时一般按照列表顺序依次绘制。
    /// </summary>
    public List<MFFlareSpriteData> spriteBlocks;
}