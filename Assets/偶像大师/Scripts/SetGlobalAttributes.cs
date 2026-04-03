using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

[ExecuteInEditMode] // 在编辑模式下执行，方便实时预览效果
public class SetGlobalAttributes : MonoBehaviour
{
    MaterialPropertyBlock PropertyBlock; // 材质属性块，用于设置每渲染器的属性
    SkinnedMeshRenderer[] Renderers;// 存储所有SkinnedMeshRenderer组件
    [Tooltip("x:天光强度;Y:多光源强度;Z:多光源Specular强度")] // 全局光照参数：x-天光强度; Y-多光源强度; Z-多光源Specular强度
    public Vector4 GlobalLightParameter = new Vector4(1.0f, 1.0f, 1.0f, 1.0f);
    public GameObject LightDirectionWS; // 世界空间光源方向参考对象
    
    [Tooltip("主光方向，当A通道为0时为Matcap空间;当A通道为1时为世界空间(此时使用上面的LightDirectionWS物体的朝向)")]
    public Vector4 MainLightDirection = new Vector4(0.34f, 0.57f, 0.74f, 0.0f);// 主光源方向：A通道为0时为Matcap空间; A通道为1时为世界空间
    [ColorUsage(true, true)]
    public Color MainLightColor = Color.white;// 主光源颜色，支持HDR
    [Tooltip("x:明暗交界线的Offset;z:阴影的强度")]
    public Vector4 MatCapParam = new Vector4(0.3f, 1.0f, 1.0f, 0.0f); // MatCap参数：x-明暗交界线的Offset; z-阴影的强度
    public Vector4 SpecularThreshold = new Vector4(0.1f, 0.5f, 1.0f, 1.0f);// 高光阈值参数
    [Tooltip("xyz:边缘光方向(ViewSpace);w:边缘光范围，值越大范围越小")]
    public Vector4 MatCapRimLight = new Vector4(-0.4f, -0.26f, 0.87f, 10.0f);// 边缘光参数：xyz-边缘光方向(ViewSpace); w-边缘光范围，值越大范围越小
    [Tooltip("xyz:边缘光颜色;w:一遍为1，为0时边缘光不会乘上基础颜色")]
    [ColorUsage(true, true)]
    public Color MatCapRimColor = Color.white;// 边缘光颜色：w为1时边缘光会乘上基础颜色
    [Tooltip("整体乘以这个颜色")]
    [ColorUsage(true, true)] 
    public Color MultiplyColor = Color.white;  // 整体颜色乘法
    public Color ShadeMultiplyColor = Color.white;// 阴影乘法颜色
    public Color ShadeAdditiveColor = Color.black;// 阴影加法颜色
    [Tooltip("皮肤颜色饱和度")]
    public float SkinSaturation = 1;// 皮肤颜色饱和度
    [ColorUsage(true, true)]
    public Color EyeHightlightColor = Color.white;// 眼睛高光颜色，支持HDR
    public Cubemap VLSpecCube;// 环境反射立方体贴图
    [ColorUsage(true, true)]
    public Color VLSpecColor = Color.white;// 环境反射颜色，支持HDR
    [ColorUsage(true, true)]
    public Color VLEyeSpecColor = Color.white;// 眼睛环境反射颜色，支持HDR
    public Vector4 ReflectionSphereMapHDR = Vector4.one;  // 反射球贴图HDR参数
    [Tooltip("x:Outline最小宽度;Y:Outline最大宽度;Z和W作用一致都是控制宽度")]
    public Vector4 OutlineParam = new Vector4(0.05f, 5.0f, 0.011f, 0.45f);// 轮廓线参数：x-最小宽度; Y-最大宽度; Z和W控制宽度
    public Transform Head;//// 头部变换参考，用于计算头部相关方向
    
