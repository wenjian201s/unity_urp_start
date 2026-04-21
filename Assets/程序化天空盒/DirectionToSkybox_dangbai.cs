using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

public class DirectionToSkybox_dangbai : MonoBehaviour
{
    public GameObject sun; // 模拟太阳的空物体
    public GameObject moon; // 模拟月亮的空物体
    public Material targetMaterial;
    
    public string sunDirectionPropertyName = "_SunDirection"; // 模拟太阳方向在Skybox材质上的属性名称
    public string moonDirectionPropertyName = "_MoonDirection"; // 模拟月亮方向在Skybox材质上的属性名称
    // Start is called before the first frame update
    void Start()
    {
        if (targetMaterial == null)
        {
            Debug.LogError("Please assign a target Skybox material.");
            return;
        }
    }


    

    // Update is called once per frame

    void Update()
    {
        Matrix4x4 LtoW = moon.transform.localToWorldMatrix;
        if (targetMaterial != null)
        {
            targetMaterial.SetMatrix("LToW", LtoW);

            if (sun!=null)
            {
                Vector3 sunDirection = -sun.transform.forward.normalized;
                targetMaterial.SetVector(sunDirectionPropertyName, sunDirection); 
                ;
            }

            if (moon!=null)
            {
                Vector3 moonDirection = -moon.transform.forward.normalized;
                targetMaterial.SetVector(moonDirectionPropertyName, moonDirection);
            }
            
        }
    }
}
