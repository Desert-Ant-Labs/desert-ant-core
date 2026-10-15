package ai.desertant.androidtest

import android.os.Bundle
import android.system.Os
import androidx.test.runner.AndroidJUnitRunner

/** The app on the device does not inherit the host's environment, so the Hub settings and the license endpoint arrive as instrumentation arguments. */
class HubTestRunner : AndroidJUnitRunner() {
    override fun onCreate(arguments: Bundle) {
        for (name in listOf("HF_TOKEN", "DAL_HF_REPO_SUFFIX", "DAL_LICENSE_ENDPOINT")) {
            arguments.getString(name)?.takeIf { it.isNotEmpty() }?.let { Os.setenv(name, it, true) }
        }
        super.onCreate(arguments)
    }
}
