# Swift looks up these host callbacks and model bridges by their JVM/JNI names.
-keep class ai.desertant.DesertAntNative { public static *; }
-keepclasseswithmembernames class ai.desertant.** { native <methods>; }
