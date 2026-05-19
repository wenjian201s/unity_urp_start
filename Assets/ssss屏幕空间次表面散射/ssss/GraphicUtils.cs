using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering; // 引入Unity渲染命名空间，使用CommandBuffer、RenderTargetIdentifier等渲染管线API

// 静态工具类：封装后处理核心的Blit（位块传输）方法，用于CommandBuffer绘制全屏四边形
// 核心作用：为SSS后处理提供高效的渲染目标切换、材质绘制能力，是连接C#渲染逻辑和Shader的桥梁
//（如全屏四边形创建、CommandBuffer 的 Blit 封装、多 / 单渲染目标处理）以及与 SSS 后处理的联动逻辑
public static class GraphicUtils {
    // 私有静态属性：懒加载创建全屏（此处为半屏）四边形Mesh（后处理绘制的基础）
    // 懒加载：第一次访问时才创建，避免初始化开销，且只创建一次
    private static Mesh mesh {
        get {
            // 如果Mesh已创建，直接返回
            if (m_mesh != null)
                return m_mesh;
            m_mesh = new Mesh(); // 初始化Mesh（后处理用的四边形，用于绘制全屏/半屏纹理）
            // 设置顶点：4个顶点定义一个四边形（注：此处顶点范围是[-1,-1]到[0,1]，实际是半屏四边形，可根据需求调整为全屏[-1,-1]到[1,1]）
            // 顶点坐标采用NDC（归一化设备坐标），无需MVP矩阵变换，直接映射到屏幕
            m_mesh.vertices = new Vector3[] {
                              new Vector3(-1,-1,0),// 左下顶点
                              new Vector3(-1,1,0),// 左上顶点
                              new Vector3(0,1,0), // 右上顶点
                              new Vector3(0,-1,0) // 右下顶点
            };
            // 设置UV坐标：对应顶点的纹理坐标，范围[0,0.5]×[0,1]（匹配半屏顶点）
            // UV用于采样Shader中的_MainTex（场景纹理/中间纹理）
            m_mesh.uv = new Vector2[] {
                        new Vector2(0,1), // 左下顶点UV
                        new Vector2(0,0),// 左上顶点UV
                        new Vector2(0.5f,0),// 右上顶点UV
                        new Vector2(0.5f,1)// 右下顶点UV
            };
            // 设置三角面索引：以四边形拓扑绘制4个顶点（0-1-2-3），避免拆分为两个三角形
            // MeshTopology.Quads：四边形拓扑，渲染效率高于Triangles
            m_mesh.SetIndices(new int[] { 0, 1, 2, 3 }, MeshTopology.Quads, 0);
            return m_mesh;
        }
    }
    // 私有静态字段：存储后处理用的四边形Mesh实例（懒加载的底层存储）
    private static Mesh m_mesh;
    // ===== 扩展方法1：Blit到多渲染目标（MRT），带深度纹理 =====
    // 用途：一次绘制输出到多个颜色渲染目标，同时绑定深度纹理（复杂后处理场景，SSS一般用不到，但预留扩展）
    // 参数：
    // - buffer：CommandBuffer（渲染命令缓冲区，用于批量提交渲染指令）
    // - colorIdentifier：多颜色渲染目标标识符数组（输出到多个RenderTexture）
    // - depthIdentifier：深度渲染目标标识符（绑定深度纹理）
    // - mat：绘制用的材质（绑定SSS Shader）
    // - pass：材质要执行的Shader Pass索引（如0=XBlur，1=YBlur）
    public static void BlitMRT(this CommandBuffer buffer, RenderTargetIdentifier[] colorIdentifier, RenderTargetIdentifier depthIdentifier, Material mat, int pass) {
        buffer.SetRenderTarget(colorIdentifier, depthIdentifier);// 设置渲染目标：绑定多个颜色目标和深度目标，后续绘制会输出到这些目标
        // 绘制四边形Mesh：
        // - mesh：后处理四边形
        // - Matrix4x4.identity：单位矩阵（NDC坐标无需变换）
        // - mat：绑定的SSS材质（包含X/Y模糊Pass）
        // - 0：Mesh的子网格索引（此处只有一个子网格）
        // - pass：要执行的Shader Pass（如0执行XBlur，1执行YBlur）
        buffer.DrawMesh(mesh, Matrix4x4.identity, mat, 0, pass);
    }
// ===== 扩展方法2：Blit到单渲染目标（SRT），无深度纹理 =====
    // 用途：绘制到单个颜色渲染目标（SSS后处理的核心方法，如XBlur输出到临时纹理）
    // 参数：
    // - destination：单个输出渲染目标标识符
    // - 其他参数同BlitMRT
    public static void BlitSRT(this CommandBuffer buffer, RenderTargetIdentifier destination, Material mat, int pass) {
        buffer.SetRenderTarget(destination);// 设置渲染目标为单个颜色目标
        buffer.DrawMesh(mesh, Matrix4x4.identity, mat, 0, pass); // 绘制四边形，执行指定Pass的Shader逻辑
    }
    // ===== 扩展方法3：Blit到多渲染目标，带源纹理和深度纹理 =====
    // 用途：指定源纹理后，绘制到多颜色目标+深度目标（参数冗余，实际未使用source，仅预留）
    // 注：该方法未实际使用source，如需传递源纹理需添加buffer.SetGlobalTexture(ShaderIDs._MainTex, source)
    public static void BlitMRT(this CommandBuffer buffer, Texture source, RenderTargetIdentifier[] colorIdentifier, RenderTargetIdentifier depthIdentifier, Material mat, int pass) {
        buffer.SetRenderTarget(colorIdentifier, depthIdentifier);
        buffer.DrawMesh(mesh, Matrix4x4.identity, mat, 0, pass);
    }
    // ===== 扩展方法4：Blit到单渲染目标，带源纹理（SSS核心方法） =====
    // 用途：将source作为_MainTex传递给Shader，绘制到destination（如将场景纹理传入SSS XBlur Pass，输出到临时纹理）
    // 参数：
    // - source：源纹理（如相机渲染的场景纹理、XBlur后的临时纹理）
    // - destination：输出渲染目标（如临时纹理、屏幕）
    public static void BlitSRT(this CommandBuffer buffer, Texture source, RenderTargetIdentifier destination, Material mat, int pass) {
        buffer.SetGlobalTexture(ShaderIDs._MainTex, source);
        buffer.SetRenderTarget(destination);
        buffer.DrawMesh(mesh, Matrix4x4.identity, mat, 0, pass);
    }
    // ===== 扩展方法5：Blit到单渲染目标，源为RenderTargetIdentifier（SSS核心重载） =====
    // 用途：适配源为RenderTargetIdentifier的场景（如临时RenderTexture的标识符），逻辑同扩展方法4
    public static void BlitSRT(this CommandBuffer buffer, RenderTargetIdentifier source, RenderTargetIdentifier destination, Material mat, int pass) {
        // 将源纹理绑定到Shader的_MainTex属性（通过预定义的ShaderIDs，性能最优）
        // SSS Shader会采样_MainTex进行X/Y方向模糊
        buffer.SetGlobalTexture(ShaderIDs._MainTex, source);
        buffer.SetRenderTarget(destination); // 设置输出渲染目标
        buffer.DrawMesh(mesh, Matrix4x4.identity, mat, 0, pass);// 绘制四边形，执行SSS的指定Pass
    }
    // ===== 扩展方法6：带模板测试的Blit（SSS核心方法） =====
    // 用途：绘制时绑定深度/模板纹理，支持SSS的模板测试（只渲染皮肤区域）
    // 参数：
    // - colorSrc：源颜色纹理（如场景纹理）
    // - colorBuffer：输出颜色目标
    // - depthStencilBuffer：深度/模板纹理（存储皮肤的模板值5，用于SSS的模板测试）
    public static void BlitStencil(this CommandBuffer buffer, RenderTargetIdentifier colorSrc, RenderTargetIdentifier colorBuffer, RenderTargetIdentifier depthStencilBuffer, Material mat, int pass) {
        buffer.SetGlobalTexture(ShaderIDs._MainTex, colorSrc);// 绑定源纹理到_MainTex
        buffer.SetRenderTarget(colorBuffer, depthStencilBuffer);// 设置渲染目标：同时绑定颜色目标和深度/模板目标（关键！保证Shader能访问模板缓冲区）
        buffer.DrawMesh(mesh, Matrix4x4.identity, mat, 0, pass); // 绘制四边形，执行带模板测试的SSS Pass
    }
    // ===== 扩展方法7：带模板测试的Blit（无源源纹理重载） =====
    // 用途：无需指定源纹理时使用（如直接绘制材质内置纹理）
    public static void BlitStencil(this CommandBuffer buffer, RenderTargetIdentifier colorBuffer, RenderTargetIdentifier depthStencilBuffer, Material mat, int pass) {
        buffer.SetRenderTarget(colorBuffer, depthStencilBuffer);
        buffer.DrawMesh(mesh, Matrix4x4.identity, mat, 0, pass);
    }
}