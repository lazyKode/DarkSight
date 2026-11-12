// TODO(csi): JNI entry points for raw CSI on rooted devices with Nexmon CSI.
// Planned surface:
//   jboolean Java_com_darksight_darksight_Csi_open(JNIEnv*, jclass, jint port);
//   jint     Java_com_darksight_darksight_Csi_read(JNIEnv*, jclass, jfloatArray amp, jfloatArray phase);
//   void     Java_com_darksight_darksight_Csi_close(JNIEnv*, jclass);
// See README.md in this directory for why this cannot work on stock Android.
