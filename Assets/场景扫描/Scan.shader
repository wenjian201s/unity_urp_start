Shader "Unlit/Scan" // 定义 Shader 名称；在 Unity 材质 Shader 下拉菜单中会显示为 Unlit/Scan，通常用于不受光照影响的后处理/扫描效果。
{ // ShaderLab 的 Shader 代码块开始。
    Subshader // 定义一个 SubShader；Unity 会在当前渲染管线和硬件条件下选择可用的 SubShader 执行。
    { // SubShader 代码块开始。
        Tags // 设置 SubShader 标签，用于告诉 Unity 这个 Shader 的渲染类型和适用管线。
        { // Tags 代码块开始。
            "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" // RenderType=Opaque 表示按不透明物体类型归类；RenderPipeline=UniversalPipeline 表示该 Shader 面向 URP 渲染管线。
        } // Tags 代码块结束。
        Pass // 定义一次渲染 Pass；这个 Pass 会执行一次顶点着色器和片元着色器。
        { // Pass 代码块开始。
            Name "SeparableGlassBlur" // 给 Pass 命名；这里名字叫 SeparableGlassBlur，但实际代码实现的是扫描线、外轮廓和扫描头效果，不是真正的玻璃模糊。
            ZTest Always // 深度测试永远通过；典型用于全屏后处理，因为它不依赖场景几何体的深度测试结果。
            Cull Off // 关闭背面剔除；全屏三角形/全屏后处理不需要剔除正反面。
            ZWrite Off // 关闭深度写入；后处理叠加效果不应该改写摄像机深度缓冲。
            Blend SrcAlpha OneMinusSrcAlpha // 开启透明混合；最终颜色按源 Alpha 与背景颜色混合，实现扫描线/描边的半透明叠加。

            HLSLPROGRAM // HLSL 代码块开始；下面是 URP 使用的顶点/片元着色器代码。
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl" // 引入 URP 核心函数和变量，例如矩阵、坐标变换、_ProjectionParams、_ZBufferParams 等。
            // Blit.hlsl 提供 vertex shader (Vert), input structure (Attributes) and output strucutre (Varyings) // 原注释：Blit.hlsl 提供全屏 Blit 相关的结构和函数。
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl" // 引入全屏三角形 Blit 工具，例如 Attributes、GetFullScreenTriangleVertexPosition、GetFullScreenTriangleTexCoord、_BlitTexture 等。
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl" // 声明 URP 的法线纹理采样接口；本代码当前没有实际采样法线纹理。
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl" // 声明 URP 的摄像机深度纹理采样接口；但当前代码实际是从 _BlitTexture 读取深度值，而不是直接 SampleSceneDepth。
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareOpaqueTexture.hlsl" // 声明 URP 的不透明颜色纹理采样接口；本代码当前没有实际采样 _CameraOpaqueTexture。

            #pragma vertex vert // 指定顶点着色器入口函数为 vert；这里没有直接使用 Blit.hlsl 自带 Vert，而是自定义了一个 vert。
            #pragma fragment frag // 指定片元着色器入口函数为 frag；每个屏幕像素最终由 frag 输出扫描叠加颜色。

            // 中心渐变的范围 // 原注释：下面两个宏原本用于控制中心渐变范围。
            #define centerFadeoutDistance1 1 // 定义中心渐变起始距离常量；但当前代码中没有使用这个宏。
            #define centerFadeoutDistance2 6 // 定义中心渐变结束距离常量；但当前代码中没有使用这个宏，实际代码写死使用 smoothstep(3, 6, distanceToCenter)。

            float3 scanColorHead; // 扫描头颜色；通常由 C# 材质参数传入，用于最亮的环形扫描前沿。
            float3 scanColor; // 普通扫描线和描边颜色；通常由 C# 传入，用于平行扫描线和外轮廓颜色。
            float outlineWidth; // 描边采样宽度；会乘以屏幕像素尺寸，用于控制 Sobel 采样的 UV 偏移距离。
            float outlineBrightness; // 描边亮度倍率；控制深度边缘最终叠加的强度。
            float outlineStarDistance; // 描边开始出现的距离阈值；距离扫描中心达到该范围后，描边会通过 smoothstep 渐显。

            float scanLineInterval; // 平行扫描线之间的间隔；distanceToCenter / interval 后取 frac 形成重复波纹。
            float scanLineWidth; // 平行扫描线宽度；控制每条线在 frac 周期中的宽窄。
            float scanLineBrightness; // 平行扫描线亮度倍率；控制普通扫描线的可见强度。
            float scanRange; // 平行扫描线跟随扫描头出现的范围；决定扫描头后方多远还能看到扫描线。

            float4 scanCenterWS; // 扫描中心的世界坐标；C# 一般会传入一个世界空间位置作为扫描波源点。
            float headScanLineDistance; // 当前扫描头距离中心的半径；通常随时间增加，让扫描圈向外扩散。
            float headScanLineWidth; // 扫描头宽度；影响扫描头环形带的厚度。
            float headScanLineBrightness; // 扫描头亮度倍率；控制扫描头前沿的发光强度。

            sampler2D _Pic; // 声明一张普通 2D 纹理；当前代码中没有使用，可能是早期测试或预留参数。

            struct v2f { // 定义顶点着色器传给片元着色器的数据结构。
                float2 uvs[9] : TEXCOORD0; // 存储 9 个 UV 坐标；中心点加周围 8 邻域，用于 Sobel 深度边缘检测。
                float4 vertex : SV_POSITION; // 裁剪空间顶点位置；SV_POSITION 是 GPU 光栅化需要的屏幕位置语义。
            }; // v2f 结构体结束。

            v2f vert(Attributes v) // 顶点着色器；输入必须使用 Blit.hlsl 中的 Attributes，因为要读取全屏三角形的 vertexID。
            { // 顶点着色器函数体开始。
                v2f o; // 声明输出结构体，用于传递屏幕位置和 9 个采样 UV。
                float4 pos = GetFullScreenTriangleVertexPosition(v.vertexID); // 根据 vertexID 生成全屏三角形的裁剪空间坐标；不依赖场景模型网格。
                float2 uv = GetFullScreenTriangleTexCoord(v.vertexID); // 根据 vertexID 生成对应的全屏 UV；范围通常覆盖 0 到 1。
       
                o.vertex = pos; // 把全屏三角形顶点位置写入输出，供 GPU 光栅化成整屏像素。

                o.uvs[0] = uv + _ScreenSize.zw * half2(-1, 1) * outlineWidth; // 左上邻域 UV；_ScreenSize.zw 通常表示单像素 UV 尺寸，乘 outlineWidth 控制采样半径。
                o.uvs[1] = uv + _ScreenSize.zw * half2(0, 1) * outlineWidth; // 正上邻域 UV；用于 Sobel 纵向/横向梯度采样。
                o.uvs[2] = uv + _ScreenSize.zw * half2(1, 1) * outlineWidth; // 右上邻域 UV；用于检测深度突变边缘。
                o.uvs[3] = uv + _ScreenSize.zw * half2(-1, 0) * outlineWidth; // 左侧邻域 UV；用于 Sobel 水平方向梯度计算。
                o.uvs[4] = uv; // 中心 UV；用于当前像素深度采样和世界坐标重建。
                o.uvs[5] = uv + _ScreenSize.zw * half2(1, 0) * outlineWidth; // 右侧邻域 UV；用于 Sobel 水平方向梯度计算。
                o.uvs[6] = uv + _ScreenSize.zw * half2(-1, -1) * outlineWidth; // 左下邻域 UV；用于 Sobel 卷积核采样。
                o.uvs[7] = uv + _ScreenSize.zw * half2(0, -1) * outlineWidth; // 正下邻域 UV；用于 Sobel 卷积核采样。
                o.uvs[8] = uv + _ScreenSize.zw * half2(1, -1) * outlineWidth; // 右下邻域 UV；用于 Sobel 卷积核采样。

                return o; // 返回顶点输出；随后片元着色器会对每个屏幕像素插值得到这些 UV。
            } // 顶点着色器结束。


            //用uv获取世界坐标 // 原注释：根据屏幕 UV 和深度值重建当前像素的世界坐标。
            float3 GetPixelWorldPosition(float2 uv, float depth01) // 输入屏幕 UV 和线性 0~1 深度，输出世界空间位置。
            { // 世界坐标重建函数开始。
                //重建世界坐标 // 原注释：下面流程是从屏幕空间反推世界空间。
                //NDC反透视除法 // 原注释：先构造远平面上的裁剪/归一化设备坐标方向。
                float3 farPosCS = float3(uv.x * 2 - 1, uv.y * 2 - 1, 1) * _ProjectionParams.z; // 把 UV 从 0~1 转到 -1~1，并乘远裁剪面距离；得到指向远平面的裁剪空间近似位置。
                //反投影 // 原注释：用摄像机逆投影矩阵把裁剪空间位置转到观察空间。
                float3 farPosVS = mul(unity_CameraInvProjection, farPosCS.xyzz).xyz; // 通过逆投影得到远平面上的观察空间位置；xyzz 组成 float4 参与矩阵乘法。
                //获得裁切空间坐标 // 原注释略有不准：这里实际是在观察空间射线上按深度比例缩放。
                float3 posVS = farPosVS * depth01; // 用 0~1 线性深度沿视线方向缩放，得到当前像素的观察空间位置近似值。
                //转化为世界坐标    // 原注释：把观察空间坐标转换成世界空间坐标。
                float3 posWS = TransformViewToWorld(posVS); // 使用 URP 提供的观察空间到世界空间转换函数。
                return posWS; // 返回当前屏幕像素对应的世界坐标。
            } // 世界坐标重建函数结束。

            half calculaateVerticalOutline(float2 uvs[9]) // 计算垂直方向深度边缘强度；函数名 calculaate 多了一个 a，但不影响调用。
            { // 垂直边缘检测函数开始。
                // 使用sobel算子计算深度纹理的梯度:-1 0 1 -2 0 2 -1 0 1  // 原注释：这里实际使用的是 Sobel 的 Y 方向/上下差分权重。
                half color = 0; // 初始化梯度累加值；half 精度更省性能，但范围和精度低于 float。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[0]).x, _ZBufferParams) * -1; // 采样左上深度并乘 -1；Linear01Depth 把硬件深度转换到 0~1 线性深度。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[1]).x, _ZBufferParams) * -2; // 采样正上深度并乘 -2；上方权重更大，用于增强上下方向差异。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[2]).x, _ZBufferParams) * -1; // 采样右上深度并乘 -1；组成 Sobel 上半部分。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[6]).x, _ZBufferParams) * 1; // 采样左下深度并乘 1；与上半部分做差，检测垂直方向深度变化。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[7]).x, _ZBufferParams) * 2; // 采样正下深度并乘 2；下方中心权重更大。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[8]).x, _ZBufferParams) * 1; // 采样右下深度并乘 1；完成 Sobel 上下梯度计算。
                return color; // 返回垂直方向的深度梯度；正负表示变化方向，绝对值大小表示边缘强度。
            } // 垂直边缘检测函数结束。

            half calculateHorizontalOutline(float2 uvs[9]) // 计算水平方向深度边缘强度。
            { // 水平边缘检测函数开始。
                // 使用sobel算子计算深度纹理的梯度:-1 0 1 -2 0 2 -1 0 1  // 原注释：这里使用 Sobel 的 X 方向/左右差分权重。
                half color = 0; // 初始化水平梯度累加值。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[0]).x, _ZBufferParams) * -1; // 采样左上深度并乘 -1；左侧权重为负。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[3]).x, _ZBufferParams) * -2; // 采样正左深度并乘 -2；左侧中心权重更大。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[6]).x, _ZBufferParams) * -1; // 采样左下深度并乘 -1；组成 Sobel 左半部分。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[2]).x, _ZBufferParams) * 1; // 采样右上深度并乘 1；右侧权重为正。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[5]).x, _ZBufferParams) * 2; // 采样正右深度并乘 2；右侧中心权重更大。
                color += Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uvs[8]).x, _ZBufferParams) * 1; // 采样右下深度并乘 1；完成 Sobel 左右梯度计算。
                return color; // 返回水平方向深度梯度；后续会和垂直梯度合成为边缘强度。
            } // 水平边缘检测函数结束。

            half4 frag(v2f i) : SV_Target // 片元着色器；输入为顶点阶段传来的 v2f，输出半精度 RGBA 颜色到当前渲染目标。
            { // 片元着色器函数体开始。
                // rebuild world position // 原注释：重建当前屏幕像素对应的世界坐标。
                float depth01 = Linear01Depth(SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, i.uvs[4]), _ZBufferParams); // 从 _BlitTexture 的中心 UV 采样深度并转成线性 0~1 深度；前提是 _BlitTexture 中确实存的是深度纹理。
                float3 posWS = GetPixelWorldPosition(i.uvs[4], depth01); // 使用屏幕 UV 和线性深度反推出当前像素的世界坐标。

                float distanceToCenter = distance(scanCenterWS, posWS); // 计算当前像素世界坐标到扫描中心的距离；这是所有扫描环、扫描线和遮罩的核心参数。

                // 头部扫描线 // 原注释：计算最前沿的扩散扫描环。
                float scanHeadLine1 = smoothstep(headScanLineDistance + 0.5 * distanceToCenter * 0.03, headScanLineDistance, distanceToCenter); // 生成扫描头前沿遮罩；smoothstep 边界反向时可形成从扫描半径附近向内/向外变化的软边。
                float scanHeadLine2 = smoothstep(headScanLineDistance - headScanLineWidth * distanceToCenter * 0.2, headScanLineDistance, distanceToCenter); // 生成扫描头宽度遮罩；距离越远，宽度按 distanceToCenter 放大，使远处扫描带更宽。
                float scanHeadLine = scanHeadLine1 * scanHeadLine2 * scanHeadLine2 * scanHeadLine2 * headScanLineBrightness; // 多次相乘压缩渐变范围，让扫描头更集中更亮，再乘亮度参数。
                float4 scanHeadLineColor = float4(scanColorHead*scanHeadLine, scanHeadLine); // 生成扫描头颜色；RGB 为扫描头颜色乘强度，Alpha 也使用强度用于透明混合。

                float scanHeadLine3 = smoothstep(headScanLineDistance - headScanLineWidth * distanceToCenter * 0.3 , headScanLineDistance, distanceToCenter); // 生成另一层更宽的扫描头遮罩，用于黑色压暗带。
                float scanHeadLineBlack = scanHeadLine1 * scanHeadLine3 * scanHeadLine3 * scanHeadLine3 * headScanLineBrightness; // 计算黑色扫描带强度；同样用多次相乘让过渡更尖锐。
                float4 scanHeadLineColorBlack = float4(0, 0, 0, scanHeadLineBlack / 2); // 生成半透明黑色带；用于在扫描头附近制造明暗层次或压暗尾部。

                // 平行扫描线范围遮罩 // 原注释：限制普通扫描线只在扫描头附近一定范围内出现。
                float scanLineRange2 = smoothstep(headScanLineDistance - distanceToCenter * 2.5 * scanRange, headScanLineDistance, distanceToCenter); // 根据扫描头距离和 scanRange 生成扫描线影响范围；越靠近扫描头范围越强。
                float scanLineRange = scanHeadLine1 * scanLineRange2 * scanLineRange2; // 把扫描线范围限制到扫描头后方，并平方增强衰减，使范围边缘更柔和。

                // 中心渐变  // 原注释：避免扫描中心附近过亮或出现密集线条。
                float centerFadeout = smoothstep(3, 6, distanceToCenter); // 距离中心 3 以内趋近 0，6 以后趋近 1；让中心附近扫描线淡出。

                // 平行扫描线 // 原注释：生成环状/等距的重复扫描线。
                float wave = frac(distanceToCenter / scanLineInterval); // 用距离除以间隔后取小数部分，得到 0~1 周期波；形成一圈圈重复扫描线。
                float scanLine1 = smoothstep(0.5 - scanLineWidth * distanceToCenter * 0.003, 0.5, wave); // 生成扫描线左侧软边；宽度随距离略微放大。
                float scanLine2 = smoothstep(0.5 + scanLineWidth * distanceToCenter * 0.003, 0.5, wave); // 生成扫描线右侧软边；由于边界反向，形成另一侧衰减。
                float scanLine = scanLine1 * scanLine2; // 左右软边相乘，得到一条以 wave=0.5 为中心的窄线。
                scanLine *= scanLineRange * scanLineBrightness * centerFadeout; // 叠加范围遮罩、亮度参数和中心淡出遮罩，得到最终普通扫描线强度。
                float4 scanLineColor = float4(scanColor*scanLine, scanLine); // 生成普通扫描线颜色；RGB 和 Alpha 都由 scanLine 强度控制。


                // 外描边 // 原注释：基于深度差异做屏幕空间外轮廓。
                half outlineV = calculaateVerticalOutline(i.uvs); // 计算当前像素周围深度的垂直方向梯度。
                half outlineH = calculateHorizontalOutline(i.uvs); // 计算当前像素周围深度的水平方向梯度。
                half outline = sqrt(outlineV * outlineV + outlineH * outlineH); // 合成 Sobel 梯度长度；相当于边缘强度 = sqrt(x² + y²)。
                //近处接近1，中距离接近0，远处为0 // 原注释：根据到扫描中心的距离压低远处描边。
                float depthMask = saturate(1 - distanceToCenter * 0.01); // 距离越远值越小；saturate 把结果限制在 0~1。
                depthMask *= depthMask; // 对遮罩平方，让远处衰减更快，近处保留更明显。
                half outLineDistanceMask = smoothstep(outlineStarDistance - 10, outlineStarDistance, distanceToCenter); // 描边距离遮罩；在 outlineStarDistance 前 10 个单位开始渐显，到阈值后接近 1。
                outline *= 1000 * depthMask; // 放大深度梯度并乘距离衰减；因为线性深度差通常很小，需要放大才能可见。
                outline = step(1, outline) * outlineBrightness * scanHeadLine1 * outLineDistanceMask; // 把连续边缘强度二值化；再乘亮度、扫描头遮罩和距离遮罩，只在扫描区域内显示描边。
                float4 outlineColor = float4(scanColor*outline, outline); // 生成描边颜色；RGB 使用扫描颜色，Alpha 使用描边强度。

                float4 color = scanHeadLineColor + scanHeadLineColorBlack + scanLineColor + outlineColor; // 把扫描头、黑色带、普通扫描线和外描边叠加成最终输出颜色。
                return color ; // 输出叠加颜色；由于 Pass 开启 Alpha Blend，会与当前画面按 Alpha 混合。
            } // 片元着色器结束。
            ENDHLSL // HLSL 代码块结束。
        } // Pass 代码块结束。
    } // SubShader 代码块结束。
} // Shader 代码块结束。
