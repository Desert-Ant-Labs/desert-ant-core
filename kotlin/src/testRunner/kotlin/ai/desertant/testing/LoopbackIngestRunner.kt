package ai.desertant.testing

import android.os.Bundle
import android.system.Os
import androidx.test.runner.AndroidJUnitRunner

/** Points the device's usage ingest at loopback before any test, so on-device suites never post real events. */
class LoopbackIngestRunner : AndroidJUnitRunner() {
    override fun onCreate(arguments: Bundle?) {
        // Before super, which starts the tests: core threads read the
        // environment once a model loads, and setenv racing getenv is unsafe.
        Os.setenv("DAL_INGEST_ENDPOINT", "http://127.0.0.1:9/api/v1/ingest", true)
        super.onCreate(arguments)
    }
}
