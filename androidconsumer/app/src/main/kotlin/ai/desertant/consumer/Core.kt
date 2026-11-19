package ai.desertant.consumer

import ai.desertant.core.DesertAnt
import ai.desertant.core.LogLevel

// Core is not a direct dependency: it has to reach the app through a model's
// `api` dependency, as it does for customers following the README.
fun configure() {
    DesertAnt.apiKey = "pk_test"
    DesertAnt.logLevel = LogLevel.DEBUG
    DesertAnt.logger = { level, source, message -> println("$level $source $message") }
}
