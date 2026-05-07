// Unity built-in shader source. Copyright (c) 2016 Unity Technologies. MIT license (see license.txt) // Unity 内置 Shader 源码版权声明；说明该 Shader 来自 Unity 官方内置资源，并采用 MIT 协议。

Shader "Legacy Shaders/Particles/Blend" { // 定义 Shader 名称；它会显示在材质 Shader 菜单的 Legacy Shaders/Particles/Blend 路径下，属于旧版粒子透明混合 Shader。
Properties { // 定义材质属性区；这些属性可以在 Unity Inspector 面板或 C# 脚本中设置。
    _MainTex ("Particle Texture", 2D) = "white" {} // 粒子主纹理；用于决定粒子的形状、颜色和透明区域，默认使用白色纹理。
    [HDR]_Emission ("Emission (RGB)", Float) = 1 // 发光/亮度倍率；HDR 表示该数值可用于增强亮度，配合 Bloom 可产生发光效果。
    _InvFade ("Soft Particles Factor", Range(0.01,3.0)) = 1.0 // 软粒子淡出系数；用于控制粒子与场景几何体交界处的柔和程度，避免硬边穿插。
} // Properties 代码块结束。

Category { // Category 是旧版 ShaderLab 的分类写法；里面的渲染状态会应用到其下的 SubShader/Pass。
    Tags { "Queue"="Transparent" "IgnoreProjector"="True" "RenderType"="Transparent" "PreviewType"="Plane" } // 设置渲染标签：透明队列渲染、忽略投影器、标记为透明类型、材质预览使用平面。
    Blend SrcAlpha OneMinusSrcAlpha // 开启标准透明混合；最终颜色 = 源颜色 * 源 Alpha + 背景颜色 * (1 - 源 Alpha)。
    ColorMask RGB // 只写入 RGB 颜色通道，不写入 Alpha 通道；适合粒子叠加到画面但不改变目标 Alpha。
    Cull Off Lighting Off ZWrite Off // 关闭背面剔除、关闭固定管线光照、关闭深度写入；粒子通常双面可见且不写深度，避免遮挡后续透明效果。

    SubShader { // 定义一个 SubShader；Unity 会根据平台和渲染能力选择合适的 SubShader 执行。
        Pass { // 定义一个渲染 Pass；这个 Pass 完成粒子的顶点处理和片元着色。

            ZTest Always // 深度测试永远通过；粒子不会被深度缓冲剔除，通常用于希望特效始终显示在画面上的情况。
            CGPROGRAM // 开始 CG/HLSL 着色器代码块；这是旧版 Unity Shader 常用写法。
            #pragma vertex vert // 指定顶点着色器入口函数为 vert。
            #pragma fragment frag // 指定片元着色器入口函数为 frag。
            #pragma target 2.0 // 指定 Shader Model 2.0；兼容性较高，适合旧版粒子 Shader。
            #pragma multi_compile_particles // 编译粒子系统相关变体，例如是否启用软粒子 SOFTPARTICLES_ON。
            #pragma multi_compile_fog // 编译雾效相关变体，使 Shader 能根据场景雾设置开关雾效。

            #include "UnityCG.cginc" // 引入 Unity 内置 CG 工具库；提供坐标变换、雾效、软粒子、深度采样等宏和函数。

            sampler2D _MainTex; // 声明主纹理采样器；片元阶段用 tex2D 从粒子纹理中读取颜色和 Alpha。
            fixed4 _TintColor; // 声明颜色叠加参数；当前代码没有使用它，也没有在 Properties 中暴露，可能是从其他内置粒子 Shader 保留下来的变量。
            fixed _Emission; // 声明发光强度参数；对应 Properties 中的 _Emission，用于放大最终 RGB 亮度。
            
            struct appdata_t { // 定义顶点输入结构；描述粒子网格传入顶点着色器的数据。
                float4 vertex : POSITION; // 顶点局部空间坐标；用于计算粒子顶点最终屏幕位置。
                fixed4 color : COLOR; // 顶点颜色；粒子系统通常用它传递粒子颜色、透明度、生命周期渐变等数据。
                float2 texcoord : TEXCOORD0; // 顶点 UV 坐标；用于采样粒子纹理。
                UNITY_VERTEX_INPUT_INSTANCE_ID // Unity 实例化输入 ID 宏；支持 GPU Instancing 或 stereo instancing 的实例数据传递。
            }; // appdata_t 结构体结束。

            struct v2f { // 定义顶点输出/片元输入结构；顶点阶段计算后传给片元阶段。
                float4 vertex : SV_POSITION; // 裁剪空间顶点坐标；GPU 根据它把粒子面片光栅化到屏幕上。
                fixed4 color : COLOR; // 传递到片元阶段的粒子颜色；会与纹理颜色相乘得到最终颜色。
                float2 texcoord : TEXCOORD0; // 传递到片元阶段的纹理 UV；用于采样 _MainTex。
                UNITY_FOG_COORDS(1) // 声明雾效坐标插值数据，使用 TEXCOORD1；后续用于按距离应用场景雾。
                #ifdef SOFTPARTICLES_ON // 如果启用了软粒子变体，则编译下面的屏幕投影坐标。
                float4 projPos : TEXCOORD2; // 粒子的屏幕投影坐标和眼空间深度；用于采样场景深度并计算软粒子淡出。
                #endif // 软粒子相关插值数据声明结束。
                UNITY_VERTEX_OUTPUT_STEREO // Unity 立体渲染输出宏；用于 VR/双眼渲染时传递 stereo 信息。
            }; // v2f 结构体结束。

            float4 _MainTex_ST; // 主纹理缩放和平移参数；由 Unity 自动生成，TRANSFORM_TEX 会使用它处理 Tiling 和 Offset。

            v2f vert (appdata_t v) // 顶点着色器函数；输入粒子顶点数据，输出屏幕位置、UV、颜色和可选软粒子数据。
            { // vert 函数体开始。
                v2f o; // 声明顶点输出变量。
                UNITY_SETUP_INSTANCE_ID(v); // 初始化当前顶点的实例 ID；让 Unity 的实例化和 stereo 宏能正确工作。
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o); // 初始化立体渲染输出数据；VR/多视图渲染时需要。
                o.vertex = UnityObjectToClipPos(v.vertex); // 将顶点从模型局部空间转换到裁剪空间；这是物体显示到屏幕上的核心变换。
                #ifdef SOFTPARTICLES_ON // 如果启用软粒子，则计算用于深度比较的屏幕投影位置。
                o.projPos = ComputeScreenPos (o.vertex); // 根据裁剪空间坐标计算屏幕空间投影坐标；后续用于投影采样 _CameraDepthTexture。
                COMPUTE_EYEDEPTH(o.projPos.z); // 将 projPos.z 转换/存储为粒子当前像素的眼空间深度，用于和场景深度比较。
                #endif // 软粒子顶点阶段计算结束。
                o.color = v.color; // 把粒子系统传入的顶点颜色传递给片元阶段；通常包含生命周期颜色和透明度。
                o.texcoord = TRANSFORM_TEX(v.texcoord,_MainTex); // 应用 _MainTex 的 Tiling/Offset，得到最终采样 UV。
                UNITY_TRANSFER_FOG(o,o.vertex); // 根据裁剪空间位置计算并传递雾效参数；片元阶段用于应用场景雾。
                return o; // 返回顶点输出；GPU 会在三角形内部对这些数据进行插值。
            } // vert 函数结束。

            UNITY_DECLARE_DEPTH_TEXTURE(_CameraDepthTexture); // 声明相机深度纹理；软粒子需要读取场景深度来判断粒子是否接近几何表面。
            float _InvFade; // 声明软粒子淡出强度；值越大，交界处淡出越快，粒子边缘越硬。

            fixed4 frag (v2f i) : SV_Target // 片元着色器函数；输入插值后的粒子数据，输出最终像素颜色。
            { // frag 函数体开始。
                #ifdef SOFTPARTICLES_ON // 如果启用软粒子，则根据场景深度和粒子深度调整透明度。
                float sceneZ = LinearEyeDepth (SAMPLE_DEPTH_TEXTURE_PROJ(_CameraDepthTexture, UNITY_PROJ_COORD(i.projPos))); // 投影采样相机深度纹理，并转换为线性眼空间深度，表示当前屏幕像素处场景物体的深度。
                float partZ = i.projPos.z; // 当前粒子片元的眼空间深度；由顶点阶段 COMPUTE_EYEDEPTH 计算并插值得到。
                float fade = saturate (_InvFade * (sceneZ-partZ)); // 计算软粒子透明度：粒子越接近场景表面，sceneZ-partZ 越小，fade 越接近 0。
                i.color *= fade; // 将粒子顶点颜色乘以淡出系数；通常会降低 alpha，从而让交界处变透明。
                #endif // 软粒子淡出逻辑结束。

                fixed4 col = i.color * tex2D(_MainTex, i.texcoord); // 采样粒子主纹理，并与粒子顶点颜色相乘；得到基础粒子颜色和透明度。
                UNITY_APPLY_FOG_COLOR(i.fogCoord, col, fixed4(0,0,0,0)); // 根据雾效参数把粒子颜色向黑色雾颜色混合；因为透明混合模式下向黑色过渡更符合旧版粒子表现。
          col.rgb *= _Emission; // 将最终 RGB 乘以发光强度；只影响颜色亮度，不直接改变 Alpha。
                return col; // 输出最终粒子颜色；随后根据 Blend SrcAlpha OneMinusSrcAlpha 与背景混合。
            } // frag 函数结束。
            ENDCG // 结束 CG/HLSL 代码块。
        } // Pass 代码块结束。
    } // SubShader 代码块结束。
} // Category 代码块结束。
} // Shader 代码块结束。
