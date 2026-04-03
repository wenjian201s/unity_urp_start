// Upgrade NOTE: replaced 'mul(UNITY_MATRIX_MVP,*)' with 'UnityObjectToClipPos(*)'

Shader "Unlit/fur"
{
    Properties
    {
       
        FurLength("毛发长度",float)=0
        UVScale("毛发大小",float)=1.0
        Layer ("毛发层级",float)=0
        vGravity ("重力方向 ",color)=(0,0,-3,1)
        FurTexture("毛发纹理",2d)="white" {}
        _LayerMap("毛发的噪声纹理",2d)="white" {}
        _EdgeFade("毛发1",float)=1.0
    }
    SubShader
    {
        Tags { "RenderType"="Transparent" "Queue" = "Transparent"}
        Blend SrcAlpha OneMinusSrcAlpha
        
    
        Cull off
      

    Pass{
            CGPROGRAM
            #pragma vertex vert0
            #pragma fragment frag0
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert0(appdata v){return vert_1(v,0,0);}
            fixed4 frag0(v2f i):SV_TARGET{return frag_1(i,0);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert1
            #pragma fragment frag1
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert1(appdata v){return vert_1(v,0.01,1);}
            fixed4 frag1(v2f i):SV_TARGET{return frag_1(i,0.01);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert2
            #pragma fragment frag2
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert2(appdata v){return vert_1(v,0.02,2);}
            fixed4 frag2(v2f i):SV_TARGET{return frag_1(i,0.02);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert3
            #pragma fragment frag3
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert3(appdata v){return vert_1(v,0.03,3);}
            fixed4 frag3(v2f i):SV_TARGET{return frag_1(i,0.03);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert4
            #pragma fragment frag4
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert4(appdata v){return vert_1(v,0.04,4);}
            fixed4 frag4(v2f i):SV_TARGET{return frag_1(i,0.04);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert5
            #pragma fragment frag5
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert5(appdata v){return vert_1(v,0.05,5);}
            fixed4 frag5(v2f i):SV_TARGET{return frag_1(i,0.05);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert6
            #pragma fragment frag6
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert6(appdata v){return vert_1(v,0.06,6);}
            fixed4 frag6(v2f i):SV_TARGET{return frag_1(i,0.06);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert7
            #pragma fragment frag7
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert7(appdata v){return vert_1(v,0.07,7);}
            fixed4 frag7(v2f i):SV_TARGET{return frag_1(i,0.07);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert8
            #pragma fragment frag8
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert8(appdata v){return vert_1(v,0.08,8);}
            fixed4 frag8(v2f i):SV_TARGET{return frag_1(i,0.08);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert9
            #pragma fragment frag9
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert9(appdata v){return vert_1(v,0.09,8);}
            fixed4 frag9(v2f i):SV_TARGET{return frag_1(i,0.09);}

            ENDCG
        }
       Pass{
            CGPROGRAM
            #pragma vertex vert10
            #pragma fragment frag10
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert10(appdata v){return vert_1(v,0.10,9);}
            fixed4 frag10(v2f i):SV_TARGET{return frag_1(i,0.1);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert11
            #pragma fragment frag11
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert11(appdata v){return vert_1(v,0.11,10);}
            fixed4 frag11(v2f i):SV_TARGET{return frag_1(i,0.11);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert12
            #pragma fragment frag12
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert12(appdata v){return vert_1(v,0.12,11);}
            fixed4 frag12(v2f i):SV_TARGET{return frag_1(i,0.12);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert13
            #pragma fragment frag13
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert13(appdata v){return vert_1(v,0.13,12);}
            fixed4 frag13(v2f i):SV_TARGET{return frag_1(i,0.13);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert14
            #pragma fragment frag14
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert14(appdata v){return vert_1(v,0.14,13);}
            fixed4 frag14(v2f i):SV_TARGET{return frag_1(i,0.14);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert15
            #pragma fragment frag15
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert15(appdata v){return vert_1(v,0.15,14);}
            fixed4 frag15(v2f i):SV_TARGET{return frag_1(i,0.15);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert16
            #pragma fragment frag16
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert16(appdata v){return vert_1(v,0.16,15);}
            fixed4 frag16(v2f i):SV_TARGET{return frag_1(i,0.16);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert17
            #pragma fragment frag17
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert17(appdata v){return vert_1(v,0.17,16);}
            fixed4 frag17(v2f i):SV_TARGET{return frag_1(i,0.17);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert18
            #pragma fragment frag18
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert18(appdata v){return vert_1(v,0.18,17);}
            fixed4 frag18(v2f i):SV_TARGET{return frag_1(i,0.18);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert19
            #pragma fragment frag19
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert19(appdata v){return vert_1(v,0.19,18);}
            fixed4 frag19(v2f i):SV_TARGET{return frag_1(i,0.19);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert20
            #pragma fragment frag20
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert20(appdata v){return vert_1(v,0.20,19);}
            fixed4 frag20(v2f i):SV_TARGET{return frag_1(i,0.20);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert21
            #pragma fragment frag21
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert21(appdata v){return vert_1(v,0.21,20);}
            fixed4 frag21(v2f i):SV_TARGET{return frag_1(i,0.21);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert22
            #pragma fragment frag22
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert22(appdata v){return vert_1(v,0.22,21);}
            fixed4 frag22(v2f i):SV_TARGET{return frag_1(i,0.22);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert23
            #pragma fragment frag23
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert23(appdata v){return vert_1(v,0.23,22);}
            fixed4 frag23(v2f i):SV_TARGET{return frag_1(i,0.23);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert24
            #pragma fragment frag24
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert24(appdata v){return vert_1(v,0.24,23);}
            fixed4 frag24(v2f i):SV_TARGET{return frag_1(i,0.24);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert25
            #pragma fragment frag25
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert25(appdata v){return vert_1(v,0.25,24);}
            fixed4 frag25(v2f i):SV_TARGET{return frag_1(i,0.25);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert26
            #pragma fragment frag26
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert26(appdata v){return vert_1(v,0.26,25);}
            fixed4 frag26(v2f i):SV_TARGET{return frag_1(i,0.26);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert27
            #pragma fragment frag27
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert27(appdata v){return vert_1(v,0.27,26);}
            fixed4 frag27(v2f i):SV_TARGET{return frag_1(i,0.27);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert28
            #pragma fragment frag28
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert28(appdata v){return vert_1(v,0.28,27);}
            fixed4 frag28(v2f i):SV_TARGET{return frag_1(i,0.28);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert29
            #pragma fragment frag29
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert29(appdata v){return vert_1(v,0.29,28);}
            fixed4 frag29(v2f i):SV_TARGET{return frag_1(i,0.29);}

            ENDCG
        }
        Pass{
            CGPROGRAM
            #pragma vertex vert30
            #pragma fragment frag30
            #include "Assets/3渲染2/layer2.cginc"

            v2f vert30(appdata v){return vert_1(v,0.3,29);}
            fixed4 frag30(v2f i):SV_TARGET{return frag_1(i,0.3);}

            ENDCG
        }
    }

}
