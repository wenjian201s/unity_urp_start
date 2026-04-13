// 引入系统集合命名空间（本脚本未深用，属于默认模板遗留）
using System.Collections;
// 引入系统泛型集合命名空间（本脚本未深用，属于默认模板遗留）
using System.Collections.Generic;
// 引入Unity核心命名空间，提供MonoBehaviour、Vector3等基础功能
using UnityEngine;
// 引入Unity渲染命名空间，提供CommandBuffer、RenderTargetIdentifier等底层的图形API接口
using UnityEngine.Rendering;


// 定义一个命名空间，用于隔离代码，防止与其他插件或项目代码重名
namespace RecaNoMaho
{
    // 声明一个静态公共类。静态类不能被实例化，适合作为全局工具类使用
    public static class CommonUtil
    {
        // 定义一个私有静态内部类，专门用于缓存Shader属性的ID
        static class ShaderConstants
        {
            // 获取"_BlitTexture"属性的ID并缓存为只读变量。
            // 原理：在渲染循环中直接使用字符串传参会产生垃圾回收(GC)消耗，通过PropertyToID转为int可以极大提升性能
            public static readonly int _BlitTexture = Shader.PropertyToID("_BlitTexture");
            // 获取"_BlitScaleBias"属性的ID并缓存。该变量用于控制全屏贴图的缩放和偏移
            public static readonly int _BlitScaleBias = Shader.PropertyToID("_BlitScaleBias");
        }
        
        // 私有静态变量，用于缓存找到的Shader对象
        private static Shader commonUtilShader;

        // 公有静态属性，用于获取上面的Shader对象（实现了懒加载单例模式）
        private static Shader CommonUtilShader
        {
            get
            {
                // 如果Shader对象为空（尚未加载或被销毁）
                if (commonUtilShader == null)
                {
                    // 通过Shader的路径去全局查找对应的Shader资源（路径必须与之前提供的Shader文件第一行完全一致）
                    commonUtilShader = Shader.Find("Hidden/RecaNoMaho/CommonUtil");
                }

                // 返回缓存好的Shader对象
                return commonUtilShader;
            }
        }

        // 私有静态变量，用于缓存由Shader生成的材质球
        private static Material commonUtilMat;

        // 公有静态属性，用于获取上面的材质球（实现了懒加载单例模式）
        private static Material CommonUtilMat
        {
            get
            {
                // 如果材质球为空
                if (commonUtilMat == null)
                {
                    // 使用URP提供的CoreUtils工具创建材质。
                    // 原理：CreateEngineMaterial不仅会创建材质，还会自动处理材质的隐藏（HideFlags.HideAndDontSave），防止材质球污染项目的Assets文件夹
                    commonUtilMat = CoreUtils.CreateEngineMaterial(CommonUtilShader);
                }

                // 返回缓存好的材质球
                return commonUtilMat;
            }
        }

        // 私有静态变量，用于缓存一个全屏的三角形网格
        private static Mesh triangleMesh;

        // 公有静态属性，用于获取上面的全屏三角形网格（实现了懒加载单例模式）
        private static Mesh TriangleMesh
        {
            get
            {
                // 如果网格为空
                if (triangleMesh == null)
                {
                    // 获取当前图形API（如DirectX或OpenGL）近裁剪面的Z值。
                    // 原理：不同平台深度缓冲的编码方向不同，DX通常反转Z（远平面=0，近平面=1），OpenGL不反转（近平面=-1，远平面=1）。必须匹配才能正确显示
                    float nearClipZ = SystemInfo.usesReversedZBuffer ? 1 : -1;
                    // 实例化一个新的Mesh对象
                    triangleMesh = new Mesh();
                    // 调用下方的方法，生成覆盖整个屏幕的3个顶点坐标，并赋值给网格
                    triangleMesh.vertices = GetFullScreenTriangleVertexPosition(nearClipZ);
                    // 调用下方的方法，生成这3个顶点对应的UV坐标，并赋值给网格
                    triangleMesh.uv = GetFullScreenTriangleTexCoord();
                    // 定义三角形的绘制索引。由于只有一个三角形，所以按0,1,2的顺序连接三个顶点
                    triangleMesh.triangles = new int[3] { 0, 1, 2 };
                }

                // 返回缓存好的网格
                return triangleMesh;
            }
        }
        
