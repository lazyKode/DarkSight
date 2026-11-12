# Models

No trained model ships yet. `radar_detector.tflite` / `radar_detector.mlmodel`
belong here once trained.

The overlay currently runs the classical detectors in `lib/ml/` (CFAR +
clustering + rules), which sit behind the interface a model would use:

- Tier 1: `RadarDetector.detect(PolarFrame) -> List<Detection>`
- Tier 3: `PointClassifier.classify(List<RadarPoint>) -> List<Cluster>`

Training plan: render labelled frames from `SimRadarSource` (the scene gives
ground-truth boxes for free), train a small U-Net or YOLO-nano on the
360 x 200 polar image, export to TFLite, convert the same graph to Core ML
with coremltools, and load it through `tflite_flutter` on Android and a
platform channel on iOS.
