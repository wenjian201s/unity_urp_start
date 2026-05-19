using System.Collections;
using System.Collections.Generic;
using UnityEngine;

public static class KernelCalculate { //计算可分离次表面散射（Separable SSS）的卷积核
    //注意：这个算法基于Jorge Jimenez的SSS方法，使用了一个预积分的核函数，该核函数由多个高斯函数的线性组合来模拟次表面散射的剖面（profile）。
    //代码分为两个主要部分：CalculateKernel公共方法和两个私有方法gaussian和profile。
    
    // 核心方法：计算SSS采样核
    // 参数：
    // - kernel：输出的采样核列表（Vector4格式：x=R通道权重, y=G通道权重, z=B通道权重, w=UV偏移量）
    // - nSamples：采样步数（核的长度，对应Shader中的SamplerSteps）
    // - strength：RGB三个通道的散射强度（控制各颜色的散射程度，如红光散射更强）
    // - falloff：RGB三个通道的散射衰减（控制各颜色的散射距离）
    public static void CalculateKernel(List<Vector4> kernel, int nSamples, Vector3 strength, Vector3 falloff, float range = 2.0f) {
        // 1. 定义核的采样范围：2.0更适合半分辨率/移动端精度，3.0更接近Jimenez原始宽范围。
        float RANGE = Mathf.Clamp(range, 1.0f, 3.0f);
        // 幂次系数：用于调整偏移量的非线性分布（模拟SSS的自然衰减）
        float EXPONENT = 2.0f;
        // 清空原有核数据，避免残留
        kernel.Clear();
        // 2. 第一步：计算SSS的UV偏移量（_Kernel[i].a）
        // 计算采样步长：将[-RANGE, RANGE]区间均分nSamples份
        // Calculate the SSS_Offset_UV:
        float step = 2.0f * RANGE / (nSamples - 1);
        for (int i = 0; i < nSamples; i++) {
            // 计算当前采样点的基础偏移值（从-RANGE到RANGE线性分布）
            float o = -RANGE + i * step;
            // 偏移值的符号（正/负，控制UV偏移方向）
            float sign = o < 0.0f ? -1.0f : 1.0f;
            // 计算非线性偏移权重：将线性偏移转换为幂次分布，模拟SSS的自然散射规律
            // 公式含义：偏移量的绝对值取EXPONENT次幂，再归一化到RANGE范围内，保留符号
            float w = RANGE * sign * Mathf.Abs(Mathf.Pow(o, EXPONENT)) / Mathf.Pow(RANGE, EXPONENT);
            // 先将核元素的RGB权重设为0，仅存储UV偏移量w到w分量（Vector4的第四个分量）
            kernel.Add(new Vector4(0, 0, 0, w));
        }
        // 3. 第二步：计算SSS的RGB通道权重（_Kernel[i].rgb）
        // Calculate the SSS_Scale:
        for (int i = 0; i < nSamples; i++) {
            // 计算当前采样点与前一个点的偏移差（用于梯形面积法）
            float w0 = i > 0 ? Mathf.Abs(kernel[i].w - kernel[i - 1].w) : 0.0f;
            // 计算当前采样点与后一个点的偏移差
            float w1 = i < nSamples - 1 ? Mathf.Abs(kernel[i].w - kernel[i + 1].w) : 0.0f;
            // 梯形面积法：近似计算当前采样点的权重面积（离散采样的积分近似）
            float area = (w0 + w1) / 2.0f;
            // 根据当前偏移量w，计算RGB通道的高斯分布权重（调用profile方法，多高斯叠加）
            Vector3 temp = profile(kernel[i].w, falloff);
            // 将面积与高斯权重相乘，得到最终的RGB权重，保留原UV偏移量w
            Vector4 tt = new Vector4(area * temp.x, area * temp.y, area * temp.z, kernel[i].w);
            // 更新核元素：此时x=R权重, y=G权重, z=B权重, w=UV偏移
            kernel[i] = tt;
        }
        // 4. 第三步：调整核的中心位置（将中间采样点移到核的第一个位置）
        // 原因：SSS核的中心对应原始像素，需要优先计算，符合Shader中_Kernel[0]为中心权重的逻辑
        Vector4 t = kernel[nSamples / 2];  // 取中间位置的核元素
        for (int i = nSamples / 2; i > 0; i--)
            kernel[i] = kernel[i - 1];// 从中间位置向前移位，腾出第一个位置
        kernel[0] = t;// 将中间元素放到第一个位置
        Vector4 sum = Vector4.zero;
        
        // 5. 第四步：核的归一化（保证RGB通道的权重和为1，避免颜色过亮/过暗）
        // 先计算RGB通道的总权重
        for (int i = 0; i < nSamples; i++) {
            sum.x += kernel[i].x;// R通道总权重
            sum.y += kernel[i].y;// G通道总权重
            sum.z += kernel[i].z;// B通道总权重
        }
        // 每个采样点的权重除以总权重，归一化到[0,1]范围
        for (int i = 0; i < nSamples; i++) {
            Vector4 vecx = kernel[i];
            vecx.x /= sum.x;
            vecx.y /= sum.y;
            vecx.z /= sum.z;
            kernel[i] = vecx;
        }
        
        // 6. 第五步：根据strength调整核的权重（控制各通道的散射强度）
        // 调整中心采样点（第一个元素）的权重：保留部分原始颜色，避免过度模糊
        Vector4 vec = kernel[0];
        // 公式含义：(1-strength)保留原始颜色，strength乘以核权重，平衡原始色与散射色
        vec.x = (1.0f - strength.x) * 1.0f + strength.x * vec.x;
        vec.y = (1.0f - strength.y) * 1.0f + strength.y * vec.y;
        vec.z = (1.0f - strength.z) * 1.0f + strength.z * vec.z;
        kernel[0] = vec;
        // 调整非中心采样点的权重：直接乘以strength，控制散射强度
        for (int i = 1; i < nSamples; i++) {
            var vect = kernel[i];
            vect.x *= strength.x;
            vect.y *= strength.y;
            vect.z *= strength.z;
            kernel[i] = vect;
        }
    }

