package ai.desertant.consumer

import ai.desertant.tongue.Tongue

fun main() {
    val detection = Tongue.bundled(null).detect("Bonjour tout le monde")
    println("${detection.language} ${detection.reliability} ${detection.isTooCloseToCall}")
}
