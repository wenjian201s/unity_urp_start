Shader "Custom/MyCustomSkyProduce"
{
    Properties
    {
 _upPartSunColor("高空近太阳颜色", Color) = (0.00326,0.18243,0.63132,1) // 作用：定义高空靠近太阳区域的颜色 | 原理：四维向量，RGBA，用于天空颜色插值
        _upPartSkyColor("高空远太阳颜色", Color) = (0.02948,0.1609,0.27936,1) // 作用：定义高空远离太阳区域的颜色 | 原理：同上
        _downPartSunColor("水平线近太阳颜色", Color) = (0.30759,0.346,0.24592,1) // 作用：定义地平线靠近太阳区域的颜色 | 原理：同上
        _downPartSkyColor("水平线远太阳颜色", Color) = (0.04305,0.26222,0.46968,1) // 作用：定义地平线远离太阳区域的颜色 | 原理：同上
        _IrradianceMapR_maxAngleRange("天空主色垂直变化范围", Range(0, 1)) = 0.44837 // 作用：控制天空颜色从上到下的渐变范围 | 原理：作为分母限制角度映射值，控制渐变过渡的急缓
        _mainColorSunGatherFactor("近太阳颜色聚集程度", Range(0, 5)) = 0.31277 // 作用：控制太阳周围天空颜色的聚集锐度 | 原理：用于插值，值越大太阳周围颜色越集中

        _SunAdditionColor("太阳追加点颜色", Color) = (0.90409,0.7345,0.13709, 1) // 作用：太阳附近的附加颜色（如大气散射暖色） | 原理：与IrradianceMap的G通道采样结果相乘
        _SunAdditionIntensity("太阳追加点颜色强度", Range(0, 3)) = 1.48499 // 作用：控制附加颜色的亮度 | 原理：作为系数乘以附加颜色
        _IrradianceMapG_maxAngleRange("太阳追加点垂直变化范围", Range(0, 1)) = 0.69804 // 作用：控制附加颜色在垂直方向的分布范围 | 原理：同_IrradianceMapR_maxAngleRange

        _SunRadius("太阳圆盘大小", Range(0, 50)) = 1 // 作用：控制太阳圆盘的视觉大小 | 原理：作为距离的乘数，值越小允许通过的距离越大，太阳越大
        _SunInnerBoundary("太阳内边界", Range(0, 10)) = 1 // 作用：太阳圆盘内边缘平滑过渡起点 | 原理：smoothstep的参数，控制太阳中心到边缘的过渡
        _SunOuterBoundary("太阳外边界", Range(0, 10)) = 1 // 作用：太阳圆盘外边缘平滑过渡终点 | 原理：smoothstep的参数，控制太阳边缘的羽化程度
        _sun_disk_power_999("太阳圆盘power", Range(0, 1000)) = 1000 // 作用：控制太阳圆盘边缘的锐度/衰减 | 原理：作为pow函数的指数，指数越大边缘衰减越剧烈
        _SunScattering("散射扩散", Range(0, 2)) = 1 // 作用：控制太阳周围的大气散射光晕范围 | 原理：作为距离的乘数，影响散射区域的计算
        _sun_color_intensity("太阳圆盘颜色强度", Range(0, 10)) = 1.18529 // 作用：太阳圆盘亮度 | 原理：颜色乘数
        _sun_color("太阳圆盘颜色", Color) = (0.90625, 0.43019, 0.11743, 1) // 作用：太阳圆盘基础颜色 | 原理：RGB颜色值
        _sun_color_Scat("日出日落散射颜色", Color) = (0.90625, 0.43019, 0.11743, 1) // 作用：日出日落时的次表面散射颜色 | 原理：在地平线附近太阳周围叠加的颜色

        _MoonTex("月亮贴图", 2D) = "white"{} // 作用：月亮的纹理贴图 | 原理：2D纹理资源
        _MoonRadius ("月亮大小", Range(0, 10)) = 3 // 作用：月亮视觉大小 | 原理：控制月亮UV的缩放
        _MoonMaskRadius("月亮遮罩大小", range(1, 10)) = 5 // 作用：月亮光晕/遮罩的半径 | 原理：距离乘数，控制月亮周围光晕范围
        _mainColorMoonGatherFactor("近月亮颜色聚集程度", Range(0, 5)) = 0.31277 // 作用：月亮周围颜色的聚集程度 | 原理：插值因子
        _MoonScatteringColor("月亮散射颜色聚集程度", Color) = (1,1,1,1) // 作用：月亮周围的散射光晕颜色 | 原理：RGB颜色值
        _Moon_color("月亮圆盘颜色", Color) = (0.90625, 0.43019, 0.11743, 1) // 作用：月亮自身颜色 | 原理：与月亮贴图相乘
        _Moon_color_intensity("月亮颜色强度", Range(0, 10)) = 1.18529 // 作用：月亮亮度 | 原理：颜色乘数

        _IrradianceMap("Irradiance Map",2D)= "while"{} // 作用：环境光照贴图，用于采样天空渐变和光照分布 | 原理：R通道控制主色渐变，G通道控制附加色渐变

        _starColorIntensity("星星颜色强度", Range(0, 50)) = 22.7 // 作用：星星亮度 | 原理：颜色乘数
        _starIntensityLinearDamping("星星遮蔽", Range(0, 1)) = 0.80829 // 作用：过滤暗星，控制星星可见数量 | 原理：作为阈值减去噪声值，小于0的星星被剔除

        _NoiseMap("NoiseMap", 2D) = "white" {} // 作用：噪声贴图 | 原理：用于星星闪烁、存在感及颜色变化
        _StarDotMap("StarDotMap", 2D) = "white" {} // 作用：星点分布图 | 原理：定义星星在天空中的位置
        StarColorLut("StarColorLut", 2D) = "white" {} // 作用：星星颜色查找表 | 原理：通过噪声采样Lut赋予星星不同颜色
        [HideInInspector] _StarColorLut_ST("_NoiseMap_ST", Vector) = (0.5,1,0,0) // 作用：Lut贴图的Tiling和Offset | 原理：隐藏属性，控制UV缩放偏移

        [HideInInspector]_StarDotMap_ST("StarDotMap_ST", Vector) = (10,10,0,0) // 作用：星点贴图的Tiling和Offset | 原理：同上
        _NoiseSpeed("c_NoiseSpeed", Range( 0 , 1)) = 0.293 // 作用：噪声流动速度 | 原理：基于时间偏移UV，产生星星闪烁

        _SunDirection("_SunDirection", Vector) = (-0.26102,0.12177,-0.95762, 0) // 作用：太阳方向向量 | 原理：由C#脚本传入，用于计算视角与太阳的夹角
        _MoonDirection("_MoonDirection", Vector) = (-0.33274, -0.11934, 0.93544, 0) // 作用：月亮方向向量 | 原理：同上

        _galaxyTex("银河贴图", 2D) = "white"{} // 作用：银河纹理 | 原理：2D纹理
        _galaxy_INT("银河默认强度", range(0,1)) = 0.2 // 作用：银河基础亮度 | 原理：颜色乘数
        _galaxy_intensity("银河强度", range(0,2)) = 1 // 作用：银河最终亮度加成 | 原理：颜色乘数
    }

    SubShader
    {
        Tags 
        { 
            "RenderPipeline"="UniversalPipeline"
             "RenderType"="Background"
             "IgnoreProjector" = "True" 
            // "RenderType"="Overlay"
            "previewType"="Skybox"
            "Queue" = "Background"

        }
        //LOD 100
        Pass
        {


            ZWrite On
            ZTest LEqual
            Cull Back






            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"


              #define UNITY_HALF_PI       1.57079632679f   //半圆周率
            #define UNITY_INV_HALF_PI   0.636619772367f  //半圆周率的倒数
            #define UNITY_PI            3.14159265359f   //圆周率
            float4x4 LToW;                               //MoonDir//Matrix4x4 LtoW = moon.transform.localToWorldMatrix; for DirectionToSkybox;

            //尽量对齐到float4,否则unity底层会自己填padding来对齐,会有空间浪费
            //Align to float4 as much as possible, otherwise the underlying Unity will fill in padding to align, which will waste space
            CBUFFER_START(UnityPerMaterial)
            float3  _upPartSunColor; // 作用：对应Properties中的颜色 | 原理：接收面板传入值
            float3  _upPartSkyColor; // 作用：对应Properties中的颜色 | 原理：接收面板传入值
            float3  _downPartSunColor; // 作用：对应Properties中的颜色 | 原理：接收面板传入值
            float3  _downPartSkyColor; // 作用：对应Properties中的颜色 | 原理：接收面板传入值
            float _IrradianceMapG_maxAngleRange; // 作用：对应Properties中的参数 | 原理：接收面板传入值
            float3 _SunAdditionColor; // 作用：对应Properties中的颜色 | 原理：接收面板传入值
            float _SunAdditionIntensity; // 作用：对应Properties中的参数 | 原理：接收面板传入值
            float  _sun_disk_power_999; // 作用：对应Properties中的参数 | 原理：接收面板传入值
            float  _sun_color_intensity; // 作用：对应Properties中的参数 | 原理：接收面板传入值
            float3 _sun_color; // 作用：对应Properties中的颜色 | 原理：接收面板传入值
            float _SunInnerBoundary; // 作用：对应Properties中的参数 | 原理：接收面板传入值
            float _SunOuterBoundary; // 作用：对应Properties中的参数 | 原理：接收面板传入值
            float _SunScattering; // 作用：对应Properties中的参数 | 原理：接收面板传入值

            float _IrradianceMapR_maxAngleRange; // 作用：对应Properties中的参数 | 原理：接收面板传入值
            float _mainColorSunGatherFactor; // 作用：对应Properties中的参数 | 原理：接收面板传入值
      
            float _SunRadius; // 作用：对应Properties中的参数 | 原理：接收面板传入值

            sampler2D _IrradianceMap; // 作用：环境光照贴图采样器 | 原理：用于采样2D纹理
            float4 _IrradianceMap_ST; // 作用：光照贴图的Tiling/Offset | 原理：用于UV变换
            sampler2D _MoonTex; // 作用：月亮贴图采样器 | 原理：用于采样2D纹理
            float4 _MoonTex_ST; // 作用：月亮贴图的Tiling/Offset | 原理：用于UV变换

            float _MoonRadius; // 作用：对应Properties中的参数 | 原理：接收面板传入值
            float _MoonMaskRadius; // 作用：对应Properties中的参数 | 原理：接收面板传入值

            float3 _SunDirection; // 作用：太阳方向 | 原理：接收脚本传入值
            float3 _MoonDirection; // 作用：月亮方向 | 原理：接收脚本传入值
            float  _mainColorMoonGatherFactor; // 作用：对应Properties中的参数 | 原理：接收面板传入值
            float3 _MoonScatteringColor; // 作用：月亮散射颜色 | 原理：接收面板传入值
            float3  _Moon_color; // 作用：月亮颜色 | 原理：接收面板传入值
            float _Moon_color_intensity; // 作用：月亮强度 | 原理：接收面板传入值
            float3 _sun_color_Scat; // 作用：太阳散射颜色 | 原理：接收面板传入值

            float _starColorIntensity; // 作用：星星强度 | 原理：接收面板传入值
            float _starIntensityLinearDamping; // 作用：星星遮蔽 | 原理：接收面板传入值

            sampler2D _StarDotMap; // 作用：星点贴图采样器 | 原理：用于采样2D纹理
            float4 _StarDotMap_ST; // 作用：星点贴图Tiling/Offset | 原理：用于UV变换

            float _NoiseSpeed; // 作用：噪声速度 | 原理：接收面板传入值

            sampler2D _NoiseMap; // 作用：噪声贴图采样器 | 原理：用于采样2D纹理
            float4 _NoiseMap_ST; // 作用：噪声贴图Tiling/Offset | 原理：用于UV变换

            sampler2D _StarColorLut; // 作用：星星颜色Lut采样器 | 原理：用于采样2D纹理
            float4 _StarColorLut_ST; // 作用：颜色Lut Tiling/Offset | 原理：用于UV变换

            sampler2D _galaxyTex; // 作用：银河贴图采样器 | 原理：用于采样2D纹理
            float4 _galaxyTex_ST; // 作用：银河贴图Tiling/Offset | 原理：用于UV变换
            float _galaxy_INT; // 作用：银河基础强度 | 原理：接收面板传入值
            float  _galaxy_intensity; // 作用：银河加成强度 | 原理：接收面板传入值
            
            CBUFFER_END
          

            
            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float4 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varings
            {
                float4 positionCS : SV_POSITION;
                float4 uv : TEXCOORD0;
                float3 positionWS : TEXCOORD1;
                float3 normalWS : TEXCOORD2;
                float3 viewDirWS : TEXCOORD3;
                float4 Varying_WorldPosAndAngle:TEXCOORD4;
                  float4 Varying_StarColorUVAndNoise_UV :TEXCOORD5;
                float4 Varying_NoiseUV_large:TEXCOORD6;
                float4 Varying_IrradianceColor:TEXCOORD7;
                float3 Test :TEXCOORD8;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            TEXTURE2D(_MainTex);
            SAMPLER(sampler_MainTex);

                        // 自定义的快速反余弦函数（输入值必须为绝对值即正数）
            // 原理：使用泰勒级数展开式近似计算acos，比原生acos快得多，但精度稍低，适合对性能要求高的天空渲染
            float FastAcosForAbsCos(float in_abs_cos) 
            {
                // 泰勒展开多项式计算弧度值
                float _local_tmp = ((in_abs_cos * -0.0187292993068695068359375 + 0.074261002242565155029296875) * in_abs_cos - 0.212114393711090087890625) * in_abs_cos + 1.570728778839111328125;
                // 乘以sqrt(1 - x^2)还原弧度（基于三角恒等式）
                return _local_tmp * sqrt(1.0 - in_abs_cos);
            }

            // 包装后的快速反余弦函数（支持负数输入）
            float FastAcos(float in_cos)                                      // 对完整 [-1,1] 的 cos 值做快速 acos
            {
                float local_abs_cos = abs(in_cos);                                 // 先取绝对值，复用上面的绝对值版本近似
                float local_abs_acos = FastAcosForAbsCos(local_abs_cos);           // 计算 |cos| 对应的 acos 近似值
                return in_cos < 0.0 ?  UNITY_PI - local_abs_acos : local_abs_acos; // 根据 acos(-x)=π-acos(x) 还原负半轴结果
            }

            Varings vert (Attributes IN)
            {
                Varings OUT;
                ////GPU Instancing
                // UNITY_SETUP_INSTANCE_ID(IN);
                // UNITY_TRANSFER_INSTANCE_ID(IN, OUT);
                
                VertexPositionInputs positionInputs = GetVertexPositionInputs(IN.positionOS.xyz);
                VertexNormalInputs normalInputs = GetVertexNormalInputs(IN.normalOS.xyz);
                //OUT.positionCS = TransformObjectToHClip(IN.positionOS);
                OUT.positionCS = positionInputs.positionCS;
                OUT.positionWS = positionInputs.positionWS;
                OUT.viewDirWS = GetCameraPositionWS() - positionInputs.positionWS;
                OUT.normalWS = normalInputs.normalWS;
                OUT.Varying_WorldPosAndAngle=normalize( float4(positionInputs.positionWS,1.0));
                OUT.uv = IN.uv;

                // 计算星星点阵UV：使用UV的xz通道（球体UV）乘以Tiling，实现星星铺满天空并控制密度
                OUT.Varying_StarColorUVAndNoise_UV.xy = TRANSFORM_TEX(IN.uv.xz , _StarDotMap);
                // 计算星星颜色采样用的噪声UV：乘以20放大频率，使星星颜色变化更细腻随机
                OUT.Varying_StarColorUVAndNoise_UV.zw = IN.uv * 20.0;
                // 计算随时间流动的UV偏移量，用于星星闪烁动画
                float4 _timeScaleValue = _Time.y * _NoiseSpeed * float4(0.4, 0.2, 0.1, 0.5);// 用时间和速度生成四个不同滚动速度，给两组噪声制造差异化动画
                      // 第一层闪烁噪声UV：基础缩放 + 慢速偏移
                 OUT.Varying_NoiseUV_large.xy = (IN.uv.xz * _NoiseMap_ST.xy) + _timeScaleValue.xy;      // 第一组噪声 UV：基础缩放 + 时间偏移
                 // 第二层闪烁噪声UV：双倍缩放 + 另一个速度偏移（两层噪声叠加产生更复杂的闪烁效果）
                OUT.Varying_NoiseUV_large.zw = (IN.uv.xz * _NoiseMap_ST.xy * 2.0) + _timeScaleValue.zw; // 第二组噪声 UV：频率翻倍 + 不同时间偏移，形成更丰富的星空变化


                  // ===== 计算大气散射核心数据 =====
                // 计算当前像素方向与太阳方向的点乘。结果范围[-1, 1]，1表示正对太阳，-1表示背对太阳
                float SunDirection = dot(normalize(positionInputs.positionWS),_SunDirection.xyz);// 计算当前天空方向与太阳方向的点积，值越大说明越接近太阳
                // 将点乘结果从[-1, 1]映射到[0, 1]并截断。0表示背对太阳，1表示正对太阳
                float SunDirectionRemapClamp =clamp((SunDirection * 0.5) + 0.5,0,1.0);// 把点积结果从 [-1,1] 映射到 [0,1]，方便后续 smoothstep/lerp 使用
                // 计算当前像素方向与正上方(0,1,0)的点乘，即余弦值。用于判断仰角
                float _miu = clamp( dot(float3(0,1,0), normalize( positionInputs.positionWS)), -1, 1 );  // 计算当前天空方向与世界上方向(0,1,0)的点积，即“有多朝上”
                // 将仰角余弦值转换为角度，并映射到[-1, 1]范围。1代表正天顶，-1代表正地平线
                float _angle_up_to_down_1_n1 = (UNITY_HALF_PI - FastAcos(_miu)) * UNITY_INV_HALF_PI;// 把顶点方向对应的仰角转换到 [-1,1]，上方为正，下方为负

                   // 保存归一化方向和仰角因子到输出结构体
                OUT.Varying_WorldPosAndAngle.xyz = normalize( positionInputs.positionWS);// 存入归一化世界方向，片元阶段继续使用
                OUT.Varying_WorldPosAndAngle.w   = _angle_up_to_down_1_n1;// 存入“从天顶到地平线再到底部”的角度参数

                // ===== 采样Irradiance图计算太阳追加光晕（在顶点算可节省性能） =====
                float2 _irradianceMap_G_uv; // 声明用于采样辐照贴图 G 通道的 UV
                // 计算垂直方向的U坐标：绝对值除以范围，相当于把仰角压入[0,1]的贴图UV中
                _irradianceMap_G_uv.x = abs(_angle_up_to_down_1_n1) / max(_IrradianceMapG_maxAngleRange, 0.001f);// 按垂直角度决定采样位置，越靠近特定范围变化越明显
                // V坐标固定在0.5，因为这是一维LUT图，只看中间一行
                _irradianceMap_G_uv.y = 0.5; // y 固定为 0.5，表示在一条水平线上采样 1D 梯度图
                // 使用tex2Dlod在顶点着色器中直接采样贴图（不需要梯度信息）
                float _irradianceMapG = tex2Dlod(_IrradianceMap, float4( _irradianceMap_G_uv, 0.0, 0.0 )).y; // 取G通道 // 在顶点阶段用 lod 采样辐照贴图的 G 通道

                // 叠加基础颜色、光晕颜色和强度
                float3 _sunAdditionPartColor = _irradianceMapG * _SunAdditionColor * _SunAdditionIntensity;// 用辐照值调制太阳附加色，形成太阳周边额外颜色层

                // 判断太阳高度：当太阳Y轴大于0.2时，_upFactor趋近于1（白天），否则趋近于0（日出日落）
                float _upFactor = smoothstep(0, 1, clamp((abs(_SunDirection.y) - 0.2) * 10/3, 0, 1));// 根据太阳高度估算“太阳是否较高挂天上”，越高 upFactor 越接近 1
                // 计算靠近太阳的程度：越靠近太阳值越大
                float _VDotSunFactor = smoothstep(0, 1, (SunDirectionRemapClamp -1)/0.7 + 1);   // 根据当前方向靠近太阳的程度得到一个平滑权重
                // 根据太阳高度混合光晕效果：白天光晕不明显(lerp到1被乘掉)，日出日落时光晕明显集中在太阳周围
                float _sunAdditionPartFactor = lerp(_VDotSunFactor, 1.0, _upFactor);/// // 当太阳高挂时更偏向整体增强，否则更偏向太阳方向局部聚集
                // 得到最终的追加光晕颜色
                float3 _additionPart = _sunAdditionPartColor * _sunAdditionPartFactor;  // 计算太阳附加颜色层最终结果
                // 汇总 Irradiance 颜色
                float3 _sumIrradianceRGColor =  _additionPart;// 当前只把附加色放进去，变量名保留了“RG”可能是为了以后扩展

                // 传递给片元着色器
                OUT.Varying_IrradianceColor.xyz = _sumIrradianceRGColor;

                // 调试用的变量输出（无实际渲染意义）
                OUT.Test.xyz = float3(_irradianceMap_G_uv.x,_irradianceMap_G_uv.x,_irradianceMap_G_uv.x);
                
                return OUT;
            }

            half4 frag (Varings IN) : SV_Target
            {
                ////GPU Instancing
                //UNITY_SETUP_INSTANCE_ID(IN);
                //half4 mainColor = UNITY_ACCESS_INSTANCED_PROP(PerInstance, _MainColor);

                // light
                float4 shadowCoord = TransformWorldToShadowCoord(IN.positionWS.xyz);
                Light light = GetMainLight(shadowCoord);
                float3 lightDirWS = light.direction;
                float3 lightColor = light.color;
                float lightIntensity = light.distanceAttenuation;

                float sunDist = distance(IN.uv.xyz, _SunDirection); // 作用：计算片元方向到太阳的角距离 | 原理：空间中两点距离，此处近似角度差
                float MoonDist = distance(IN.uv.xyz,_MoonDirection);// 作用：计算片元方向到月亮的角距离 | 原理：同上

                float sunArea=1-(sunDist*_SunRadius);// 作用：计算太阳圆盘区域 | 原理：距离越近值越大，乘以半径控制范围
                float moonArea = 1 - clamp((MoonDist * _MoonMaskRadius),0,1);// 作用：计算月亮光晕区域 | 原理：距离近时值为正，形成光晕

                 float moonGalaxyMask = step(0.084,MoonDist); // 作用：月亮遮罩银河 | 原理：距月亮近时返回0遮蔽银河，远时返回1
                //散射
                float sunArea2 = 1- (sunDist*_SunScattering);//散射扩散 // 作用：计算太阳散射区域 | 原理：利用散射范围参数计算光晕
                float moonArea2 = 1 - (MoonDist*0.5); // 作用：计算月亮散射区域 | 原理：固定0.5系数计算
                //光晕
                float sunArea3 = 1- (sunDist*0.4); // 作用：计算大范围太阳光晕 | 原理：0.4系数产生较大的光晕
                sunArea3 = smoothstep(0.05,1.21,sunArea3); // 作用：平滑大光晕边缘 | 原理：产生柔和过渡的太阳大气散射
                //太阳边缘
                sunArea = smoothstep(_SunInnerBoundary,_SunOuterBoundary,sunArea); // 作用：平滑太阳圆盘边缘 | 原理：产生清晰或羽化的太阳边界
                //月亮UV
                float3 MoonUV = mul(IN.uv.xyz,LToW); // 作用：变换月亮UV方向 | 原理：使用矩阵修正月亮贴图朝向
                float2 moonUV = MoonUV.xy * _MoonTex_ST.xy*_MoonRadius + _MoonTex_ST.zw; // 作用：计算月亮贴图UV | 原理：应用Tiling、Offset和大小缩放
                //天空盒与天顶角余弦
                float  _WorldPosDotUp = dot(IN.Varying_WorldPosAndAngle.xyz, float3(0,1,0)); // 作用：计算片元高度 | 原理：与正上方点积，即天顶角余弦
                //地平线因子计算
                float  _WorldPosDotUpstep = smoothstep(0,0.1,_WorldPosDotUp); // 作用：地平线裁剪因子 | 原理：低于地平线（值<0）输出0，高于输出1，0-0.1平滑过渡
                 float _WorldPosDotUpstep1  = 1-abs(_WorldPosDotUp ); // 作用：计算地平线附近因子 | 原理：越靠近地平线值越大
                 _WorldPosDotUpstep1 = smoothstep(0.4,1,_WorldPosDotUpstep1 ); // 作用：平滑地平线因子 | 原理：缩放过渡范围
                float _WorldPosDotUpstep2 = clamp(0,1,smoothstep(0,0.01,_WorldPosDotUp)+ smoothstep(0.5,1,_WorldPosDotUpstep1)) ; // 作用：组合高度因子 | 原理：限制在地平线以上且靠近地平线的区域
                float  _WorldPosDotUp_Multi999 = _sun_disk_power_999; // 作用：获取太阳圆盘Power值 | 原理：用于后续指数运算
                //采用贴图
                 float4 moonTex = tex2D(_MoonTex, moonUV)*moonArea*_WorldPosDotUpstep; // 作用：采样月亮贴图 | 原理：采样并乘以光晕和地平线裁剪
                float4 galaxyTex = tex2D(_galaxyTex,IN.uv.xz * _galaxyTex_ST.xy + _galaxyTex_ST.zw); // 作用：采样银河贴图 | 原理：应用缩放偏移
                //裁剪地平线以下的太阳
                sunArea = sunArea *  _WorldPosDotUpstep; // 作用：裁剪地平线以下的太阳 | 原理：低于地平线sunArea置0
                
                // 作用：计算太阳核心多层光晕 | 原理：对RGB三通道分别用不同指数求幂，模拟不同波长的光衰减，点乘合并后产生带色彩过渡的太阳盘面
                float3 _sun_disk = dot(min(1, pow(sunArea3 , _WorldPosDotUp_Multi999 * float3(1, 0.1, 0.01))),float3(1, 0.16, 0.03))* _sun_color_intensity * _sun_color; 
                float3 _sun_disk_sunArea = sunArea * _sun_color_intensity * _sun_color ; // 作用：计算太阳主体颜色 | 原理：基础太阳区域颜色
                _sun_disk = _sun_disk + _sun_disk_sunArea * 3; // 作用：叠加太阳核心和主体 | 原理：合并并增强亮度
                float _LDotDirClampn11_smooth = smoothstep(0, 1, sunArea3); // 作用：太阳光晕蒙版 | 原理：控制太阳盘面外围光晕的显示
                // ===== 6. 大气主色调计算 =====
                  // 采样Irradiance图获取垂直方向的渐变系数（R通道控制主色调）
                
                float2 _irradianceMap_R_uv;                                           // 声明辐照贴图 R 通道采样坐标
                _irradianceMap_R_uv.x = abs(IN.Varying_WorldPosAndAngle.w) / max(_IrradianceMapR_maxAngleRange,0.001f); // 通过垂直角度决定主天空渐变采样位置
                _irradianceMap_R_uv.y = 0.5;                                          // 固定在贴图中线采样，相当于把贴图当 1D 曲线用
                 // 根据靠近太阳的程度计算颜色混合因子
                float _irradianceMapR = tex2Dlod(_IrradianceMap, float4(_irradianceMap_R_uv, 0.0, 0.0)).x; // 采样辐照贴图 R 通道，作为“天顶到地平线”主渐变权重

                // 根据靠近太阳的程度计算颜色混合因子
                float _VDotSunDampingA = max(0, lerp( 1, sunArea2 , _mainColorSunGatherFactor )); // 控制天空主色向太阳附近聚集的强度
                 // 取3次方，让颜色过渡更集中在太阳周围，形成明显的光锥
                float _VDotSunDampingA_pow3 = _VDotSunDampingA * _VDotSunDampingA * _VDotSunDampingA; // 三次方增强对比，让靠近太阳的颜色变化更集中

                // 高空颜色：远太阳色与近太阳色根据靠近程度混合
                float3 _upPartColor   = lerp(_upPartSkyColor, _upPartSunColor, _VDotSunDampingA_pow3);
                // 低空颜色：远太阳色与近太阳色根据靠近程度混合
                float3 _downPartColor = lerp(_downPartSkyColor, _downPartSunColor, _VDotSunDampingA_pow3);
                // 最终主色调：根据仰角在高低空颜色间混合，_irradianceMapR提供了非线性过渡曲线
                float3 _mainColor = lerp(_upPartColor, _downPartColor, _irradianceMapR);

                 // ===== 7. 月亮光晕与天空SSS（伪次表面散射）计算 =====
                // 月亮光晕混合因子
                float _VDotMoonDampingA = max(0, lerp( 1, moonArea2 , _mainColorMoonGatherFactor ));  // 控制月亮附近的颜色聚集程度
                float _VDotMoonDampingA_pow3 = _VDotMoonDampingA *_VDotMoonDampingA;  // 做平方增强，突出月亮周边颜色变化

                // 模拟天空的次表面散射（日出日落时地平线附近被照红）
                // 将靠近太阳的程度取5次方（极度集中），并乘以地平线遮罩（仅在地平线生效）  // 计算地平线附近的太阳散射强度，太阳越强且越靠近地平线，散射越明显
                float SSS = clamp( _VDotSunDampingA_pow3*_VDotSunDampingA *_VDotSunDampingA  * _WorldPosDotUpstep1 ,0,1);
                // 去除极微弱的杂色，平滑过渡
                SSS = smoothstep(0.02,0.5, SSS );// 把散射结果平滑化，避免过于生硬
                // 再次叠加地平线遮罩确保干净
                SSS = SSS *  _WorldPosDotUpstep2;// 再乘地平线区域遮罩，只保留合理散射区域
                // 乘以日出日落散射颜色
                float3 SSSS =  SSS *_sun_color_Scat;// 得到最终散射颜色（SSSS 只是作者的变量名）

                  // 合并月亮本体颜色和光晕
                float3 FmoonColor =  (moonTex.xyz*_Moon_color*_Moon_color_intensity) + _VDotMoonDampingA_pow3*_MoonScatteringColor;


                // ===== 8. 白天部分颜色合成 =====
                // 太阳本体(带泛光过渡) + 太阳追加光(顶点算的) + 大气主色 + 月亮
                float3 _day_part_color = (_sun_disk * _LDotDirClampn11_smooth ) + IN.Varying_IrradianceColor.xyz + _mainColor+ FmoonColor;

                 // ===== 9. 星星渲染计算 =====
                // 采样两层不同速度和频率的噪声，作为星星的闪烁和随机遮挡层
                float _starExistNoise1 = tex2D(_NoiseMap, IN.Varying_NoiseUV_large.xy).r;// 第一层噪声，决定星星是否存在/闪烁
                float _starExistNoise2 = tex2D(_NoiseMap, IN.Varying_NoiseUV_large.zw).r;// 第二层噪声，与第一层相乘增强随机性
                // 采样星星基底点阵图
                float _starSample = tex2D(_StarDotMap, IN.uv.xz*_StarDotMap_ST.xy+_StarDotMap_ST.zw  ).r;// 采样星点分布图，决定哪些位置可以生成星星
                // 将点阵图与两层噪声相乘：只有点阵图有星的地方，且噪声值也刚好符合，星星才存在。实现随机闪烁效果
                float _star = _starSample * _starExistNoise2 * _starExistNoise1;  // 星星基础强度 = 星点分布 × 两层噪声

                  // 计算星星的仰角淡出：越靠近地平线（_miuResult越小），星星越暗，防止星星画在地面或浓厚大气中
                float _miuResult = IN.Varying_WorldPosAndAngle.w * 1.5; // 根据垂直角度增强上半球星星显示，通常越高越容易显示星空
                _miuResult = clamp(_miuResult, 0.0, 1.0); // 把星空可见度钳制到 0~1
                float _star_intensity = _star * _miuResult; // 星星强度乘上垂直可见度
                _star_intensity *= 3.0; // 整体提亮星星底色 // 整体把星星亮度再抬高一些

                 // 根据颜色噪声进行亮度阈值过滤：_starIntensityLinearDamping作为阈值，
                // 只有噪声值大于阈值的星星才被保留，过滤掉大部分暗淡的噪点
                float _starColorNoise = tex2D(_NoiseMap, IN.Varying_StarColorUVAndNoise_UV.zw).r; // 再采样一份噪声，用于控制星星亮度和颜色选取
                float _starIntensityDamping = (_starColorNoise - _starIntensityLinearDamping) / (1.0 -_starIntensityLinearDamping);// 根据阈值把较弱噪声压掉，只保留足够“亮”的星点
                _starIntensityDamping = clamp(_starIntensityDamping, 0.0, 1.0);// 把衰减结果限制在 0~1
                // 将过滤后的强度应用到星星上
                _star_intensity = _starIntensityDamping * _star_intensity;// 应用阈值衰减，让星空更稀疏自然


                 // 采样星星颜色LUT图：根据之前的噪声值决定这颗星是红色、蓝色还是白色
                float2 _starColorLutUV;   // 声明星星颜色 LUT 的采样坐标
                _starColorLutUV.x = (_starColorNoise * _StarColorLut_ST.x) + _StarColorLut_ST.z;// 用噪声值映射到 LUT 横坐标，不同噪声值对应不同星体颜色
                _starColorLutUV.y = 0.5; // 固定在中间行   // y 固定 0.5，等价于在中线读取 1D 颜色表
                float3 _starColorLut = tex2D(_StarColorLut, _starColorLutUV).xyz;// 读取星星颜色 LUT
                // 乘以颜色强度系数
                float3 _starColor = _starColorLut * _starColorIntensity; // 乘颜色强度，得到最终星星颜色

                // 最终星星颜色 = 亮度 * 颜色 * 月亮遮罩（被月亮挡住的星星不显示）
                float3 _finalStarColor = _star_intensity * _starColor*moonGalaxyMask; // 星星最终颜色；月亮附近通过 moonGalaxyMask 被压掉，避免和月亮重叠


                
                // ===== 10. 银河最终处理 =====
                // 提取银河贴图的Alpha通道（通常存的是银河的蒙版形状），取10次方使边缘极度锐利，去除杂边
                galaxyTex.w = pow(galaxyTex.w,10);  // 强化银河 alpha/亮度分布，让亮区域更突出、暗区域更快衰减
                // 银河最终颜色 = 颜色 * 蒙版 * 高度遮罩(只在上半球) * 基础强度 * 月亮遮挡 * 整体强度系数
                float3 galaxyColor =clamp((galaxyTex.xyz*galaxyTex.w*_WorldPosDotUp *_galaxy_INT*moonGalaxyMask*_galaxy_intensity),0,1);

                
                // ===== 11. 最终输出合成 =====
                // SSS散射光 + 白天天空(含太阳月亮) + 星星 + 银河，Alpha设为1（完全不透明）
                return float4(SSSS+_day_part_color+_finalStarColor+galaxyColor,1);

              
            }
            ENDHLSL
        }


    }
    //使用官方的Diffuse作为FallBack会增加大量变体，可以考虑自定义
    //FallBack "Diffuse"
}