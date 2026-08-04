package ai.desertant.redact.example

import ai.desertant.redact.Redact
import android.app.Activity
import android.os.Bundle
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var redact: Redact
    private lateinit var input: EditText
    private lateinit var output: TextView
    private lateinit var progress: ProgressBar

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        redact = Redact(this)
        setContentView(buildView())
    }

    override fun onDestroy() {
        scope.cancel()
        redact.close()
        super.onDestroy()
    }

    private fun buildView(): ScrollView {
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()

        input = EditText(this).apply {
            setText(SAMPLE_TEXT)
            minLines = 5
            setSingleLine(false)
        }
        output = TextView(this).apply {
            textSize = 16f
            text = "Tap Redact to run the model locally. The first run downloads the model and caches it."
            setPadding(0, dp(12), 0, 0)
        }
        progress = ProgressBar(this).apply { visibility = ProgressBar.GONE }

        val button = Button(this).apply {
            text = "Redact"
            setOnClickListener { runRedaction() }
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(20))
            addView(TextView(context).apply {
                text = "Redact Android Example"
                textSize = 24f
            })
            addView(input, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            addView(button, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            addView(progress, ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
            addView(output, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }

        return ScrollView(this).apply { addView(root) }
    }

    private fun runRedaction() {
        val text = input.text.toString()
        progress.visibility = ProgressBar.VISIBLE
        output.text = "Redacting..."

        scope.launch {
            try {
                val result = withContext(Dispatchers.Default) { redact.redaction(text) }
                output.text = buildString {
                    appendLine(result.redactedText)
                    appendLine()
                    appendLine("Items:")
                    for (item in result.items) {
                        appendLine("${item.placeholder} = \"${item.original}\" (${item.label})")
                    }
                }
            } catch (error: Throwable) {
                output.text = error.stackTraceToString()
            } finally {
                progress.visibility = ProgressBar.GONE
            }
        }
    }

    private companion object {
        const val SAMPLE_TEXT = "Email Anna Kovács at anna@example.hu, IBAN DE89370400440532013000. " +
            "Ship to 123 Main Street, Apt 4B. VAT DE129273398, IMEI 490154203237518."
    }
}
