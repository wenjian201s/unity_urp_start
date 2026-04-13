// 声明一个Shader，路径为Hidden/RecaNoMaho/VolumetricLight。"Hidden"表示该Shader不会出现在材质面板中，通常由C#脚本通过CommandBuffer或RenderFeature调用
Shader "Hidden/RecaNoMaho/VolumetricLight"
{
    // 属性块，这里为空是因为体积光的所有参数都由C#端直接通过CommandBuffer传递，不需要材质球面板赋值
    Properties
    {
        
    }
    
    // HLSL代码块，包含顶点和片元着色器共享的变量、函数和结构体
    HLSLINCLUDE

    // 宏定义：启用URP的额外灯光阴影，必须定义此宏才能在片元着色器中采样Additional Lights的阴影贴图
    #define _ADDITIONAL_LIGHT_SHADOWS

    // 引入Unity核心通用库，提供基础的宏、函数和结构体（如UnityObjectToClipPos等）
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
    // 引入URP核心库，提供相机参数、灯光参数等（如_WorldSpaceCameraPos, _ZBufferParams等）
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
    // 引入通用材质库，提供一些基础的光照计算辅助函数
    #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/CommonMaterial.hlsl"
    // 引入URP阴影库，提供获取阴影采样数据、坐标转换和阴影采样等核心函数
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

    // 声明相机深度纹理，用于获取场景中物体的深度，从而决定光线步进的终点
    TEXTURE2D(_CameraDepthTexture); 
    // 声明深度纹理的采样器，使用默认的sampler（通常为线性夹取）
    SAMPLER(sampler_CameraDepthTexture);
    // 声明蓝噪声纹理，用于在Ray Marching时进行空间抖动，消除因固定步长带来的条带伪影
    TEXTURE2D(_BlueNoiseTexture);

    // Ray Marching包围盒的裁剪平面数量，通常为6（对应一个长方体的6个面）
    int _BoundaryPlanesCount;
    // 存储包围盒平面的方程系数，平面方程为 Ax + By + Cz + D = 0，xyz分量代表法线，w分量代表D
    float4 _BoundaryPlanes[6]; 
    // 光线步进的次数，步数越多精度越高，性能消耗越大
    int _Steps;

    // 方向光的理论距离（由于方向光无衰减，设为一个极大值参与透射率计算）
    float _DirLightDistance;
    // 光源位置，.w分量是一个巧妙的开关：0代表方向光（此时xyz为方向），1代表点光源/聚光灯（此时xyz为位置）
    float4 _LightPosition;
    // 光源方向（对于聚光灯，表示光线照射的中心轴方向）
    float4 _LightDirection;
    // 光源颜色和强度（RGB为颜色，A通常未使用或作为强度乘数）
    float4 _LightColor;
    // 聚光灯的半角余弦值，用于计算点是否在聚光灯锥体内
    float _LightCosHalfAngle;
    // 是否开启阴影的开关（1为开启，0为关闭）
    int  _UseShadow;
    // 额外光源在URP中的索引，用于查找对应的阴影贴图和矩阵
    int _ShadowLightIndex;

    // 透射消光系数，决定介质（雾）的浓度，值越大雾越浓
    float _TransmittanceExtinction;
    // 入射光损耗系数，控制光线从光源到达介质内部某点时的能量衰减程度（模拟光源到介质间的雾）
    float _IncomingLoss; 
    // Henyey-Greenstein相位函数的非对称因子g，取值[-1, 1]。趋近1时光强烈向后散射（逆光看光柱明显），趋近-1时向前散射
    float _HGFactor; 
    // 吸收系数，介质吸收光能而不产生散射的比例。散射系数 = 消光系数 * (1 - 吸收系数)
    float _Absorption;
    // 渲染分辨率范围，用于将屏幕UV映射到蓝噪声贴图的正确像素坐标上
    float4 _RenderExtent;
    // 蓝噪声贴图的纹素大小，xy为1/宽高，zw为宽高
    float4 _BlueNoiseTexture_TexelSize;

    // 打包的相机参数，这里自定义传入，xy分别代表垂直和水平FOV的正切值
    float4 _CameraPackedInfo;

    // 从_CameraPackedInfo中提取垂直FOV正切值，用于重建视线方向
    #define TAN_FOV_VERTICAL _CameraPackedInfo.x
    // 从_CameraPackedInfo中提取水平FOV正切值
    #define TAN_FOV_HORIZONTAL _CameraPackedInfo.y

    float _BrightIntensity;
    float _DarkIntensity;
    // 顶点着色器输入结构体
    struct Attributes
    {
        // 模型空间顶点坐标
        float4 positionOS   : POSITION;
        // Unity内置宏，用于处理SRP Batcher和Instancing的实例ID
        UNITY_VERTEX_INPUT_INSTANCE_ID
    };

    // 顶点着色器输出结构体（也是片元着色器输入结构体）
    struct Varyings
    {
        // 裁剪空间顶点坐标
        float4 positionCS   : SV_POSITION;
        // 世界空间顶点坐标
        float3 positionWS   : TEXCOORD0;
        // 屏幕UV，注意这里是float3，其中xy是UV，z是positionCS.w，用于在片元中做透视除法校正插值
        float3 screenUV     : TEXCOORD1;
        // Unity内置宏，传递实例ID到片元
        UNITY_VERTEX_INPUT_INSTANCE_ID
    };
    
    // 射线与平面求交函数。返回射线起点到交点的距离t，同时通过out参数返回射线方向在平面法线上的投影
    // 原理：将射线表示为 P = O + t*D，代入平面方程 Ax+By+Cz+D=0 求解t
    float intersectPlane(float4 plane, float3 origin, float3 dir, out float projection)
    {
        // 计算射线方向与平面法线的点积，即投影。若为0表示射线平行于平面
        projection = dot(dir, plane.xyz);
        // 根据平面方程推导出的t值公式：t = -(N·O + D) / (N·D)
        return -dot(float4(origin.xyz, 1), plane) / projection;
    }

    // 计算视线射线与Ray Marching包围盒的交点，并输出近处交点距离和远处交点距离
    // 返回值为光路总长度（即far - near），也称为光学几何深度
    float computeIntersect(float3 viewRay, out float nearIntersect, out float farIntersect)
    {
        // 初始化near为相机的近裁剪面距离，防止步进起点在相机内部导致穿模
        nearIntersect = _ProjectionParams.y; 
        // 初始化far为相机的远裁剪面距离
        farIntersect = _ProjectionParams.z; 

        // 遍历所有定义的包围盒裁剪平面
        for(int i = 0; i < _BoundaryPlanesCount; i++)
        {
            float projection;
            // 计算视线与当前平面的交点距离及投影方向
            float depth = intersectPlane(_BoundaryPlanes[i], _WorldSpaceCameraPos, viewRay, projection);
            // 如果投影小于0，说明射线从平面的正面（外侧）穿向背面（内侧），这是一个"进入"平面的动作
            // TODO: 优化判断（这里可以用step和lerp优化掉分支）
            if(projection < 0)
            {
                // 对于"进入"动作，我们要取所有进入点中最远的一个作为真正的_nearIntersect（取max）
                nearIntersect = max(nearIntersect, depth);
            }
            // 如果投影大于0，说明射线从平面的背面（内侧）穿向正面（外侧），这是一个"离开"平面的动作
            else if (projection > 0)
            {
                // 对于"离开"动作，我们要取所有离开点中最近的一个作为真正的_farIntersect（取min）
                farIntersect = min(farIntersect, depth);
            }
        }

        // 返回有效的光线步进区间长度
        return farIntersect - nearIntersect;
    }

    // 根据屏幕UV和深度缓冲值，计算从摄像机到实际场景物体表面的真实世界空间距离
    float computeDepthFromCameraToRealFragment(float2 screenUV, float depth)
    {
        // 将深度缓冲的非线性值转换为线性的视空间深度（即距离摄像机近平面的垂直距离）
        float linearDepth = LinearEyeDepth(depth, _ZBufferParams);
        // 根据相似三角形原理，利用FOV正切值和当前像素偏离屏幕中心的比例，计算出该片元在视空间中的X坐标偏移
        float realFragmentX = linearDepth * TAN_FOV_HORIZONTAL * abs(2 * screenUV.x - 1);
        // 同理计算出视空间中的Y坐标偏移
        float realFragmentY = linearDepth * TAN_FOV_VERTICAL * abs(2 * screenUV.y - 1);
        // 勾股定理：利用三维空间距离公式 sqrt(x^2 + y^2 + z^2) 求出摄像机到该像素的真实直线距离
        return sqrt(realFragmentX * realFragmentX + realFragmentY * realFragmentY + linearDepth * linearDepth);
        //TODO:更快的算法（注：可以提前算出视线方向向量，直接乘以linearDepth即可，避免sqrt）
        // float2 p = (screenUV * 2 - 1) * float2(TAN_FOV_HORIZONTAL, TAN_FOV_VERTICAL);
        // float3 ray = float3(p.xy, 1);
        // return linearDepth * length(ray);
    }

    // 计算介质中某一点的消光系数。消光系数 = 吸收系数 + 散射系数，代表光在介质中单位距离内能量损失的比率
    // pos：当前计算点的世界坐标，k：外部传入的风格化强度系数
    float extinctionAt(float3 pos, float k)
    {
        // 假设介质是绝对均匀分布的，所以消光系数是一个常数（基础浓度 * 风格化系数）
        // 原理：非均匀介质可以通过采样3D Noise或Density Volume来实现
        return k * _TransmittanceExtinction;
    }
    
    // 采样SpotLight的实时阴影
    // lightIndex：额外灯光索引，positionWS：需要计算阴影的世界坐标
    float SpotLightRealtimeShadow(int lightIndex, float3 positionWS)
    {
        // 从URP内部获取该索引光源的阴影采样数据（包括偏移、软阴影参数等）
        ShadowSamplingData shadowSamplingData = GetAdditionalLightShadowSamplingData(lightIndex);

        // 获取该光源的阴影参数（x:强度, y:偏移, z:法线偏移, w:阴影级联/切片索引）
        half4 shadowParams = GetAdditionalLightShadowParams(lightIndex);

        // 提取阴影切片索引，用于在阴影图集中查找正确的贴图区域
        int shadowSliceIndex = shadowParams.w;
        // 如果索引小于0，说明该光源没有开启阴影或不在阴影级联范围内
        if ( shadowSliceIndex < 0)
            return 1.0; // 返回1表示无阴影遮挡，完全照亮

        // 将世界坐标通过该光源的VP矩阵变换到光源的阴影贴图空间（齐次裁剪空间）
        float4 shadowCoord = mul(_AdditionalLightsWorldToShadow[shadowSliceIndex], float4(positionWS, 1.0));

        // 采样阴影贴图。sampler_LinearClampCompare会自动做PCF软阴影和深度比较
        return SampleShadowmap(TEXTURE2D_ARGS(_AdditionalLightsShadowmapTexture, sampler_LinearClampCompare), shadowCoord, shadowSamplingData, shadowParams, true);
    }

    // 封装阴影计算函数，返回1表示无阴影，趋近0表示完全在阴影中
    float shadowAt(float3 positionWS)
    {
        // 直接调用上面的函数，传入C#端绑定的光源索引
        return SpotLightRealtimeShadow(_ShadowLightIndex, positionWS);
    }

    // 计算介质中某一点接收到的直接光照能量（入射辐射度），以及该点到光源的方向
    // pos：介质中的点，lightDir：输出参数，返回从该点指向光源的单位向量
    float3 lightAt(float3 pos, out float3 lightDir)
    {
        // 计算光线方向。当_LightPosition.w为0(方向光)时，pos*0=0，lightDir就是归一化的光源方向；
        // 当w为1(聚光灯)时，减法计算出真实的指向光源的向量，然后归一化
        lightDir = normalize(_LightPosition.xyz - pos * _LightPosition.w);
        // 计算该点到光源的距离。方向光时直接使用设定好的超大距离，聚光灯时计算真实距离
        float lightDistance = lerp(_DirLightDistance, distance(_LightPosition.xyz, pos), _LightPosition.w);
        // 根据比尔-朗伯定律计算从光源到该点的透射率：T = e^(-密度 * 距离)
        // _IncomingLoss作为一个开关或乘数，决定是否考虑"光源到介质中"这段距离的雾气衰减
        float transmittance = lerp(1, exp(-lightDistance * extinctionAt(pos, _BrightIntensity)), _IncomingLoss);

        // 初始化光照颜色
        float3 lightColor = _LightColor.rgb;
        // 聚光灯锥形衰减判断：计算光线方向与聚光灯主轴的点积（即夹角余弦），
        // 如果大于设定的半角余弦值(step返回1)，说明在光锥内，保留能量；否则(返回0)丢弃能量
        lightColor *= step(_LightCosHalfAngle, dot(lightDir, _LightDirection.xyz));
        // 叠加实时阴影遮蔽，在阴影中的点接收不到直接光照
        lightColor *= shadowAt(pos);
        // 叠加透射率衰减，光穿过雾气到达该点时被消耗了一部分
        lightColor *= transmittance;
        // 计算散射系数。物理上散射=消光-吸收，这里简化为 消光系数 * (1 - 吸收比例)，代表这部分能量被散射到其他方向而不是被吃掉
        lightColor *= extinctionAt(pos, _BrightIntensity) * (1 - _Absorption);
        // 应用亮部的风格化强度调整
        lightColor *= _BrightIntensity;

        // 返回最终到达该点并被散射的能量
        return lightColor;
    }

    // 相位函数：描述光在介质中发生散射时，散射到特定方向上的概率分布。
    // 原理：体积积分必须为1，即所有方向的散射概率加起来等于1。
    // lightDir：入射光方向（指向光源），viewDir：观察方向（指向摄像机）
    float3 Phase(float3 lightDir, float3 viewDir)
    {
        // 采用Henyey-Greenstein公式，该公式通过参数g模拟不同大小的微粒散射。
        // 当g趋近1时，光强烈沿原方向传播（前向散射，如大气中的丁达尔效应/光柱）；
        // 当g趋近-1时，光反向散射（如毛发材质）；
        // dot(viewDir, lightDir)计算视线与光线方向的夹角余弦，决定了我们逆光看还是顺光看。
        return ( 1 - _HGFactor * _HGFactor) / ( 4 * PI * pow(1 + _HGFactor * _HGFactor- 2 * _HGFactor * dot(viewDir, lightDir) , 1.5));
    }

    // 核心的Ray Marching光线步进函数，计算沿视线方向累积的体积散射光
    // ray：归一化的视线方向，near/far：步进的起止距离，transmittance：输出参数，返回到达终点时剩下的能量比例
    float3 scattering(float3 ray, float near, float far, out float3 transmittance)
    {
        // 初始化透射率为1，代表摄像机处有100%的能量
        transmittance = 1;
        // 初始化累积的体积光总量为0
        float3 totalLight = 0;
        // 计算每次步进的步长（将总距离平均分成_Steps份）
        float stepSize = (far - near) / _Steps;
        // 提示编译器这是一个循环，防止编译器在步数较大时自动展开循环导致指令超限或编译极慢
        // [UNITY_LOOP]
        // 开始步进循环（从1开始，直到等于_Steps，避开near起点以防包含体积外部的误差）
        for(int i= 1; i <= _Steps; i++)
        {
            // 根据当前步数计算当前采样点的世界空间坐标：摄像机位置 + 方向 * (起点距离 + 步数 * 步长)
            float3 pos = _WorldSpaceCameraPos + ray * (near + stepSize * i);
            // 更新透射率：根据比尔-朗伯定律，光每走一个步长stepSize，能量就会衰减 e^(-消光系数 * 步长)。
            // 使用累乘是因为光是一层一层穿过雾气的，前面雾挡住的能量，后面的雾就接收不到了。
            // 注：这里用_DarkIntensity控制暗部衰减的浓淡，实现风格化分离
            transmittance *= exp(-stepSize * extinctionAt(pos, _DarkIntensity));
            
            // 声明一个临时变量用于接收lightAt函数计算出的指向光源的方向
            float3 lightDir;
            // 累积光照公式：当前透射率（光从远处走到这里还剩多少） * 当前点的入射光（光源照到这里多少） * 步长（微积分的dx近似） * 相位函数（有多少光散射到我们眼里）
            // -ray是因为ray是视线方向（指向屏幕内），而相位函数需要的是从介质指向摄像机的方向（指向屏幕外）
            totalLight += transmittance * lightAt(pos, lightDir) * stepSize * Phase(lightDir, -ray);
        }
        // 返回沿视线积分得到的总散射光颜色
        return totalLight;
    }

    // 体积光顶点着色器
    Varyings volumetricLightVert(Attributes input)
    {
        // 初始化输出结构体，将所有字段置零（防止垃圾数据）
        Varyings output = (Varyings)0;

        // 提取实例ID并设置环境
        UNITY_SETUP_INSTANCE_ID(input);
        // 将实例ID从顶点传递到片元
        UNITY_TRANSFER_INSTANCE_ID(input, output);
        // 初始化立体渲染（VR）相关的输出变量
        UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

        // 获取模型空间坐标
        float3 positionOS = input.positionOS.xyz;
        // 利用URP内置函数将模型空间坐标转换为各种空间坐标（此函数内部计算了OS->WS->VS->CS）
        VertexPositionInputs vertexInput = GetVertexPositionInputs(positionOS.xyz);
        // 输出裁剪空间坐标（用于GPU光栅化）
        output.positionCS = vertexInput.positionCS;
        // 输出世界空间坐标（用于在片元中计算视线方向）
        output.positionWS = vertexInput.positionWS;
        // 将裁剪空间的xyw存入screenUV（此时还不是真正的UV）
        output.screenUV = output.positionCS.xyw;
        // 处理不同平台（如DX与OpenGL）的UVY轴翻转问题
        #if UNITY_UV_STARTS_AT_TOP
        // 如果Y轴从顶部开始（如DX），xy除以w并进行翻转和偏移
        output.screenUV.xy = output.screenUV.xy * float2(0.5, -0.5) + 0.5 * output.screenUV.z;
        #else
        // 如果Y轴从底部开始（如OpenGL），正常除以w并偏移到0~1范围
        output.screenUV.xy = output.screenUV.xy * 0.5 + 0.5 * output.screenUV.z;
        #endif
        // 注意：上述除以w（即除以z）是在插值阶段由硬件自动完成的（透视校正插值），这样得到的UV才是完全准确的屏幕坐标

        // 返回处理好的数据给光栅化阶段
        return output;
    }

    // 体积光片元着色器，执行实际的Ray Marching计算
    float4 volumetricLightFrag(Varyings input) : SV_TARGET
    {
        // 设置实例化环境
        UNITY_SETUP_INSTANCE_ID(input);

        // 利用硬件透视校正插值后的结果，除以z（即原始的w）得到真正的0~1范围的屏幕UV
        float2 screen_uv = (input.screenUV.xy / input.screenUV.z);
        // 计算世界空间下的视线方向：用世界坐标减去摄像机位置并归一化
        float3 viewRay = normalize(input.positionWS - _WorldSpaceCameraPos);
        // 采样当前像素的深度缓冲值
        float cameraDepth = SAMPLE_TEXTURE2D(_CameraDepthTexture, sampler_CameraDepthTexture, screen_uv);

        // 声明变量接收Ray Marching的有效起止距离
        float nearIntersect, farIntersect, lightDepthIntersect;
        // 调用前面的函数，计算出视线与体积包围盒的交点，返回值为光路长度
        lightDepthIntersect = computeIntersect(viewRay, nearIntersect, farIntersect);

        // 性能优化：计算视线进入包围盒的近交点在屏幕上的深度值，判断是否被场景物体遮挡
        float3 nearIntersectWS = _WorldSpaceCameraPos + viewRay * nearIntersect;
        // 将近交点的世界坐标转换为齐次裁剪空间坐标
        float4 nearIntersectCS = TransformWorldToHClip(nearIntersectWS);
        // 执行透视除法，得到标准的NDC坐标（此时z范围为0~1或-1~1，对应深度缓冲）
        nearIntersectCS /= nearIntersectCS.w;
        // clip函数：如果参数小于0，则丢弃该像素不渲染。
        // 原理：如果体积包围盒的入口都被墙壁挡住了，那这个像素肯定没有体积光，直接跳过昂贵的Ray Marching计算
        clip(nearIntersectCS.z - cameraDepth);

        // 将远处的步进终点限制在场景真实物体表面上，防止光线穿透墙壁导致体积光画在墙壁后面
        farIntersect = min(farIntersect, computeDepthFromCameraToRealFragment(screen_uv, cameraDepth));
        
        // ---- Blue Noise 抖动抗锯齿/去条带算法 ----
        // 计算蓝噪声的采样UV：将屏幕坐标乘以渲染分辨率，再乘以蓝噪声的纹素大小(1/宽高)，得到[0,1]范围映射到蓝噪声像素的UV
        float2 jitterUV = screen_uv * _RenderExtent.xy * _BlueNoiseTexture_TexelSize.xy;
        // 采样蓝噪声贴图的Alpha通道（通常存储了[0,1]的随机值），Point采样保证像素级随机不模糊
        float offset = SAMPLE_TEXTURE2D(_BlueNoiseTexture, sampler_PointRepeat, jitterUV).a;
        // 将随机值按比例放大到一个步长的长度，作为偏移量
        offset *= (farIntersect - nearIntersect) / _Steps;
        // 原理：每次步进就像一把尺子在量雾，固定步长会导致出现明暗相间的"条带"。
        // 通过用随机噪声让这把尺子随机前后滑动不到一个步长的距离，多次帧叠加后条带就会消失，变成平滑的过渡。
        // 注意这里是-=offset，即让近处和远处同时减去偏移，整体平移采样网格。
        nearIntersect -= offset;
        farIntersect -= offset;

        // 声明透射率变量用于接收scattering函数的输出
        float3 transmittance = 1;
        // 初始化最终颜色为黑色
        float3 color = 0;
        // 调用核心Ray Marching函数，计算沿视线累积的散射光颜色
        color = scattering(viewRay, nearIntersect, farIntersect, transmittance);
        
        // 返回颜色，Alpha设为1（因为下面使用了Blend One One加法混合，Alpha不起作用，仅RGB相加）
        return float4(color, 1);
    }
    // 结束HLSL包含块
    ENDHLSL
    
    // 子着色器区块
    SubShader
    {
        // 这行代码试图直接复用URP内置的Blit Pass。但这在自定义了顶点/片元的情况下通常无效或是冗余的，可能是作者从模板遗留的代码。
        UsePass "Hidden/Universal Render Pipeline/Blit/Blit"
        
        // 定义一个渲染Pass
        Pass 
        {
            // Pass名称，标记为聚光灯体积光，可在FrameDebug中辨认
            Name "Volumetric Light Spot" // 1
            // 关闭深度测试：因为这是后处理全屏效果，不需要与场景深度比较
            ZTest Off
            // 关闭深度写入：后处理不写入深度缓冲，避免污染后续依赖深度的Pass
            ZWrite Off
            // 关闭背面剔除：通常绘制全屏Quad时关闭，以防Quad因相机旋转而背对摄像机被丢弃
            Cull Off
            // 设置混合模式为 加法混合。
            // 原理：体积光是增加光照能量，使用 One One (最终颜色 = 源颜色 * 1 + 目标颜色 * 1) 可以让光叠加在原画面上越亮越白，符合物理直觉。
            Blend One One
            
            // HLSL程序块标记
            HLSLPROGRAM

            // 指定该Pass使用的顶点着色器函数
            #pragma vertex volumetricLightVert
            // 指定该Pass使用的片元着色器函数
            #pragma fragment volumetricLightFrag
            
            // 结束HLSL程序块
            ENDHLSL
        }
    }
// 结束Shader
}