    // 私有辅助方法：单高斯分布函数（模拟单次散射的权重分布）
    // 参数：
    // - variance：方差（控制高斯曲线的宽窄，值越大散射越广）
    // - r：当前偏移量（采样点到中心的距离）
    // - falloff：RGB通道的衰减系数（控制各通道的散射距离）
    private static Vector3 gaussian(float variance, float r, Vector3 falloff) {
        Vector3 g = Vector3.zero;// 存储RGB通道的高斯权重


        for (var i = 0; i < 3; ++i) { // 为每个颜色通道计算高斯权重
            // 归一化偏移量：除以falloff[i]，控制该通道的散射距离（falloff越小，散射越远）
            // 加0.001f避免除以0
            float rr = r / (0.001f + falloff[i]);
            // 高斯分布公式：G(r) = e^(-r²/(2σ²)) / (2πσ²)，σ²为方差variance
            g[i] = Mathf.Exp((-(rr * rr)) / (2.0f * variance)) / (2.0f * 3.14f * variance);
        }
      
        return g;
    }
    // 私有辅助方法：多高斯分布叠加（次表面散射的经典模型，模拟多次散射的综合效果）
    // 原理：将5个不同方差的高斯分布加权叠加，更贴近真实材质（如皮肤）的SSS特性
    // 参数：
    // - r：当前偏移量
    // - falloff：RGB通道的衰减系数
    private static Vector3 profile(float r, Vector3 falloff) {
        // 5个高斯分布的加权和，系数和方差是行业内模拟皮肤SSS的经典参数
        return 0.100f * gaussian(0.0484f, r, falloff) +// 近距离散射（小方差）
                0.118f * gaussian(0.187f, r, falloff) + // 中近距离散射
                0.113f * gaussian(0.567f, r, falloff) + // 中距离散射
                0.358f * gaussian(1.99f, r, falloff) + // 中远距离散射（权重最大）
                0.078f * gaussian(7.41f, r, falloff);// 远距离散射（大方差）
    }
}
