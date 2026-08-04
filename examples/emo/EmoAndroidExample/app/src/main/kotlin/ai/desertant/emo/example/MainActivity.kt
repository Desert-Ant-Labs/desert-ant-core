package ai.desertant.emo.example

import ai.desertant.emo.Emo
import android.app.Activity
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Type a short phrase; the app suggests emoji for it, live, on device. The first
 * suggestion downloads and caches the model.
 */
class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var emo: Emo
    private lateinit var output: TextView
    private var pending: Job? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        emo = Emo(this)
        setContentView(buildView())
    }

    override fun onDestroy() {
        scope.cancel()
        emo.close()
        super.onDestroy()
    }

    private fun buildView(): LinearLayout {
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()

        output = TextView(this).apply { textSize = 56f; text = "✨" }
        val input = EditText(this).apply {
            hint = "What's on your list?"
            textSize = 18f
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) = suggest(s?.toString().orEmpty())
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            })
        }

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(48), dp(24), dp(24))
            addView(TextView(context).apply { text = "Emo Android Example"; textSize = 24f })
            addView(output, ViewGroup.LayoutParams.MATCH_PARENT, dp(120))
            addView(input, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }
    }

    private fun suggest(text: String) {
        pending?.cancel()
        if (text.isBlank()) { output.text = "✨"; return }
        pending = scope.launch {
            delay(200)  // debounce keystrokes
            val emoji = runCatching { emo.suggestions(text, limit = 1).firstOrNull()?.emoji }.getOrNull()
            if (emoji != null) output.text = emoji
        }
    }
}
