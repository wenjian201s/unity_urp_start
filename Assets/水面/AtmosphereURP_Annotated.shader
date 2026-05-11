Shader "Hidden/AtmosphereURP" { // 隐藏Shader：不直接出现在材质创建菜单中，专门给RendererFeature后处理使用。
    
    Properties { // Shader属性区，Unity材质面板和Blitter会通过这些名字传入纹理。
        _BlitTexture ("Texture", 2D) = "white" {} // URP Blitter自动传入的当前相机颜色纹理，也就是后处理前的场景画面。
        _SkyboxTex ("Skybox Texture", Cube) = "white" {} // 天空盒立方体贴图，用于没有几何体的天空像素采样。
    }
    
    SubShader { // SubShader定义当前渲染管线下的具体实现。
        Tags { // Shader标签，用于告诉Unity这个Shader适用于什么渲染管线和渲染类型。
            "RenderPipeline" = "UniversalPipeline" // 指定该Shader只用于URP，避免Built-in/HDRP错误使用。
            "RenderType" = "Opaque" // 后处理本身是全屏覆盖输出，不参与透明物体排序。
        }

        ZWrite Off // 全屏后处理不写入深度；否则会破坏后续UI/后处理/调试显示。
        ZTest Always // 全屏后处理始终通过深度测试，保证屏幕每个像素都被处理。
        Cull Off // 关闭背面剔除；Blitter绘制的全屏三角形不需要区分正反面。

        Pass { // 一个完整的GPU绘制Pass；RendererFeature会调用该Pass进行全屏Blit。
            Name "AtmosphereURP" // Pass名称，方便Frame Debugger中识别。

            HLSLPROGRAM // URP使用HLSLPROGRAM，而不是Built-in常见的CGPROGRAM。
            #pragma vertex Vert // 顶点着色器入口；Vert来自Blit.hlsl，负责生成全屏三角形顶点。
            #pragma fragment Frag // 片元着色器入口；Frag是下面自定义的大气合成函数。

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl" // URP核心函数库，提供GetCameraPositionWS、深度参数、矩阵宏等。
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl" // URP/Core的Blit工具库，定义Vert、Varyings、_BlitTexture等全屏后处理结构。
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl" // 声明_CameraDepthTexture和SampleSceneDepth函数。

            float _FogDensity, _FogOffset; // 雾密度、雾起始距离偏移；由Atmosphere.cs传入。
            float3 _FogColor, _SunColor; // 雾颜色、太阳颜色；使用float3即可，不需要Alpha。

            float4x4 _CameraInvViewProjection; // 相机逆视图投影矩阵，用于从屏幕UV+深度重建世界空间坐标。

            float3 ComputeWorldSpacePositionCustom(float2 positionNDC, float deviceDepth) { // 根据屏幕空间位置和深度计算世界空间位置。
                #if UNITY_REVERSED_Z // 判断当前平台是否使用反向Z缓冲；URP在多数现代平台使用反向Z提高远处深度精度。
                    float z = deviceDepth; // 反向Z平台下，SampleSceneDepth返回值可直接作为裁剪空间深度使用。
                #else
                    float z = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, deviceDepth); // 非反向Z平台需要把深度映射到当前图形API的裁剪空间范围。
                #endif

                float4 positionCS = float4(positionNDC * 2.0 - 1.0, z, 1.0); // 将屏幕UV从0~1转换到裁剪空间-1~1，并填入深度。
                float4 hpositionWS = mul(_CameraInvViewProjection, positionCS); // 乘以逆VP矩阵，把裁剪空间位置还原到齐次世界空间。
                return hpositionWS.xyz / max(0.00001, hpositionWS.w); // 透视除法得到真实世界坐标；max避免w过小导致数值爆炸。
            }

            float _FogHeight, _FogAttenuation, _SkyboxSpeed; // 雾高度、雾高度衰减、天空盒流动速度；由C#传入。
            float3 _SunDirection, _SkyboxDirection; // 太阳方向、天空盒流动方向；由C#传入。

            TEXTURECUBE(_SkyboxTex); // 声明天空盒立方体贴图资源。
            SAMPLER(sampler_SkyboxTex); // 声明天空盒采样器；SAMPLE_TEXTURECUBE需要纹理和采样器配对使用。

            float4 flowUVW(float3 dir, float3 curl, float t, bool flowB) { // 计算流动天空盒采样方向和混合权重。
                float phaseOffset = flowB ? 0.5f : 0.0f; // 第二次采样错开半个周期，用于交叉淡入淡出，减少流动重置时的跳变。
                float progress = t + phaseOffset - floor(t + phaseOffset); // 当前流动进度，使用小数部分让进度循环在0~1。
                float3 offset = curl * progress; // 根据流动方向和进度得到采样偏移。

                float4 uvw = float4(dir, 0.0f); // xyz保存Cubemap采样方向，w保存本次采样的混合权重。
                uvw.xz -= offset.xy; // 在xz方向进行天空盒流动偏移，模拟云/天空纹理移动。
                uvw.w = 1 - abs(1.0f - 2.0f * progress); // 三角波权重：0→1→0，用于两次采样无缝混合。

                return uvw; // 返回偏移后的采样方向和权重。
            }

            bool IsSkyDepth(float rawDepth) { // 判断当前像素是否没有几何体深度，即天空区域。
                #if UNITY_REVERSED_Z // 反向Z中，天空/远平面通常接近0。
                    return rawDepth <= 0.00001;
                #else // 普通Z中，天空/远平面通常接近1。
                    return rawDepth >= 0.99999;
                #endif
            }

            float4 Frag(Varyings input) : SV_Target { // 片元着色器：对屏幕上的每个像素执行一次大气合成。
                float2 uv = input.texcoord; // 当前屏幕UV，范围0~1。
                float4 col = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, uv); // 采样当前相机颜色纹理，得到后处理前的场景颜色。

                float rawDepth = SampleSceneDepth(uv); // 从URP生成的_CameraDepthTexture采样原始硬件深度。
                float3 worldPos = ComputeWorldSpacePositionCustom(uv, rawDepth); // 用屏幕UV和深度重建该像素对应的世界坐标。
                float3 viewDir = normalize(GetCameraPositionWS() - worldPos); // 计算从当前世界点指向相机的观察方向。

                float3 curl = normalize(_SkyboxDirection + 0.00001); // 天空盒流动方向；加极小值避免零向量normalize产生NaN。

                float t = _Time.y * _SkyboxSpeed; // 根据Unity内置时间和速度计算天空盒流动时间。

                float4 uvw1 = flowUVW(-viewDir, curl, t, false); // 第一次天空盒流动采样方向；-viewDir表示从相机向外看的方向。
                float4 uvw2 = flowUVW(-viewDir, curl, t, true); // 第二次天空盒流动采样方向，错开半周期用于无缝循环。
                
                float3 sky = SAMPLE_TEXTURECUBE(_SkyboxTex, sampler_SkyboxTex, uvw1.xyz).rgb * uvw1.w; // 第一次天空盒采样并乘以权重。
                float3 sky2 = SAMPLE_TEXTURECUBE(_SkyboxTex, sampler_SkyboxTex, uvw2.xyz).rgb * uvw2.w; // 第二次天空盒采样并乘以权重。

                sky = (sky + sky2); // 合并两次天空盒采样，形成连续流动效果。

                if (IsSkyDepth(rawDepth)) col.rgb = sky; // 如果该像素是天空区域，则用自定义天空盒颜色替换原场景颜色。

                float height = min(_FogHeight, worldPos.y) / max(0.00001, _FogHeight); // 根据世界高度计算高度比例，越接近雾高度上限，height越接近1。
                height = pow(saturate(height), 1.0f / max(0.00001, _FogAttenuation)); // 应用高度衰减曲线，控制低处雾更浓、高处雾更淡的过渡。

                float linearDepth = Linear01Depth(rawDepth, _ZBufferParams); // 将非线性的硬件深度转换为0~1线性深度。
                float viewDistance = linearDepth * _ProjectionParams.z; // 乘以远裁剪面距离，得到近似相机视距。
                
                float fogFactor = (_FogDensity / sqrt(log(2.0))) * max(0.0f, viewDistance - _FogOffset); // 根据距离计算雾衰减输入；fogOffset让近处不受雾影响。
                fogFactor = exp2(-fogFactor * fogFactor); // 高斯型距离雾：距离越远fogFactor越小，场景颜色越接近雾颜色。

                float3 sunDir = normalize(_SunDirection); // 太阳方向归一化，保证点乘结果稳定在-1~1。
                float3 sun = _SunColor * pow(saturate(dot(viewDir, sunDir)), 3500.0f); // 视线越接近太阳方向，太阳光晕越强；指数越大光晕越尖锐。

                float3 output = lerp(_FogColor, col.rgb, saturate(height + fogFactor)); // 在雾颜色和原始颜色之间混合；混合系数越小雾越浓。
                
                return float4(output + sun, 1.0f); // 输出最终颜色，并叠加太阳光晕；Alpha固定为1表示不透明全屏结果。
            }

            ENDHLSL // 结束HLSL代码块。
        }
    }
}
