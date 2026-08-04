package ai.desertant.emo

/**
 * Preferred emoji skin tone variant for skin-tone-capable emoji. The skin tone
 * is applied inside the shared native core, so this only carries the choice
 * across the JNI boundary.
 */
enum class EmojiSkinTone(internal val nativeValue: Int) {
    /** Default emoji presentation with no skin tone modifier. */
    DEFAULT(0),
    LIGHT(1),
    MEDIUM_LIGHT(2),
    MEDIUM(3),
    MEDIUM_DARK(4),
    DARK(5),
}
