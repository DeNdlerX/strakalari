# Python reaches these classes by name through pyjnius (strakalari/core/android.py):
# R8 must neither rename them nor drop members only Python calls. Without this,
# release builds abort the app at the first lookup ("JNI DETECTED ERROR ... obj == null").
-keep class io.github.dendlerx.strakalari.android.** { *; }
