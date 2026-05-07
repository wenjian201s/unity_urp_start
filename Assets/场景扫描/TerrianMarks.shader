Shader "TerrianMarks" // 定义 Shader 名称；注意这里可能是 Terrian 的拼写，通常 Terrain Marks 表示地形/场景扫描标记图标。
{ // ShaderLab Shader 代码块开始。
    Properties // 材质面板属性区；这里定义可以在 Inspector 或 C# 中设置的材质参数。
    { // Properties 代码块开始。
        _IconSize("Icon Size", Float) = 1 // 图标尺寸参数；控制每个扫描标记在世界空间中的显示大小。
        [HDR] _SafeColor("Safe Color", Color) = (1, 1, 1, 1) // 安全标记颜色；HDR 表示颜色可以超过 1，用于 Bloom 发光效果。
        [HDR] _WarningColor("Warning Color", Color) = (1, 1, 0, 1) // 警告标记颜色；默认黄色，HDR 可配合后处理产生发光。
        [HDR] _DangerColor("Danger Color", Color) = (1, 0, 0, 1) // 危险标记颜色；默认红色，通常用于高危目标或扫描结果。
    } // Properties 代码块结束。

    SubShader // 定义一个 SubShader；Unity 会根据当前渲染管线和平台选择可用的 SubShader。
    { // SubShader 代码块开始。
        Tags // 设置 SubShader 标签；用于告诉 Unity 这个 Shader 的渲染类型和适用渲染管线。
        { // Tags 代码块开始。
            "RenderType" = "Opaque" // 声明渲染类型为不透明；但该 Pass 实际开启了 Alpha Blend，所以更像透明叠加效果。
            "RenderPipeline" = "UniversalPipeline" // 指定该 Shader 用于 URP，也就是 Universal Render Pipeline。
        } // Tags 代码块结束。

        Pass // 定义一次渲染 Pass；这个 Pass 负责绘制所有扫描标记图标。
        { // Pass 代码块开始。
            Tags // Pass 级别标签；用于指定该 Pass 在 URP 中的渲染阶段。
            { // Pass Tags 代码块开始。
                "LightMode" = "UniversalForward" // 表示该 Pass 参与 URP 的 Forward 渲染路径；会被 Universal Forward 阶段调用。
            } // Pass Tags 代码块结束。

            ZWrite Off // 关闭深度写入；标记图标本身不写入深度缓冲，避免遮挡后续物体或影响场景深度。
            ZTest LEqual // 深度测试为小于等于；图标只有在不被更近物体遮挡时才会显示，符合场景遮挡关系。
            Cull Back // 剔除背面；因为图标面片始终面向相机，通常只需要绘制正面。
            Blend SrcAlpha OneMinusSrcAlpha // 开启标准 Alpha 混合；图标颜色按自身 alpha 叠加到场景画面上。

            HLSLPROGRAM // HLSL 着色器代码开始。
            // #include "UnityCG.cginc" // 旧版 Built-in 管线常用工具库；这里被注释掉，因为当前 Shader 使用 URP 的 HLSL 库。
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl" // 引入 SRP Core 通用函数、宏和基础数学工具。
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl" // 引入 URP 核心函数，例如坐标变换、矩阵、摄像机参数等。
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Input.hlsl" // 引入 URP 输入变量定义，例如灯光、相机、阴影相关全局输入。
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl" // 引入 URP 光照函数；本 Shader 当前没有真正做光照计算，但保留后可扩展。

            #pragma shader_feature _RECEIVE_SHADOWS_OFF // 定义是否关闭接收阴影的材质关键字；当前代码没有显式使用阴影，但 URP 光照库可能依赖该关键字。

            // GPU Instancing // 原注释：启用 GPU 实例化相关编译变体。
            #pragma multi_compile_instancing // 编译支持 GPU Instancing 的变体；允许一次 DrawCall 绘制多个标记实例。
            // #pragma instancing_options procedural:setup // 程序化实例化入口；这里被注释，当前使用 SV_InstanceID + StructuredBuffer 手动取实例数据。

            
            CBUFFER_START(UnityPerMaterial) // 开始定义 UnityPerMaterial 常量缓冲；这些变量按材质传入，SRP Batcher 友好。
                float _IconSize; // 图标大小；在顶点阶段决定面片在世界空间中的宽高。
                float4 _SafeColor; // 安全类型颜色；RGBA，支持 HDR。
                float4 _WarningColor; // 警告类型颜色；RGBA，支持 HDR。
                float4 _DangerColor; // 危险类型颜色；RGBA，支持 HDR。
            CBUFFER_END // 结束 UnityPerMaterial 常量缓冲。
            float colorAlpha; // 全局透明度参数；通常由 C# 动态传入，用于控制所有标记整体淡入淡出。
            
            struct Attributes { // 顶点输入结构；定义网格传给顶点着色器的数据。
                float2 uv : TEXCOORD0; // 输入 UV；这里不仅用于贴图，也作为局部二维坐标来生成图标形状和顶点偏移。
                uint instanceID : SV_InstanceID; // GPU 实例 ID；用于从 markBuffer 中读取当前实例对应的位置和类型。
            }; // Attributes 结构体结束。

            struct Varyings { // 顶点输出/片元输入结构；用于把顶点阶段数据传给片元阶段。
                float2 uv : TEXCOORD0; // 传递 UV 到片元着色器；用于 DrawPattern 绘制圆环、圆点、危险符号等图案。
                float4 positionCS : SV_POSITION; // 裁剪空间位置；GPU 用它把顶点光栅化到屏幕上。
                float3 positionWS : TEXCOORD1; // 世界空间位置；片元阶段用它计算到相机方向并修正写入深度。
                uint instanceID : SV_InstanceID; // 实例 ID 继续传到片元阶段；用于读取当前标记类型。
            }; // Varyings 结构体结束。

            #pragma vertex PassVertex // 指定顶点着色器入口函数为 PassVertex。
            #pragma fragment PassFragment // 指定片元着色器入口函数为 PassFragment。

            struct Marks { // 定义每个扫描标记实例的数据结构；需要和 C# 端 StructuredBuffer 数据布局匹配。
                float3 position; // 标记中心点的世界坐标；决定图标显示在场景中的位置。
                int type; // 标记类型；用于决定绘制安全、警告、危险等不同图案。
            }; // Marks 结构体结束。

            StructuredBuffer<Marks> markBuffer; // GPU 结构化缓冲区；存储所有标记实例的位置和类型，由 C# 传入 Shader。

            Varyings PassVertex(Attributes input) // 顶点着色器；把每个实例的小面片放到对应世界坐标，并让它面向相机。
            { // PassVertex 函数体开始。
                Varyings output; // 声明输出结构体，准备传递给片元阶段。
                float2 uv = input.uv; // 读取当前顶点 UV；后续把 0~1 UV 映射为 -1~1 的局部坐标。
                uint instanceID = input.instanceID; // 读取当前实例 ID；用于访问 markBuffer 中对应的标记数据。

                float3 posCenterWS = markBuffer[instanceID].position; // 从结构化缓冲读取当前实例中心世界坐标。
                       
                float3 dirToCam = GetWorldSpaceNormalizeViewDir(posCenterWS); // 计算从标记中心指向相机的单位方向；用于构建始终面向相机的公告板 Billboard。
                float3 xAxis = normalize(cross(float3(0, 1, 0), dirToCam)); // 用世界上方向和视线方向叉乘得到图标的局部 X 轴；保证图标横向大致平行屏幕。
                float3 yAxis = normalize(cross(dirToCam, xAxis)); // 用视线方向和 X 轴叉乘得到图标局部 Y 轴；与 X 轴、视线方向共同构成正交基。

                float3 posWS = posCenterWS; // 初始化当前顶点世界坐标为图标中心点。
                posWS += xAxis * (uv.x * 2 - 1) * 0.05 * _IconSize; // 根据 UV.x 将顶点向左右偏移；uv.x 从 0~1 映射到 -1~1，形成图标宽度。
                posWS += yAxis * (uv.y * 2 - 1) * 0.05 * _IconSize; // 根据 UV.y 将顶点向上下偏移；形成面向相机的方形图标高度。

                output.positionCS = TransformWorldToHClip(posWS); // 把世界空间顶点转换到齐次裁剪空间，供 GPU 投影到屏幕。
                output.uv = uv; // 把原始 UV 传给片元着色器，用于程序化绘制图案。
                output.positionWS = posWS; // 把顶点世界坐标传给片元着色器，用于计算手动深度。

                output.instanceID = instanceID; // 把实例 ID 传给片元阶段，让每个像素知道自己属于哪个标记实例。

                return output; // 返回顶点输出；GPU 会对三角形内部像素插值这些数据。
            } // PassVertex 函数结束。

            half4 DrawPattern(int type, float2 uv) // 根据标记类型和 UV 程序化绘制图案，返回该像素的颜色。
            { // DrawPattern 函数体开始。
                if (type == 0) // 类型 0：绘制安全圆环图案。
                { // type 0 分支开始。
                    half circle1 = step(0.2, length(uv - 0.5)); // 计算距离中心大于 0.2 的区域；用于挖掉圆环内部。
                    half circle2 = step(length(uv - 0.5), 0.3); // 计算距离中心小于 0.3 的区域；用于限制圆环外半径。
                    half circle = circle1 * circle2; // 内外两个遮罩相乘，得到半径 0.2 到 0.3 之间的圆环。
                    return circle * _SafeColor; // 返回安全颜色圆环；circle 为 0 的地方颜色和 alpha 都为 0。
                } // type 0 分支结束。
                else if (type == 1) // 类型 1：绘制安全实心圆点图案。
                { // type 1 分支开始。
                    half circle = step(length(uv - 0.5), 0.1); // 计算距离中心小于 0.1 的区域，形成小圆点遮罩。
                    return circle * _SafeColor; // 返回安全颜色实心圆点。
                } // type 1 分支结束。
                else if (type == 2) // 类型 2：绘制警告实心圆点图案。
                { // type 2 分支开始。
                    half circle = step(length(uv - 0.5), 0.1); // 计算距离中心小于 0.1 的区域，形成小圆点遮罩。
                    return circle * _WarningColor; // 返回警告颜色实心圆点，默认黄色。
                } // type 2 分支结束。
                else // 其他类型：绘制危险标记图案，一般是类似斜向交叉/高亮符号。
                { // else 分支开始。
                    float distance = length(uv - 0.5); // 计算当前像素到图标中心的距离；用于生成外侧更亮或中心变化的亮度遮罩。
                    float lightMask = saturate((distance - 0.25) * (distance - 0.25) * 50 + 0.2); // 根据距离生成亮度遮罩；远离半径 0.25 的区域更亮，并限制在 0~1。
                    if (uv.y < uv.x + 0.1 && uv.y > uv.x - 0.1 && uv.y > -uv.x + 0.1 && uv.y < -uv.x + 1.95 || uv.y < -uv.x + 1.1 && uv.y > -uv.x + 0.9 && uv.y < uv.x + 0.9 && uv.y > uv.x - 0.9) // 用多条直线不等式组合出两条斜线区域；整体形成类似 X/危险交叉的程序化形状。
                    { // 危险形状区域开始。
                        return lightMask * _DangerColor; // 在危险形状区域返回红色危险颜色，并乘亮度遮罩形成强弱变化。
                    } // 危险形状区域结束。
                } // else 分支结束。
                return 0; // 不属于任何图案区域时返回透明黑色；该像素不会显示。
            } // DrawPattern 函数结束。
            
            half4 PassFragment(Varyings input, out float depth : SV_DEPTH) : SV_Target // 片元着色器；输出颜色到 SV_Target，同时手动输出深度到 SV_DEPTH。
            { // PassFragment 函数体开始。
                float3 dirToCam = GetWorldSpaceNormalizeViewDir(input.positionWS); // 计算当前像素世界位置指向相机的单位方向；用于把写入深度向相机方向偏移。
                half4 color = DrawPattern(markBuffer[input.instanceID].type, input.uv); // 根据当前实例类型和当前像素 UV 绘制对应图案颜色。
                color.a *= colorAlpha; // 用全局透明度控制最终 alpha，实现整体淡入淡出或扫描标记透明度变化。

                // 向相机移动，计算裁切空间位置，透视除法后写入深度 // 原注释：让图标的深度稍微靠近相机，减少与地面/物体表面的 Z-Fighting。
                half4 posNDC4Depth = TransformWorldToHClip(input.positionWS + dirToCam  * _IconSize * 0.1 ); // 将当前像素位置沿视线方向向相机移动一点，再转换到裁剪空间。
                depth = posNDC4Depth.z / posNDC4Depth.w; // 手动写入透视除法后的深度值；使标记在深度测试中略微浮在表面上方。
                
                return color; // 返回最终颜色；由于开启 Alpha Blend，会按 alpha 半透明叠加到场景画面。
            } // PassFragment 函数结束。
            ENDHLSL // HLSL 着色器代码结束。
        } // Pass 代码块结束。

    } // SubShader 代码块结束。
    FallBack "Hidden/Universal Render Pipeline/FallbackError" // 如果 Shader 不兼容或编译失败，使用 URP 的错误回退 Shader，通常显示粉色错误材质。
} // ShaderLab Shader 代码块结束。
