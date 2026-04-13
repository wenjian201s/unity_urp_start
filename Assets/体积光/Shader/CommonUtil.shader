// 声明一个Shader，路径为Hidden/RecaNoMaho/CommonUtil。"Hidden"表示在材质面板中隐藏，通常由C#代码（如Render Feature）动态调用
Shader "Hidden/RecaNoMaho/CommonUtil"
{
    // 子着色器区块，Unity会自动选择最合适的子着色器执行，这里只有一个
    SubShader
    {
        // 渲染标签：RenderType=Opaque告诉Unity这是一个不透明物体（虽然后处理其实是全屏Quad，但这是常规写法）；
        // RenderPipeline=UniversalPipeline声明该Shader仅用于URP渲染管线
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline"}
        // 细节级别设为100。当项目设置的LOD低于此值时，该Shader将不被使用，100是基础值
        LOD 100

        // 渲染通道Pass
        Pass
        {
            // 通道命名为"Blit Add"，方便在C#端通过CommandBuffer或RenderFeature精准找到并执行该Pass
            Name "Blit Add"
            // 深度测试设为始终通过。因为后处理是绘制一个覆盖全屏的四边形，不需要考虑场景原有的深度关系，必须保证全部绘制
            ZTest Always
            // 关闭深度写入。后处理只是叠加颜色，绝对不能把全屏Quad的深度写入深度缓冲，否则会破坏后续的渲染
            ZWrite Off
            // 关闭背面剔除。绘制全屏Quad时，因为相机旋转等原因，Quad的正面可能背对相机，关闭剔除可保证无论什么角度都能画上
            Cull Off
            // 设置混合模式为 加法混合。
            // 原理：最终颜色 = 源颜色(Shader输出) * 1 + 目标颜色(屏幕原有颜色) * 1。
            // 这是体积光叠加的核心：光能量是增加的，黑色的体积光区域(0)不会影响原画面，亮的部分会越叠越亮，符合物理光照叠加直觉
            Blend One One

            // 标记HLSL代码段的开始
            HLSLPROGRAM
            // 编译指令：告诉编译器顶点着色器使用名为"Vert"的函数（该函数定义在下方引入的Blit.hlsl中）
            #pragma vertex Vert
            // 编译指令：告诉编译器片元着色器使用名为"Fragment"的函数（定义在下方）
            #pragma fragment Fragment

            // 引入URP核心库，提供基础的矩阵变换、宏定义等。注释说明引入它主要是为了支持VR/XR（立体渲染）的相关依赖
            // Core.hlsl for XR dependencies
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            // 引入URP官方提供的Blit工具库。
            // 原理：该库内置了后处理专用的顶点着色器、Varyings结构体、以及源纹理_BlitTexture的定义，避免开发者重复写全屏Quad的顶点逻辑
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            // 引入URP的全屏调试工具库。原理：允许在Scene视图的Game窗口下拉菜单中叠加各种调试视图（如法线、深度等）
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Debug/DebuggingFullscreen.hlsl"
            // 引入核心颜色工具库。原理：提供颜色空间转换函数（如Linear转sRGB），确保在不同色彩空间设置下颜色显示正确
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Color.hlsl"

            // 声明一个采样器状态，绑定到名为"BlitTexture"的纹理。它决定了纹理采样的过滤方式（如双线性过滤）和寻址模式（如Clamp）
            SAMPLER(sampler_BlitTexture);

            // 片元着色器函数。输入参数input是顶点着色器传过来的插值数据，SV_Target表示将返回值输出到当前的渲染目标上
            half4 Fragment(Varyings input) : SV_Target
            {
                // Unity XR(如VR)必须的宏。原理：从顶点着色器传过来的数据中提取当前渲染的是左眼还是右眼的索引，以保证立体渲染时纹理采样正确
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                // 从传入的顶点数据中提取屏幕UV坐标（范围通常是0~1），这个UV对应屏幕上的每一个像素
                float2 uv = input.texcoord;

                // 使用宏进行纹理采样。_BlitTexture是输入的源图（比如算好的体积光图），sampler_BlitTexture是采样器。
                // 原理：SAMPLE_TEXTURE2D_X是一个智能宏，如果是普通屏幕它等同于SAMPLE_TEXTURE2D，如果是VR立体渲染，它会自动处理纹理数组
                half4 col = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_BlitTexture, uv);

                // 条件编译指令：检查是否定义了"_LINEAR_TO_SRGB_CONVERSION"宏（通常由C#端根据目标RT的格式动态开启）
                #ifdef _LINEAR_TO_SRGB_CONVERSION
                // 如果目标纹理要求sRGB格式，而我们在Shader里是在线性空间计算的，这里需要手动将颜色从线性空间转换回伽马空间。
                // 原理：防止画面因为缺少伽马校正而看起来发灰、过亮
                col = LinearToSRGB(col);
                // 结束条件编译
                #endif

                // 条件编译指令：检查是否处于开发版的调试显示模式
                #if defined(DEBUG_DISPLAY)
                // 初始化一个调试颜色变量为纯黑(0)
                half4 debugColor = 0;

                // 调用调试库函数，判断当前是否开启了某种全屏调试覆盖（比如查看光照复杂度、材质属性等）
                if(CanDebugOverrideOutputColor(col, uv, debugColor))
                {
                    // 如果开启了调试视图，直接返回调试颜色，忽略正常的体积光混合结果
                    return debugColor;
                }
                // 结束调试条件编译
                #endif

                // 正常情况下，返回采样到的颜色。配合上面的"Blend One One"，这个颜色会被加法叠加到背板上
                return col;
            }
            // 标记HLSL代码段的结束
            ENDHLSL
        }
    }
}
