using System;
using UnityEngine;

/// <summary>
/// MFFlareSpriteData 表示一个单独的镜头光晕元素。
/// 
/// 作用：
/// 一条完整的 Lens Flare 由多个光晕元素组成。
/// 每个元素可以有自己的贴图区域、颜色、缩放、位置偏移和旋转方式。
/// 
/// 原理：
/// 渲染 Lens Flare 时，程序会把每个光晕元素绘制成一个屏幕空间中的 Quad 面片。
/// 这个结构体就是用来描述这个 Quad 应该怎么画。
/// 
/// Serializable 的作用：
/// 让 Unity 可以在 Inspector 面板中显示这个结构体的数据，
/// 并且可以把它保存到 ScriptableObject 资产文件中。
/// </summary>
[Serializable]
public struct MFFlareSpriteData
{
    /// <summary>
    /// 控制该 flare 是否使用光源颜色，或者使用光源颜色的强度。
    /// 
    /// 作用：
    /// 如果这个值用于开关：
    /// 0 可以表示不使用光源颜色，
    /// 1 可以表示完全使用光源颜色。
    /// 
    /// 如果这个值用于权重：
    /// 0 表示只使用自身 color；
    /// 0.5 表示自身颜色和光源颜色混合；
    /// 1 表示主要使用光源颜色。
    /// 
    /// 原理：
    /// 渲染时可能会执行类似这样的颜色混合：
    /// 
    /// finalColor = flareColor * lerp(Color.white, lightColor, useLightColor);
    /// 
    /// 也就是说，useLightColor 越大，
    /// 光晕越接近当前光源的颜色。
    /// 
    /// 注意：
    /// 这里字段类型是 float，不是 bool。
    /// 所以它更适合表示“光源颜色影响强度”，而不只是简单开关。
    /// </summary>
    public float useLightColor;

    /// <summary>
    /// 是否让该 flare 根据屏幕方向进行旋转。
    /// 
    /// 作用：
    /// 开启后，这个光晕元素会根据光源在屏幕中的位置产生旋转。
    /// 通常用于让条纹、光斑等元素始终朝向屏幕中心。
    /// 
    /// 原理：
    /// Lens Flare 一般沿着“光源屏幕位置到屏幕中心”的方向分布。
    /// 如果 useRotation 为 true，
    /// 程序会计算当前 flare 到屏幕中心的方向向量，
    /// 然后根据这个方向计算旋转角度。
    /// 
    /// 例如：
    /// Vector2 dir = screenCenter - flareScreenPos;
    /// float angle = atan2(dir.y, dir.x);
    /// 
    /// 最后把这个 angle 应用到 Quad 的旋转上。
    /// </summary>
    public bool useRotation;

    /// <summary>
    /// 当前 flare 元素在图集模板中的序号。
    /// 
    /// 作用：
    /// 用来标识这个 flare 使用图集中的第几个图案。
    /// 
    /// 原理：
    /// 如果 flareSprite 图集被划分成多个小块，
    /// index 可以用来快速定位当前元素应该使用哪一个小块。
    /// 
    /// 例如：
    /// index = 0 表示使用第 0 个 flare 图案；
    /// index = 1 表示使用第 1 个 flare 图案。
    /// 
    /// 注意：
    /// 实际是否使用 index 取决于后续渲染代码。
    /// 如果渲染代码已经直接使用 block 计算 UV，
    /// 那么 index 可能只是辅助编辑器显示或调试使用。
    /// </summary>
    public int index;

    /// <summary>
    /// 当前 flare 元素在图集中的矩形区域。
    /// 
    /// 作用：
    /// 用来记录该 flare 图案在 flareSprite 图集中的位置。
    /// 
    /// Rect 通常包含：
    /// x：矩形左下角或左上角的横坐标
    /// y：矩形左下角或左上角的纵坐标
    /// width：矩形宽度
    /// height：矩形高度
    /// 
    /// 原理：
    /// 渲染时会根据 block 计算 UV 坐标，
    /// 从整张贴图中采样出指定的小 flare 图案。
    /// 
    /// 比如一张图集中有 16 个光晕图案，
    /// block 就告诉 Shader 当前 Quad 应该采样哪一块区域。
    /// </summary>
    public Rect block;

    /// <summary>
    /// 当前 flare 元素的基础缩放值。
    /// 
    /// 作用：
    /// 控制这个光晕元素在屏幕上显示的大小。
    /// 
    /// 原理：
    /// 每个 flare 元素最终一般会被绘制成一个正方形或矩形 Quad。
    /// scale 会影响这个 Quad 的宽高。
    /// 
    /// 例如：
    /// scale = 1 表示标准大小；
    /// scale = 2 表示放大两倍；
    /// scale = 0.5 表示缩小一半。
    /// 
    /// 如果 MFFlareAsset.fadeWithScale 开启，
    /// 最终缩放值可能是：
    /// finalScale = scale * fadeValue;
    /// </summary>
    public float scale;

    /// <summary>
    /// 当前 flare 元素相对于屏幕中心和光源位置连线的偏移值。
    /// 
    /// 作用：
    /// 控制该 flare 出现在 Lens Flare 线条上的哪个位置。
    /// 
    /// 原理：
    /// Lens Flare 通常根据光源屏幕坐标和屏幕中心坐标计算。
    /// 假设：
    /// screenCenter 是屏幕中心；
    /// lightScreenPos 是光源在屏幕上的位置；
    /// offset 控制 flare 在线上的插值位置。
    /// 
    /// 常见计算方式类似：
    /// flarePos = screenCenter + (screenCenter - lightScreenPos) * offset;
    /// 
    /// offset 不同，光晕元素的位置就不同。
    /// 
    /// 例如：
    /// offset = 0：位于屏幕中心附近；
    /// offset = 1：位于光源相对屏幕中心的反方向；
    /// offset < 0：可能靠近光源方向；
    /// 
    /// Range(-1.5f, 1) 的作用：
    /// 限制 Inspector 中可以拖动的数值范围，
    /// 方便美术或开发者调整光晕分布。
    /// </summary>
    [Range(-1.5f, 1)]
    public float offset;

    /// <summary>
    /// 当前 flare 元素自身的颜色。
    /// 
    /// 作用：
    /// 用来控制该 flare 的颜色、亮度和透明度。
    /// 
    /// 原理：
    /// 渲染时这个颜色通常会传入 Shader，
    /// 与 flare 贴图采样结果相乘。
    /// 
    /// 最终颜色可能类似：
    /// finalColor = textureColor * color;
    /// 
    /// 如果开启 useLightColor，
    /// 还可能继续叠加光源颜色。
    /// 
    /// ColorUsage(true, true) 的作用：
    /// 允许在 Inspector 中编辑 HDR 颜色。
    /// 
    /// 第一个 true：
    /// 表示显示 Alpha 通道。
    /// 
    /// 第二个 true：
    /// 表示允许 HDR 颜色，也就是颜色强度可以超过 1。
    /// 
    /// 这对于 Lens Flare 很重要，
    /// 因为光晕通常需要配合 Bloom 后处理产生强烈发光效果。
    /// </summary>
    [ColorUsage(true, true)]
    public Color color;
}