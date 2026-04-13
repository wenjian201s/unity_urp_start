Shader "DanbaidongRP/ScreenSpaceRainShader"
{//屏幕空间（Screen Space）降雨后处理 Shader
 //不使用真实的3D粒子系统，而是将雨滴贴图通过**圆柱面投影（Cylindrical Projection）
 //的方式贴在屏幕上，并通过深度图（Depth）和高度图（HeightMap）来剔除被遮挡的雨水（例如屋顶下不应该有雨）。
    Properties
    {
        // === 近处雨层属性 ===
        // 允许使用HDR颜色，以便在后处理中产生泛光(Bloom)效果
        [HDR]_RainColor("RainColor", Color) = (1, 1, 1, 1)  //近处雨的颜色
        // 雨滴贴图，通常R通道存储雨滴形状/深度偏移，A通道存储透明度
        _RainTex("Texture Close Rain", 2D) = "black" {}  //雨滴贴图 R通道存储雨滴形状/深度偏移，A通道存储透明度
        // 虚拟雨滴平面距离摄像机的基准距离
        _RainPlaneDistance("RainPlaneDistance", Float) = 5   //雨滴距离摄像机的距离
        // 雨滴平面的厚度范围（用于打破雨滴在同一个绝对平面的假象）
        _RainPlaneRange("RainPlaneRange", Float) = 3   //制作 远近雨的效果
        // 摄像机移动时，雨滴贴图UV偏移的缩放系数，用于模拟视差（Parallax）
        _CameraMoveScale("CameraMoveScale", Range(1, 1000)) = 50  //摄像机视察

        [Space(20)] // Inspector面板中留出空隙
        // === 远处雨层属性（与近处同理，产生远近层次感） ===
        [HDR]_RainColor2("RainColor2", Color) = (1, 1, 1, 1)//远处雨的颜色
        _RainTex2("Texture Far Rain", 2D) = "black" {}//雨滴贴图
        _RainPlaneDistance2("RainPlaneDistance", Float) = 30 //远处雨滴距离摄像机的距离
        _RainPlaneRange2("RainPlaneRange", Float) = 10 //雨滴平面的厚度范围
        _CameraMoveScale2("CameraMoveScale", Range(1, 1000)) = 500 //摄像机移动时，雨滴贴图UV偏移的缩放系数，用于模拟视差
    }
    SubShader
    {
        // 渲染类型为不透明（虽然是半透明效果，但作为全屏后处理Pass，基础设置跟随管线），指定URP管线
        Tags{ "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline"}
        
        Pass
        {
            Name "ScreenSpaceRain"
            
            // -------------------------------------
            // Render State Commands (渲染状态指令)
            
            // 经典的Alpha混合模式：源颜色 * SrcAlpha + 目标颜色 * (1 - SrcAlpha) //取反
            Blend SrcAlpha OneMinusSrcAlpha
            // 深度测试始终通过。因为这是屏幕空间后处理，直接覆盖在画面上，深度遮挡靠代码手动计算
            ZTest Always 
            // 关闭深度写入，雨水本身不应该遮挡其他物体
            ZWrite Off 
            // 关闭背面剔除，全屏Quad绘制任意一面即可
            Cull Off
            
            HLSLPROGRAM
            #pragma target 2.0 // 指定Shader Model 2.0，兼容性极高
            // -------------------------------------
            // Shader Stages
            #pragma vertex Vert // 顶点着色器（来自Core.hlsl或Blit.hlsl内部提供的默认全屏Vert）
            #pragma fragment RainFragment // 片元着色器
            #pragma editor_sync_compilation // 编辑器下同步编译
            #pragma enable_d3d11_debug_symbols // 开启D3D11调试符号，方便抓帧调试

            // -------------------------------------
            // Includes (引入URP核心库和工具函数)
            #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            // 引入声明和采样深度图的宏和函数
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            // === 变量声明（与Properties对应） ===
            //近平面雨的属性参数
            float4 _RainTex_ST; // 贴图的Tiling和Offset，ZW分量通常被C#脚本用来传递下落速度
            float4 _RainColor;
            float _RainPlaneDistance;
            float _RainPlaneRange;
            float _CameraMoveScale;
            //远平面参数
            float4 _RainTex2_ST;
            float4 _RainColor2;
            float _RainPlaneDistance2;
            float _RainPlaneRange2;
            float _CameraMoveScale2;

            // 全局变量，由C#脚本传入。记录摄像机在XZ平面上的移动增量，用于实现雨滴的惯性/视差
            float2 _CameraMoveOffset; 
            // 全局高度图的投影矩阵，用于将世界坐标转换到高度图的UV空间
            float4x4 _RuntimeHeightMapMatrix;

            // 纹理及采样器声明 (URP规范写法)
            TEXTURE2D(_RainTex);
            SAMPLER(sampler_RainTex);

            TEXTURE2D(_RainTex2);
            SAMPLER(sampler_RainTex2);

            // 运行时生成的全局高度图（通常由一个正交相机从上往下拍，记录场景的屋顶、地形高度）
            TEXTURE2D(_RuntimeHeightMapTexture);
            SAMPLER(sampler_RuntimeHeightMapTexture);

            // =========================================================================
            // 核心函数：计算雨滴平面的透明度（包含深度剔除、高度遮挡剔除、视角剔除）
            // =========================================================================
            float ComputeRainPlaneAlpha(float rainTex, float rainPlaneDistance, float rainPlaneRange, float cosViewAngle, float3 camPosWS, float3 viewDirWS, float linearEyeDepth)
            {
                // 1. 计算雨滴的水平距离。利用贴图R通道(0~1)映射到(-1~1)作为随机偏移，加上基础距离。
                // 原理：让雨滴不要全部像一堵平面的墙，而是有前后景深层次。
                float rainDistanceHori = rainPlaneDistance + (rainTex.r * 2.0 - 1.0) * rainPlaneRange;  //计算雨滴镜深
                
                // 2. 将水平距离转换为视线方向上的实际3D距离 (斜边 = 邻边 / cosθ)
                // 原理：摄像机仰视或俯视时，视线是斜的，需要用三角函数算出雨滴离相机的真实距离。
                float rainDropDistance = rainDistanceHori / cosViewAngle; //根据摄像机仰视或俯视时 计算真实的雨滴跟摄像机距离
                
                // 3. 根据距离和视线方向，重建这个雨滴在世界空间中的真实3D坐标
                float3 rainDropPosWS = camPosWS + viewDirWS * rainDropDistance; //根据摄像机位置 已经摄像机像素点的方向和距离 计算真实的3d空间水滴位置

                // 4. 深度测试剔除 (Depth Test)
                // 原理：如果重建的雨滴距离 > 屏幕该像素上真实物体的距离，说明雨滴在物体背后，不显示(返回0)。
                float depthTestAlpha = rainDropDistance < linearEyeDepth; //根据深度计算是否被物体遮挡

                // 5. 顶部视角剔除 (Updir occlusion)
                // 原理：当玩家完全抬头看天(viewDirWS.y 接近1)时，平面的雨水会穿帮，这里用smoothstep让其平滑过渡到消失。
                float topAlpha = 1 - smoothstep(0.85, 1.0, viewDirWS.y); //抬头雨滴消失避免穿帮

                // 6. 顶部遮挡物剔除 (Height occlusion)
                // 原理：防穿墙（如站在屋檐下避雨）。将雨滴的3D世界坐标转换到全局高度图空间。
                float3 rainDropPosHS = mul(_RuntimeHeightMapMatrix, float4(rainDropPosWS, 1.0)); 
                // 采样高度图，获取该位置场景顶部的最高高度
                float4 heightMap = SAMPLE_TEXTURE2D_LOD(_RuntimeHeightMapTexture, sampler_LinearClamp, rainDropPosHS.xy, 0);
                // 如果雨滴的Z值（高度图空间下的高度）大于高度图记录的值，说明雨滴在屋顶下方，被挡住了。
                // (注意：这里取决于矩阵的构造，高度可能映射在Z通道，且此处逻辑看似Z越大表示越向下/越深)
                float heightOcclusionAlpha = rainDropPosHS.z > heightMap.r;

                // 最终透明度 = 深度是否通过 * 是否非极致仰角 * 是否未被屋顶遮挡
                return depthTestAlpha * topAlpha * heightOcclusionAlpha;
            }

            // =========================================================================
            // 片元着色器：处理全屏像素，生成最终画面
            // =========================================================================
            half4 RainFragment(Varyings input) : SV_Target
            {
                // 获取当前全屏的屏幕UV
                float2 uv = input.texcoord; //获取摄像机屏幕的UI
                
                // 采样场景原始深度图
                float depth = SampleSceneDepth(uv); //采用摄像机的深度纹理
                // 将非线性的硬件深度转换为线性的观察空间深度（距离相机的实际单位距离）
                float linearDepth = LinearEyeDepth(depth, _ZBufferParams); //将非线性深度转为线性深度

                // 利用屏幕UV和深度值，反推出当前像素的世界空间坐标
                float3 positionWS = ComputeWorldSpacePosition(uv, depth, UNITY_MATRIX_I_VP); //根据屏幕uv像素点和深度计算屏幕像素对应的世界空间顶点
                // 获取摄像机的世界坐标
                float3 camPosWS = GetCameraPositionWS(); ////获取世界空间摄像机位置

                // 计算从摄像机指向该像素的世界空间视线方向，并归一化
                float3 viewDirWS = SafeNormalize(positionWS - camPosWS); //计算摄像机位置到世界空间顶点的距离
                // 视线方向在XZ水平面上的投影长度，等价于 cos(Pitch) （俯仰角的余弦值）
                float cosViewAngle = length(viewDirWS.xz); //计算摄像机屏幕的（俯仰角的余弦值）飞机x轴

                // -----------------------------------------------------
                // 重建圆柱体UV (Cylinder UV Reconstruction)
                // 原理：如果不做圆柱投影，雨贴图在屏幕转动时会跟着屏幕死板地平移。
                // 使用圆柱投影能让雨滴有处在一个环绕玩家的真实3D圆柱环境中的错觉。
                // -----------------------------------------------------  //根据玩家摄像机位置形成一个包围的圆柱UV 避免摄像机原地转向而雨滴不动
                // theta: 偏航角Yaw，利用atan2算出角度(-PI到PI)，并映射到0~1作为U坐标
                float theta = atan2(viewDirWS.z, viewDirWS.x) * INV_PI * 0.5 + 0.5; //飞机Y轴  根据摄像机的z轴和x轴计算偏航角度Y
                // vertical: 垂直V坐标。viewDirWS.y / cosViewAngle 实质上是 tan(Pitch)。
                // 原理：使用tan值能抵消透视变形，保证在仰视/俯视时雨丝不会过度拉伸。
                float vertical = viewDirWS.y / cosViewAngle;
                // 最终合成用于采样雨滴贴图的2D UV
                float2 cylinderUV = float2(theta, vertical);  //摄像机位置的重建圆柱体UV

                // ================== 近处雨层计算 ==================
                
                // 计算摄像机移动带来的UV偏移量，距离越近，视差位移越明显
                float2 camMoveOffset = _CameraMoveOffset * _RainPlaneDistance / _CameraMoveScale; //由C#脚本传入摄像机偏移量*摄像机距离雨滴的距离 /缩放系数，用于模拟视差

                // 采样近处雨滴贴图
                // cylinderUV * _RainTex_ST.xy : 圆柱UV应用Tiling缩放
                // frac(_RainTex_ST.zw * _Time.y) : 随时间y分量不断向下流动，模拟下雨，frac取小数防精度溢出
                // camMoveOffset : 加上摄像机移动带来的视差偏移
                // LOD(..., 0) : 使用0级Mipmap，防止圆柱投影在UV接缝处(0和1交界处)因为求导产生极大的Mipmap导致接缝线伪影
                float4 rainTex = SAMPLE_TEXTURE2D_LOD(_RainTex, sampler_RainTex, cylinderUV * _RainTex_ST.xy + frac(_RainTex_ST.zw * _Time.y) + camMoveOffset, 0);
                
                // 调用核心函数，计算该像素的近处雨水是否被遮挡  //传入雨滴纹理  ，摄像机距离雨滴平面距离， 范围  ，计算摄像机屏幕的（俯仰角的余弦值） ，世界空间摄像机位置，摄像机位置到世界空间顶点的方向，深度
                float rainPlaneAlpha = ComputeRainPlaneAlpha(rainTex, _RainPlaneDistance, _RainPlaneRange, cosViewAngle, camPosWS, viewDirWS, linearDepth);

                // 计算近处层颜色：这里假定雨滴高光/形状存在红通道（rainTex.r）
                half3 color = rainTex.r * _RainColor.rgb;
                // 计算近处层最终Alpha = 贴图Alpha * 材质颜色Alpha * 遮挡剔除结果
                half alpha = rainTex.r * _RainColor.a * rainPlaneAlpha;  //近处雨水的alpha值根据rain纹理计算的 雨滴结果
              

                // ================== 远处雨层计算 ==================
                // 逻辑与近处雨层完全一致，只是使用了第二套参数(_RainTex2, 距离更大, 运动缩放不同)
                
                float2 camMoveOffset2 = _CameraMoveOffset * _RainPlaneDistance2 / _CameraMoveScale2;// 计算摄像机移动带来的UV偏移量，距离越越，视差位移越明显
                //采样远处处雨滴贴图
                float4 rainTex2 = SAMPLE_TEXTURE2D_LOD(_RainTex2, sampler_RainTex2, cylinderUV * _RainTex2_ST.xy + frac(_RainTex2_ST.zw * _Time.y) + camMoveOffset2, 0);
                //根据核心函数计算场真实远处雨水的alpah
                float rainPlaneAlpha2 = ComputeRainPlaneAlpha(rainTex2, _RainPlaneDistance2, _RainPlaneRange2, cosViewAngle, camPosWS, viewDirWS, linearDepth);

                half3 color2 = rainTex2.r * _RainColor2.rgb;//远处雨水的深度
                half alpha2 = rainTex2.r * _RainColor2.a * rainPlaneAlpha2;  // 计算近处层最终Alpha = 贴图Alpha * 材质颜色Alpha * 遮挡剔除结果

                // ================== 混合输出 ==================
                // 将近处和远处的颜色直接相加（叠加模式），透明度也相加。
                // 最终的 half4 会通过渲染状态中定义的 `Blend SrcAlpha OneMinusSrcAlpha` 与场景画面混合。
                return half4(color + color2, alpha + alpha2);
            }

            
            ENDHLSL
            
        }
        
    }
    
}