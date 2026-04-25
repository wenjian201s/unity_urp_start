// 定义 Shader 名称，在 Unity 材质 Shader 菜单中会显示为 CasualAtmosphere/AerialPerspective
Shader "CasualAtmosphere/AerialPerspective"
{
    // Properties 是 Unity 材质面板中暴露给外部设置的参数区域
    Properties
    {
        // _MainTex 是输入的主纹理，通常在后处理里表示当前相机已经渲染好的屏幕颜色
        // 2D 表示二维纹理，默认值为 white，即没有传入时使用白色纹理
        _MainTex ("_MainTex", 2D) = "white" {}
    }

    // SubShader 是 Shader 的实际渲染实现部分
    SubShader
    {
        // Cull Off：关闭背面剔除
        // 后处理通常绘制一个全屏三角形或全屏四边形，不需要剔除正反面
        Cull Off

        // ZWrite Off：关闭深度写入
        // 因为这是屏幕后处理，不应该修改场景已有的深度缓冲
        ZWrite Off

        // ZTest Always：深度测试永远通过
        // 后处理要覆盖整个屏幕，所以不应该被场景深度挡住
        ZTest Always

        // 定义一个渲染 Pass
        // 这个 Pass 会对整张屏幕执行一次片元着色器
        Pass
        {
            // 开始 HLSL 程序代码块
            HLSLPROGRAM

            // 使用 URP Blitter 的全屏三角形顶点函数。
            #pragma vertex Vert

            // 指定片元着色器入口函数为 frag
            #pragma fragment frag

            // 引入 URP 的核心函数库
            // 其中包含矩阵变换、坐标空间转换、平台兼容宏等基础功能
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // 引入 URP 光照函数库
            // 本文件当前没有直接调用光照函数，但可能是为了和大气散射相关代码保持一致
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            // 引入 URP 深度纹理声明
            // 提供 _CameraDepthTexture 和 SAMPLE_DEPTH_TEXTURE 等深度采样接口
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            // Blitter.BlitCameraTexture 会把源颜色绑定到 _BlitTexture，
            // 并通过 Vert 输出正确的全屏 texcoord。
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

            // 引入自定义辅助函数文件
            // 可能包含数学工具函数、坐标变换函数或通用宏定义
            #include "Helper.hlsl"

            // 引入自定义大气散射计算文件
            // 通常会包含 Rayleigh 散射、Mie 散射、相函数等相关公式
            #include "Scattering.hlsl"

            // 引入自定义大气参数文件
            // 通常会包含地球半径、大气半径、散射系数、太阳方向等参数
            #include "AtmosphereParameter.hlsl"

            // 引入自定义光线步进文件
            // 通常用于沿视线或太阳方向积分大气散射
            #include "Raymarching.hlsl"

            // 定义顶点着色器输入结构体
            struct appdata
            {
                // vertex 是模型空间下的顶点位置
                // POSITION 语义表示该变量来自网格顶点位置
                float4 vertex : POSITION;

                // uv 是模型传入的纹理坐标
                // TEXCOORD0 表示第一套 UV
                float2 uv : TEXCOORD0;
            };

            // 定义顶点着色器输出到片元着色器的数据结构体
            struct v2f
            {
                // uv 传递给片元着色器，用来采样屏幕颜色、深度和 LUT
                float2 uv : TEXCOORD0;

                // vertex 是裁剪空间位置
                // SV_POSITION 是 GPU 光栅化需要的屏幕空间位置语义
                float4 vertex : SV_POSITION;
            };

            // 顶点着色器函数
            // 作用是把全屏网格的顶点从模型空间变换到裁剪空间，并传递 UV
            v2f vert (appdata v)
            {
                // 声明顶点着色器输出结构体
                v2f o;

                // 将模型空间顶点变换到齐次裁剪空间
                // TransformObjectToHClip 是 URP 封装函数，本质上使用 MVP 矩阵完成变换
                o.vertex = TransformObjectToHClip(v.vertex);

                // 将输入 UV 原样传给片元着色器
                // 后处理 Shader 中 UV 通常对应屏幕坐标
                o.uv = v.uv;

                // 返回顶点输出数据
                return o;
            }

            // 声明一个点采样 + Clamp 寻址的采样器
            // point 采样适合采样深度，避免线性过滤导致深度值被混合
            SAMPLER(my_point_clamp_sampler);

            // 声明一个线性过滤 + Clamp 寻址的采样器
            // linear 采样适合颜色和 LUT，使结果在像素之间平滑过渡
            SAMPLER(sampler_aerialLinearClamp);

            // 声明屏幕颜色纹理
            // 通常由渲染管线传入，表示当前帧已经渲染好的场景颜色
            Texture2D _MainTex;

            // 声明 Aerial Perspective LUT 纹理
            // 该纹理存储不同屏幕方向和距离 slice 下的大气透视数据
            // RGB 通常为 in-scattering，A 通常为 transmittance
            Texture2D _aerialPerspectiveLut;

            // 声明透射率 LUT
            // 当前文件没有直接使用，但大气散射系统中常用于查询太阳光穿过大气后的衰减
            Texture2D _transmittanceLut;

            // 声明天空视图 LUT
            // 当前文件没有直接使用，通常用于天空背景颜色的预计算采样
            Texture2D _skyViewLut;

            // Aerial Perspective 的最大作用距离
            // 相机到物体的距离会被归一化到这个范围内，用来决定采样哪个深度 slice
            float _AerialPerspectiveDistance;

            // Aerial Perspective 体素参数
            // 这里至少使用了 .z 作为距离方向 slice 数量
            // .x 被用来缩放 UV 的横向坐标，说明 LUT 很可能是将多个 slice 横向打包进一张 2D 纹理
            float4 _AerialPerspectiveVoxelSize;

            // 根据屏幕 UV 和深度纹理，还原当前像素对应的世界空间位置
            float4 GetFragmentWorldPos(float2 screenPos)
            {
                // 从相机深度纹理中采样当前屏幕像素的原始深度值
                // 使用点采样可以避免相邻物体深度被插值污染
                float sceneRawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, my_point_clamp_sampler, screenPos);

                // 将屏幕 UV 从 [0, 1] 转换到 NDC 的 x、y 范围 [-1, 1]
                // z 使用深度纹理中的 raw depth
                // w 设置为 1，表示齐次坐标
                float4 ndc = float4(screenPos.x * 2 - 1, screenPos.y * 2 - 1, sceneRawDepth, 1);

                // 如果当前平台的 UV 原点在顶部，例如部分 DirectX 平台
                // Unity 会定义 UNITY_UV_STARTS_AT_TOP
                #if UNITY_UV_STARTS_AT_TOP

                    // 翻转 NDC 的 y 坐标
                    // 这是为了修正屏幕 UV 坐标系和裁剪空间坐标系方向不一致的问题
                    ndc.y *= -1;

                #endif

                // 使用相机的逆 VP 矩阵把 NDC / 裁剪空间坐标还原到世界空间
                // UNITY_MATRIX_I_VP 是 ViewProjection 矩阵的逆矩阵
                float4 worldPos = mul(UNITY_MATRIX_I_VP, ndc);

                // 执行透视除法
                // 因为经过逆投影矩阵后得到的是齐次坐标，需要除以 w 才是真正的世界坐标
                worldPos /= worldPos.w;

                // 返回当前像素对应的世界空间位置
                return worldPos;
            }

            // 片元着色器
            // 对屏幕上每一个像素执行，用来计算最终的大气透视合成颜色
            float4 frag (Varyings i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);

                // 取得当前片元的屏幕 UV
                float2 uv = i.texcoord.xy;

                // 从屏幕颜色纹理中采样当前像素原本的场景颜色
                // SampleLevel(..., 0) 表示采样 mip 0，即最高精度 mip 层
                float3 sceneColor = SAMPLE_TEXTURE2D_X_LOD(_BlitTexture, sampler_LinearClamp, uv, 0).rgb;

                if (_AerialPerspectiveDistance <= 0.0 || _AerialPerspectiveVoxelSize.z <= 1.0)
                    return float4(sceneColor, 1.0);

                // ------------------------------------------------------------
                // 天空 mask
                // 作用：判断当前像素是否是天空背景
                // 如果是天空像素，就直接返回原始场景颜色，不叠加地面物体的大气透视
                // ------------------------------------------------------------

                // 从相机深度纹理采样当前像素的原始深度
                float sceneRawDepth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, my_point_clamp_sampler, uv);

            #if UNITY_REVERSED_Z

                // 在 Reversed-Z 深度模式下，远平面深度通常接近 0
                // 天空背景没有真实几何体写入深度，因此通常表现为远平面深度
                // 如果深度为 0，则认为该像素是天空，直接返回原始颜色
                if(sceneRawDepth == 0.0f) return float4(sceneColor, 1.0);

            #else

                // 在普通 Z 深度模式下，远平面深度通常接近 1
                // 如果深度为 1，则认为该像素是天空，直接返回原始颜色
                if(sceneRawDepth == 1.0f) return float4(sceneColor, 1.0);

            #endif

                // 调试代码：如果取消注释，会把非天空区域全部显示为红色
                // return float4(1.0, 0, 0, 1);
                
                // ------------------------------------------------------------
                // 世界坐标计算
                // 作用：根据屏幕 UV 和深度重建当前像素的世界空间位置
                // 这是屏幕后处理里从 2D 像素恢复 3D 信息的常见技术
                // ------------------------------------------------------------

                // 使用深度反投影函数，得到当前像素对应物体表面的世界坐标
                float3 worldPos = GetFragmentWorldPos(uv).xyz;

                // 获取相机世界空间位置
                // _WorldSpaceCameraPos 是 Unity 内置变量
                float3 eyePos = _WorldSpaceCameraPos.xyz;

                // 计算相机到当前像素对应世界点的距离
                // 该距离决定大气透视的强度和采样的距离 slice
                float dis = length(worldPos - eyePos);

                // 计算从相机指向当前世界点的视线方向
                // normalize 用于归一化方向向量，使其长度为 1
                float3 viewDir = normalize(worldPos - eyePos);

                // ------------------------------------------------------------
                // 体素 slice 计算
                // 作用：把真实世界距离映射到 Aerial Perspective LUT 的 Z 方向 slice
                // LUT 中不同 slice 表示不同距离下的大气散射累积结果
                // ------------------------------------------------------------

                // 将当前像素距离除以最大大气透视距离，得到 [0, 1] 范围的距离比例
                // saturate 会把结果限制在 0 到 1 之间，避免越界采样
                float dis01 = saturate(dis / _AerialPerspectiveDistance);

                // 将 [0, 1] 距离比例映射到 [0, SizeZ - 1] 的 slice 空间
                // 例如 SizeZ = 32，则结果范围是 [0, 31]
                float sliceCount = max(_AerialPerspectiveVoxelSize.z, 1.0);
                float dis0Z = dis01 * (sliceCount - 1.0);

                // 取当前距离所在的下方整数 slice
                // floor 表示向下取整
                float slice = floor(dis0Z); 

                // 取下一个 slice，用于在两个距离层之间做线性插值
                // min 防止超过最大 slice 索引
                float nextSlice = min(slice + 1.0, sliceCount - 1.0);

                // 计算当前距离位于 slice 和 nextSlice 之间的比例
                // 例如 dis0Z = 5.3，则 slice = 5，lerpFactor = 0.3
                float lerpFactor = dis0Z - floor(dis0Z);

                // 调试代码：如果取消注释，会显示 slice 插值因子
                // 越接近 0 表示靠近当前 slice，越接近 1 表示靠近下一个 slice
                // return float4(lerpFactor, 0, 0, 1);
                
                // ------------------------------------------------------------
                // LUT 横向坐标计算
                // 作用：由于 3D 体素 LUT 通常被压缩打包成 2D 纹理，
                // 每一个距离 slice 可能被横向排列在同一张纹理上
                // ------------------------------------------------------------

                // 缩放 uv.x，使当前屏幕横向 UV 落入单个 slice 对应的横向区域
                // 这说明 _aerialPerspectiveLut 可能是一个 2D atlas：
                // 横向排列多个距离 slice，每个 slice 只占整张图的一部分宽度
                uv.x /= sliceCount;

                // 调试代码：采样指定 slice 的 LUT 内容
                // 这里的 31.0 / _AerialPerspectiveVoxelSize.z 表示尝试访问第 31 个 slice 的横向偏移
                // return _aerialPerspectiveLut.SampleLevel(sampler_aerialLinearClamp, float2(uv.x + 31.0 / _AerialPerspectiveVoxelSize.z, uv.y), 0);

                // ------------------------------------------------------------
                // 采样 Aerial Perspective Voxel
                // 作用：从预计算的大气透视 LUT 中读取当前像素当前距离下的大气散射结果
                // ------------------------------------------------------------

                // 计算当前 slice 对应的 LUT 采样坐标
                // uv.x 是当前 slice 内部的横向坐标
                // slice / SizeZ 是该 slice 在横向 atlas 中的偏移
                float2 uv1 = float2(uv.x + slice / sliceCount, uv.y);

                // 计算下一个 slice 对应的 LUT 采样坐标
                // 用于后面进行距离方向的线性插值
                float2 uv2 = float2(uv.x + nextSlice / sliceCount, uv.y);

                // 从 Aerial Perspective LUT 中采样当前 slice 的大气数据
                // RGB 通常表示 in-scattering，即沿视线进入相机的大气散射光
                // A 通常表示 transmittance，即物体颜色穿过大气后剩余的透射率
                float4 data1 = _aerialPerspectiveLut.SampleLevel(sampler_aerialLinearClamp, uv1, 0);

                // 从 Aerial Perspective LUT 中采样下一个 slice 的大气数据
                float4 data2 = _aerialPerspectiveLut.SampleLevel(sampler_aerialLinearClamp, uv2, 0);

                // 在当前 slice 和下一个 slice 之间做线性插值
                // 这样可以避免距离变化时出现明显的分层、条带或跳变
                float4 data = lerp(data1, data2, lerpFactor);

                // 取 LUT 的 RGB 作为内散射光
                // inScattering 表示太阳光或环境光被大气粒子散射后进入相机的光
                float3 inScattering = data.xyz;

                if (data.w <= 0.0001 && dot(abs(inScattering), 1.0.xxx) <= 0.0001)
                    return float4(sceneColor, 1.0);

                // 取 LUT 的 A 通道作为透射率
                // transmittance 表示场景物体原本颜色经过大气吸收和散射损耗后保留下来的比例
                float transmittance = saturate(data.w);

                // 调试代码：显示视线方向
                // return float4(viewDir, 1.0);

                // 调试代码：原本可能用于显示某个深度或高度参数 z
                // 当前 z 没有定义，所以不能直接启用
                // return float4(z, 0, 0, 1);

                // 调试代码：显示交换 RGB 通道后的场景颜色
                // return float4(sceneColor.bgr, 1.0);

                // 调试代码：直接返回原始场景颜色，不应用大气透视
                // return float4(sceneColor, 1.0);

                // 最终大气透视合成
                // sceneColor * transmittance 表示远处物体颜色被大气衰减
                // + inScattering 表示沿视线方向累积进入相机的大气散射光
                // 这是典型的单次散射 / 预积分大气透视合成形式
                return float4(sceneColor * transmittance + inScattering, 1.0);
            }

            // 结束 HLSL 程序代码块
            ENDHLSL
        }
    }
}
