// ---------------------------【故障艺术（真实电脑故障）特效】---------------------------

Shader "lcl/screenEffect/GlitchArt"
{
    // ---------------------------【属性】---------------------------
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
        _GlitchTex ("Glitch Texture", 2D) = "white" {} // 用于数据注入的故障纹理
    }

    CGINCLUDE
    #include "UnityCG.cginc"

    sampler2D _MainTex;
    sampler2D _GlitchTex; // 新增：故障纹理（用于数据注入）
    float2 _MainTex_TexelSize;

    float2 _ScanLineJitter; // (displacement, threshold)
    float2 _VerticalJump;   // (amount, time)
    float _HorizontalShake;
    float2 _ColorDrift;     // (amount, time)
    
    // 像素块错位参数
    float _PixelBlockSize;  // 像素块大小 (1.0 = 单像素, 8.0 = 8x8像素块)
    float _PixelBlockJitter; // 像素块错位强度
    float _PixelBlockTime;   // 像素块错位时间变化
    
    // 新增：水平条纹干扰参数
    float _HorizontalBanding; // 水平条纹强度
    float _BandingFrequency;  // 条纹密度
    float _BandingTime;       // 条纹时间变化
    
    // 新增：数据注入参数
    float _DataInjection;     // 数据注入强度
    float _DataThreshold;     // 数据注入阈值
    float _DataTime;          // 数据注入时间
    
    // 新增：信号丢失参数
    float _SignalLoss;        // 信号丢失强度
    float _LossThreshold;     // 丢失阈值
    float _LossTime;          // 丢失时间
    
    // 新增：效果强度控制
    float _OverallIntensity;  // 整体效果强度

    // 优化的随机函数
    float nrand(float x, float y)
    {
        return frac(sin(dot(float2(x, y) + float2(_Time.y, _Time.w) * 0.1, float2(12.9898, 78.233))) * 43758.5453);
    }
    
    // 高质量随机函数（用于时间突变）
    float hrand(float2 uv)
    {
        return frac(sin(dot(uv, float2(127.1, 311.7))) * 43758.5453123);
    }
    
    // 模拟数据块（代码/字符）
    half4 generateDataBlock(float2 uv, float time)
    {
        // 创建模拟代码/字符的图案
        float charIndex = floor(uv.x * 30.0) + floor(uv.y * 20.0);
        float charValue = sin(charIndex * 0.1 + time * 10.0) * 0.5 + 0.5;
        
        // 生成类似代码的字符图案
        float pattern = sin(uv.x * 100.0 + time) * sin(uv.y * 50.0 + time * 0.5);
        pattern = step(0.7, abs(pattern)); // 创建二进制效果
        
        // 随机颜色（模拟终端显示）
        float3 terminalColors[4] = {
            float3(0.0, 1.0, 0.0), // 绿色（经典终端）
            float3(0.0, 0.7, 0.0), // 深绿
            float3(0.7, 0.0, 0.0), // 红色
            float3(0.0, 0.0, 1.0)  // 蓝色
        };
        
        int colorIndex = (int)(charValue * 3.99);
        float3 color = terminalColors[colorIndex];
        
        return half4(color * pattern, 1.0);
    }

    half4 frag(v2f_img i) : SV_Target
    {
        float u = i.uv.x;
        float v = i.uv.y;
        float intensity = _OverallIntensity; // 应用整体强度
        
        // ===== 1. 水平条纹干扰（关键效果）=====
        float bandSize = max(1.0, _BandingFrequency * 20.0); // 控制条纹密度
        float bandIndex = floor(v * bandSize);
        
        // 突变效果：使用时间突变函数
        float bandTime = floor(_BandingTime * 5.0) * 0.2;
        float bandRand = nrand(bandIndex * 10.0, bandTime);
        
        // 仅当随机值超过阈值时应用条纹
        float bandThreshold = 0.6;
        float bandOffset = 0.0;
        float bandVisibility = 1.0;
        
        if (bandRand > bandThreshold) 
        {
            // 随机偏移强度（突变式）
            bandOffset = (step(0.5, bandRand) * 2.0 - 1.0) * _HorizontalBanding * intensity * 0.05;
            
            // 模拟信号丢失：部分条纹完全消失
            if (bandRand > 0.9) 
            {
                bandVisibility = 0.0; // 完全不可见
            }
            else if (bandRand > 0.8) 
            {
                bandVisibility = 0.3; // 部分可见
            }
        }
        
        // 应用条纹偏移
        u += bandOffset;
        
        // ===== 2. 像素块错位效果 =====
        float blockScale = max(1.0, _PixelBlockSize);
        float2 blockUV = floor(i.uv * blockScale) / blockScale;
        float blockRand = nrand(blockUV.x * 10.0 + _PixelBlockTime, blockUV.y * 10.0 + _PixelBlockTime * 0.7);
        
        // 仅当随机值超过阈值时应用错位
        float blockThreshold = 0.7;
        float2 blockOffset = float2(0, 0);
        
        if (blockRand > blockThreshold) 
        {
            // 生成随机方向的偏移（突变式）
            float2 randDir = float2(
                sin(blockRand * 123.45 + _PixelBlockTime * 10.0),
                cos(blockRand * 678.90 + _PixelBlockTime * 5.0)
            );
            randDir = normalize(randDir);
            
            // 应用偏移 (强度由_PixelBlockJitter控制)
            blockOffset = randDir * _PixelBlockJitter * intensity * _MainTex_TexelSize.xy * blockScale;
        }
        
        // 将块偏移应用到UV
        float2 uvWithBlockOffset = float2(u, v) + blockOffset;
        
        // ===== 3. 信号丢失效果（关键效果）=====
        float lossRand = nrand(floor(u * 50.0) * 10.0 + _LossTime * 5.0, floor(v * 50.0) * 10.0 + _LossTime * 3.0);
        float lossEffect = 0.0;
        
        if (lossRand < _LossThreshold * intensity) 
        {
            // 完全丢失：黑色
            if (lossRand < _LossThreshold * intensity * 0.4) 
            {
                lossEffect = 1.0; // 完全黑色
            }
            // 部分丢失：雪花噪点
            else 
            {
                lossEffect = 0.7 * nrand(u * 1000.0 + _LossTime, v * 1000.0 + _LossTime * 0.7);
            }
        }
        
        // ===== 4. 数据注入效果（关键效果）=====
        float dataRand = nrand(floor(u * 30.0) * 5.0 + _DataTime, floor(v * 30.0) * 5.0 + _DataTime * 0.5);
        half4 dataColor = half4(0,0,0,0);
        float dataAlpha = 0.0;
        
        if (dataRand < _DataThreshold * intensity) 
        {
            // 决定使用哪种数据注入
            float dataType = nrand(dataRand * 10.0, _DataTime);
            
            // 50% 概率使用故障纹理，50% 概率使用生成数据
            if (dataType < 0.5) 
            {
                // 从故障纹理采样（可用于自定义错误消息、代码等）
                float2 glitchUV = frac(float2(u * 2.0 + _DataTime * 0.1, v * 2.0 + _DataTime * 0.05));
                dataColor = tex2D(_GlitchTex, glitchUV);
            }
            else 
            {
                // 生成模拟代码/字符的数据块
                dataColor = generateDataBlock(i.uv, _DataTime);
            }
            
            // 随机透明度（模拟部分覆盖）
            dataAlpha = 0.4 + 0.6 * nrand(dataRand * 100.0, _DataTime * 10.0);
            dataAlpha *= _DataInjection * intensity;
        }
        
        // ===== 5. 原有故障效果 (使用处理后的UV) =====
        float jitter = nrand(v * 15.0, _Time.x * 3.0) * 2.0 - 1.0;
        jitter *= step(_ScanLineJitter.y, abs(jitter)) * _ScanLineJitter.x * intensity;

        float jump = lerp(v, frac(v + _VerticalJump.y), _VerticalJump.x * intensity);
        float shake = (nrand(_Time.x * 2.0, 2) - 0.5) * _HorizontalShake * intensity;
        float drift = sin(jump * 10.0 + _ColorDrift.y) * _ColorDrift.x * intensity;

        // 使用处理后的UV进行采样
        float2 finalUV = frac(float2(uvWithBlockOffset.x + jitter + shake, jump));
        half4 src1 = tex2D(_MainTex, finalUV);
        half4 src2 = tex2D(_MainTex, frac(float2(finalUV.x + drift, finalUV.y)));

        // ===== 6. 混合所有效果 =====
        half4 color = half4(src1.r, src2.g, src1.b, 1);
        
        // 应用信号丢失
        if (lossEffect > 0.01) 
        {
            color.rgb = lerp(color.rgb, half3(0,0,0), lossEffect);
        }
        
        // 应用数据注入
        if (dataAlpha > 0.01) 
        {
            color = lerp(color, dataColor, dataAlpha);
        }
        
        // 应用条纹可见性
        color.rgb *= bandVisibility;
        
        // ===== 7. 扫描线效果（增强真实感）=====
        float scanline = sin(v * _ScreenParams.y * 2.0) * 0.05 + 0.95;
        color.rgb *= scanline;
        
        // ===== 8. 色彩失真（模拟老式显示器）=====
        if (nrand(floor(u * 20.0), floor(v * 20.0)) < 0.05 * intensity) 
        {
            // 随机色彩偏移
            color.rg = color.gr; // 交换R和G通道
        }
        
        return color;
    }
    
    ENDCG

    // ---------------------------【子着色器】---------------------------
    SubShader
    {
        // ---------------------------【渲染通道】---------------------------
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag
            #pragma target 3.0
            ENDCG
        }
    }
    
    // ---------------------------【回退方案】---------------------------
    Fallback off
}