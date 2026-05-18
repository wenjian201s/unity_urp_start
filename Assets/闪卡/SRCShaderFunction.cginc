#ifndef SRC_SHADER_FUNCTIONS_INCLUDED
#define SRC_SHADER_FUNCTIONS_INCLUDED

//视差 
half4 ParallaxTex(sampler2D HeightMap, sampler2D MainTex, half2 uv, half3 vDirTS,  half ParallaxStrength)
{
    half h = 1 - tex2D(HeightMap, uv).r;//反转高度
    half2 offset = -vDirTS.xy * (h/vDirTS.z) * ParallaxStrength;
    half4 col = tex2D(MainTex, uv + offset);
    return col;
}

//各向异性高光
half Anisotropy(half3 tDir, half3 hDir,half AnisotropyPow)
{
    half tdoth = dot(tDir, hDir);
    //当tdoth小于等于-1，也就是h与t方向完全相反时，dirAtten为0；当大于等于0时，为1。
    //限制t与h夹角，必须小于180°，否则可以认为光源无法照到/相机无法观察到 当前像素。
    half dirAtten = smoothstep(-1, 0, tdoth);
    half sinth = sqrt(1 - tdoth *  tdoth);
    half AnisoSpec = dirAtten * pow(sinth, AnisotropyPow);
    return AnisoSpec;
}

//色相偏移
half3 HueOffset(half3 In, half Offset)
{
    half4 K = half4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    half4 P = lerp(half4(In.bg, K.wz), half4(In.gb, K.xy), step(In.b, In.g));
    half4 Q = lerp(half4(P.xyw, In.r), half4(In.r, P.yzx), step(P.x, In.r));
    half D = Q.x - min(Q.w, Q.y);
    half E = 1e-10;
    half3 hsv = half3(abs(Q.z + (Q.w - Q.y)/(6.0 * D + E)), D / (Q.x + E), Q.x);
    // 色相偏移（直接使用标准化值）
    half hue = hsv.x + Offset;
    hsv.x = (hue < 0) ? hue + 1 : (hue > 1) ? hue - 1 : hue;
    // HSV to RGB 转换（同上）
    half4 K2 = half4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    half3 P2 = abs(frac(hsv.xxx + K2.xyz) * 6.0 - K2.www);
    half3 color = hsv.z * lerp(K2.xxx, saturate(P2 - K2.xxx), hsv.y);
    return color;
}

//条纹闪烁
half2 StripeGlitter(half vDirTS, half GlitterCount, half GlitterSpeed, half GlitterArea, half GlitterStart)
{
    //影响之后三角函数的周期，_GridGlitterCount越大，周期越短，波峰之间距离越接近，闪烁次数越多
    //同时根据输入的切线空间观察方向的分量，当物体自身旋转或视角移动时，相当于改变了函数的t，波峰和波谷的位置也发生变化，形成亮暗的变化，达成闪烁效果
    half2 angleCycle = vDirTS * GlitterCount * UNITY_PI * 2;
    //_GlitterSpeed控制闪烁速度
    half glitterWave = sin(angleCycle * GlitterSpeed + GlitterStart * 3.14);
    //_GridGlitterArea越大，波峰区域越宽，格子发亮的面积就越大
    half glitter = smoothstep(1.0 - GlitterArea, 1.0, glitterWave);
    return glitter;
}

//格子闪烁
half2 GridGlitter(half2 uv, half vDirTS, half GridSize, half GridGlitterCount, half GridGlitterSpeed, half GridGlitterArea)
{
    // 创建格子UV
    half2 gridUV = uv * GridSize;
    half2 gridId = floor(gridUV);//记录每个格子的位置
    //通过frac(sin(dot(x, y)) * 大数)，为每个格子生成伪随机相位
    half randomPhase = frac(sin(dot(gridId, half2(12.9898, 78.233))) * 43758.5453);
    //影响之后三角函数的周期，_GridGlitterCount越大，周期越短，波峰之间距离越接近，闪烁次数越多
    //同时根据输入的切线空间观察方向的分量，当物体自身旋转或视角移动时，相当于改变了函数的t，波峰和波谷的位置也发生变化，形成亮暗的变化，达成闪烁效果
    half2 angleCycle = vDirTS * GridGlitterCount * UNITY_PI * 2;
    //_GridGlitterSpeed控制闪烁速度，后边是每个格子随机偏移的相位（随机相位 * 6.28之后映射到0-2pi的范围。只是0-1最多偏移57°，影响小）
    half glitterWave = sin(angleCycle * GridGlitterSpeed + randomPhase * 6.28);
    //_GridGlitterArea越大，波峰区域越宽，格子发亮的面积就越大
    half glitter = smoothstep(1 - GridGlitterArea, 1.0, glitterWave);
                
    return glitter;
}
#endif