# SPDX-License-Identifier: GPL-3.0-only
#
# Auralis Android R8 rules.
#
# AGP 8 runs R8 in full mode, so reflective entry points that libraries used to
# keep implicitly must be declared here. Auralis relies on three of them:
#
#  * kotlinx.serialization: every @Serializable class gets a generated
#    `$$serializer` plus a `Companion.serializer()` factory, both looked up by
#    name. Without the rules below the whole catalog payload decode path is
#    stripped and Room rows fail to decode at runtime.
#  * Room: generated `*_Impl` classes are resolved by name; Room ships consumer
#    rules, but keep the database holder explicitly because it is created from
#    the Application graph, not from a manifest component.
#  * OkHttp / Media3 / Retrofit / Coil: resolved by name from XML-free code
#    paths, and they ship their own consumer rules; listed here only to make the
#    dependency explicitly documented.
#
# Manifest-declared components (activities, services, the Application class) are
# kept automatically by AGP's generated `aapt_rules.txt`; they are intentionally
# not repeated here.

# ---------------------------------------------------------------- attributes
-keepattributes RuntimeVisibleAnnotations,RuntimeVisibleParameterAnnotations
-keepattributes AnnotationDefault,InnerClasses,EnclosingMethod,Signature
-keepattributes *Annotation*,Exceptions,SourceFile,LineNumberTable

# ------------------------------------------------------------------ coroutines / metadata
-keep class kotlin.Metadata { *; }
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}
-dontwarn kotlinx.coroutines.**

# --------------------------------------------------------------- serialization
# Official kotlinx.serialization recipe (docs: "R8 / ProGuard").
-if @kotlinx.serialization.Serializable class **
-keepclassmembers class <1> {
    static <1>$Companion Companion;
}

-if @kotlinx.serialization.Serializable class ** {
    static **$* *;
}
-keepclassmembers class <2>$<3> {
    kotlinx.serialization.KSerializer serializer(...);
}

-if @kotlinx.serialization.Serializable class ** {
    public static ** INSTANCE;
}
-keepclassmembers class <1> {
    public static <1> INSTANCE;
    kotlinx.serialization.KSerializer serializer(...);
}

-keepclassmembers class **$$serializer {
    *;
}
-keepclasseswithmembers class * {
    kotlinx.serialization.KSerializer serializer(...);
}

# Sealed/polymorphic hierarchies stored in the Room payload column.
-keep,includedescriptorclasses class com.auralis.**$$serializer { *; }
-keepclassmembers class com.auralis.** {
    *** Companion;
}

-dontnote kotlinx.serialization.**

# --------------------------------------------------------------------- Room
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class com.auralis.core.data.db.AuralisDatabase { *; }
-keep class com.auralis.core.data.db.**_Impl { *; }
-dontwarn androidx.room.paging.**

# ------------------------------------------------------- networking / media
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-keep,allowobfuscation,allowshrinking interface retrofit2.Call
-keep,allowobfuscation,allowshrinking class retrofit2.Response
-keep,allowobfuscation,allowshrinking class kotlin.coroutines.Continuation
-dontwarn retrofit2.**
-dontwarn javax.annotation.**
-dontwarn coil.**

# ------------------------------------------------------------------- Compose
# Compose stores @Composable lambdas in classes whose `invoke` is called
# reflectively by the runtime's restart machinery.
-keepclassmembers class **$* implements androidx.compose.runtime.Composer { *; }
-dontwarn androidx.compose.**

# ------------------------------------------------------------------ security
# androidx.security-crypto touches Tink via reflection.
-dontwarn com.google.crypto.tink.**
