package ai.desertant.testing

import android.os.Bundle
import android.system.Os
import androidx.test.runner.AndroidJUnitRunner

/** Test-only runner for our device suites: usage goes to a closed local port, set before any model builds its usage client. */
class LocalIngestRunner : AndroidJUnitRunner() {
    override fun onCreate(arguments: Bundle?) {
        Os.setenv("DAL_INGEST_ENDPOINT", LOCAL_INGEST_ENDPOINT, true)
        super.onCreate(arguments)
    }

    companion object {
        const val LOCAL_INGEST_ENDPOINT: String = "http://127.0.0.1:1/ingest"
    }
}
