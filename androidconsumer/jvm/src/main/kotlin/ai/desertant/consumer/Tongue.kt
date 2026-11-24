package ai.desertant.consumer

import ai.desertant.tongue.Tongue

fun main() {
    val detection = Tongue.bundled(null).detect("Bonjour tout le monde")
    check(detection.language == "fr") { "Unexpected Tongue result: $detection" }
    println("${detection.language} ${detection.reliability} ${detection.isTooCloseToCall}")
}
