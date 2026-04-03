using System;

namespace UnityEngine.Rendering.Universal
{
    [Serializable, VolumeComponentMenu("SSAO/GTAO")]
    public class GroundTruthAmbientOcclusion : VolumeComponent, IPostProcessComponent
    {
        public ClampedIntParameter downsamplingFactor = new ClampedIntParameter(2, 1, 4);

        public ClampedFloatParameter intensity = new ClampedFloatParameter(0.0f, 0.0f, 1.0f);
        public ClampedFloatParameter radius = new ClampedFloatParameter(1.0f, 0.01f, 5.0f);
        public ClampedFloatParameter distributionPower = new ClampedFloatParameter(2.0f, 1.0f, 5.0f);
        public ClampedFloatParameter falloffRange = new ClampedFloatParameter(0.1f, 0.01f, 1.0f);

        public bool IsActive()
        {
            return active && intensity.value > 0.0f;
        }

        public bool IsTileCompatible()
        {
            return false;
        }
    }
}