        // 生成全屏三角形顶点坐标的方法。需与URP底层的Common.hlsl逻辑保持一致
        // 参数z代表近裁剪面的深度值
        static Vector3[] GetFullScreenTriangleVertexPosition(float z /*= UNITY_NEAR_CLIP_VALUE*/)
        {
            // 创建一个长度为3的Vector3数组，代表三角形的三个顶点
            var r = new Vector3[3];
            // 循环3次，为每个顶点赋值
            for (int i = 0; i < 3; i++)
            {
                // 使用位运算技巧快速生成(0,0)、(2,0)、(0,2)三个2D坐标
                Vector2 uv = new Vector2((i << 1) & 2, i & 2);
                // 将上述坐标乘以2减去1，映射到NDC（标准化设备坐标）空间，范围变为[-1, 1]。
                // 这3个顶点实际上是：(-1,-1), (1,-1), (-1,1)。它们构成的三角形斜边刚好覆盖整个屏幕的右上角之外，光栅化时会被裁剪成完美的全屏四边形
                r[i] = new Vector3(uv.x * 2.0f - 1.0f, uv.y * 2.0f - 1.0f, z);
            }
            // 返回计算好的顶点数组
            return r;
        }
        
        // 生成全屏三角形UV坐标的方法。需与URP底层的Common.hlsl逻辑保持一致
        static Vector2[] GetFullScreenTriangleTexCoord()
        {
            // 创建一个长度为3的Vector2数组
            var r = new Vector2[3];
            // 循环3次
            for (int i = 0; i < 3; i++)
            {
                // 判断当前平台的图形API，UV原点是否在左上角（DirectX通常是Top，OpenGL是Bottom）
                if (SystemInfo.graphicsUVStartsAtTop)
                    // 如果在顶部：生成(0,1)、(2,1)、(0,-1)的UV。注意这里的UV范围超出了[0,1]，
                    // 但由于顶点坐标构成的三角形超出了屏幕被裁剪，插值后屏幕内剩余像素的UV依然会完美落在[0,1]内，同时修正了Y轴翻转问题
                    r[i] = new Vector2((i << 1) & 2, 1.0f - (i & 2));
                else
                    // 如果在底部：正常生成(0,0)、(2,0)、(0,2)的UV
                    r[i] = new Vector2((i << 1) & 2, i & 2);
            }
            // 返回计算好的UV数组
            return r;
        }

        // 核心公共方法：将源贴图以“加法混合”的方式绘制到目标贴图上
        // cmd：C#端构建渲染指令的缓冲区；source：输入的源图像（如体积光图）；destination：输出的目标图像（如屏幕画面）
        public static void BlitAdd(CommandBuffer cmd, RenderTargetIdentifier source, RenderTargetIdentifier destination)
        {
            // 给材质设置缩放和偏移参数。new Vector4(1, 1, 0, 0)代表XY缩放为1倍，XY偏移为0，即不做任何拉伸变形，完全铺满
            CommonUtilMat.SetVector(ShaderConstants._BlitScaleBias, new Vector4(1, 1, 0, 0));
            // 将传入的源图像（source）设置为全局纹理，名字必须与HLSL中的"_BlitTexture"一致，这样Shader的SAMPLE_TEXTURE2D_X才能采样到它
            cmd.SetGlobalTexture(ShaderConstants._BlitTexture, source);
            // 设置接下来要渲染到的目标纹理。
            // RenderBufferLoadAction.Load：极其重要！表示在绘制前“加载/保留”目标贴图原本的画面内容。如果不保留而用Clear，加法混合就失效了（画面会被清空变黑）
            // RenderBufferStoreAction.Store：表示绘制完成后“存储”结果到目标贴图中
            cmd.SetRenderTarget(destination, RenderBufferLoadAction.Load, RenderBufferStoreAction.Store);
            // 向CommandBuffer下发绘制网格指令。
            // TriangleMesh：使用前面缓存的全屏三角形（比传统的Quad少一个三角形，性能更高）；
            // Matrix4x4.identity：不进行任何模型空间变换；
            // CommonUtilMat：使用前面创建的材质（对应带Blend One One的Shader）；
            // 0：子网格索引（没用到）；
            // 0：Pass索引（对应Shader里"Blit Add"那个Pass的索引号，通常第一个Pass就是0）
            cmd.DrawMesh(TriangleMesh, Matrix4x4.identity, CommonUtilMat, 0, 0);
        }
    }
}
