package ai.desertant.tongue

import ai.desertant.tongue.license.DEAD_ENDPOINT
import ai.desertant.tongue.license.testRuntime
import ai.desertant.tongue.license.withRuntime
import kotlin.test.Test

class GoldenVectorsTest {
    @Test
    fun matchesTheSharedVectors() = withRuntime(testRuntime(DEAD_ENDPOINT)) { runGoldenVectors() }
}