    void UpdateProperties() // 更新所有属性的方法
    {
        Vector3 NormalizedLight = Vector3.Normalize(MainLightDirection);  // 归一化光源方向
        if (LightDirectionWS && MainLightDirection.w > 0.5f)  // 如果指定了世界空间光源方向对象且使用世界空间模式
        {
            NormalizedLight = LightDirectionWS.transform.up; // 使用指定对象的上方向作为光源方向
        }
        // 设置全局着色器属性（影响所有使用该着色器的物体）
        Shader.SetGlobalVector("_GlobalLightParameter", GlobalLightParameter);
        Shader.SetGlobalVector("_MatCapMainLight", new Vector4(NormalizedLight.x, NormalizedLight.y, NormalizedLight.z, MainLightDirection.w));
        Shader.SetGlobalVector("_MatCapLightColor", MainLightColor);
        Shader.SetGlobalVector("_MatCapParam", MatCapParam);
        Shader.SetGlobalVector("_MatCapRimLight", MatCapRimLight);
        Shader.SetGlobalVector("_MatCapRimColor", MatCapRimColor);
        Shader.SetGlobalVector("_MultiplyColor", MultiplyColor);
        Shader.SetGlobalVector("_ShadeMultiplyColor", ShadeMultiplyColor);
        Shader.SetGlobalVector("_ShadeAdditiveColor", ShadeAdditiveColor);
        Shader.SetGlobalFloat("_SkinSaturation", SkinSaturation);
        Shader.SetGlobalVector("_EyeHighlightColor", EyeHightlightColor);
        Shader.SetGlobalTexture("_VLSpecCube", VLSpecCube);
        Shader.SetGlobalVector("_VLSpecColor", VLSpecColor);
        Shader.SetGlobalVector("_VLEyeSpecColor", VLEyeSpecColor);
        Shader.SetGlobalVector("_ReflectionSphereMapHDR", ReflectionSphereMapHDR);
        Shader.SetGlobalVector("_OutlineParam", OutlineParam);
        
        //// 计算头部相关方向
        Vector4 HeadDirection = new Vector4(0, 0, 1, 0); // 默认前向
        Vector4 HeadUp = new Vector4(0, 1, 0, 0); // 默认上向
        Vector4 HeadRight = new Vector4(1, 0, 0, 0);   // 默认右向
        Matrix4x4 HeadXAxisReflectionMatrix = Matrix4x4.identity; // 头部反射矩阵
        if (Head)   // 如果指定了头部变换
        {
            //// 获取头部的方向向量
            HeadDirection = Head.forward;
            HeadUp = Head.up;
            HeadRight = Head.right;
            // 构建头部X轴反射矩阵（用于特殊反射效果）
            HeadXAxisReflectionMatrix.SetColumn(0, -HeadRight); // 第一列：负右向
            HeadXAxisReflectionMatrix.SetColumn(1, HeadUp);// 第二列：上向
            HeadXAxisReflectionMatrix.SetColumn(2, HeadDirection);// 第三列：前向
            HeadXAxisReflectionMatrix.SetColumn(3, new Vector4(0, 0, 0, 1));// 第四列：位置
        }
        // 创建材质属性块（用于设置每渲染器的属性）
        PropertyBlock = new MaterialPropertyBlock();
        PropertyBlock.SetVector("_HeadDirection", HeadDirection);
        PropertyBlock.SetVector("_HeadUpDirection", HeadUp);
        PropertyBlock.SetMatrix("_HeadXAxisReflectionMatrix", HeadXAxisReflectionMatrix);

        if (Renderers != null)// 为所有SkinnedMeshRenderer设置属性块
        {
            foreach (SkinnedMeshRenderer SkinnedRenderer in Renderers)
            {
                SkinnedRenderer.SetPropertyBlock(PropertyBlock);
            }
        }
    }
    
    void Start()
    {
        Renderers = GetComponentsInChildren<SkinnedMeshRenderer>();
        UpdateProperties();
    }

    private void OnValidate()
    {
        UpdateProperties();
    }
    
    private void Update()
    {
        UpdateProperties();
    }

}
