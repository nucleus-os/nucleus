package dev.nucleus.android

class NucleusException internal constructor(
    operation: String,
    private val nativeCode: Int,
) : IllegalStateException("$operation failed: ${Nucleus.describeError(nativeCode)}") {
    fun code(): Int = nativeCode
}
