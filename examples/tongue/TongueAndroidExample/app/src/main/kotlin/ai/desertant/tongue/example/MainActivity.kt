package ai.desertant.tongue.example

import ai.desertant.tongue.Detection
import ai.desertant.tongue.Reliability
import ai.desertant.tongue.Tongue
import ai.desertant.tongue.Verdict
import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.util.Locale

/**
 * Type in any language; the app names it, live and on device.
 *
 * No coroutines and no debounce, unlike EmoAndroidExample. A detection is an int8
 * gather, a sum, one 59x32 matmul and a masked softmax over 2 MB of bundled
 * weights, so it runs on the main thread inside the TextWatcher and still keeps up
 * with typing. Nothing is downloaded and nothing is cached.
 */
class MainActivity : Activity() {

    // The Context gives the usage turnstile somewhere to persist its device id;
    // without it every launch looks like a new device. See docs/USAGE.md.
    private val tongue: Tongue by lazy { Tongue.bundled(this) }

    private lateinit var headline: TextView
    private lateinit var subhead: TextView
    private lateinit var candidates: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildView())
    }

    private fun buildView(): ViewGroup {
        val density = resources.displayMetrics.density
        fun dp(value: Int) = (value * density).toInt()

        headline = TextView(this).apply {
            textSize = 30f
            gravity = Gravity.CENTER
            text = "…"
        }
        subhead = TextView(this).apply {
            textSize = 13f
            gravity = Gravity.CENTER
            setTextColor(Color.parseColor("#777777"))
        }
        candidates = TextView(this).apply {
            textSize = 15f
            typeface = android.graphics.Typeface.MONOSPACE
            setTextColor(Color.parseColor("#333333"))
        }

        val input = EditText(this).apply {
            hint = "Type in any language"
            textSize = 18f
            addTextChangedListener(object : TextWatcher {
                override fun afterTextChanged(s: Editable?) = show(s?.toString().orEmpty())
                override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
                override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            })
        }

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(48), dp(24), dp(24))
            addView(headline, matchWidth(dp(56)))
            addView(subhead, matchWidth(dp(28)))
            addView(input, matchWidth(ViewGroup.LayoutParams.WRAP_CONTENT).also { it.topMargin = dp(20) })
            addView(candidates, matchWidth(ViewGroup.LayoutParams.WRAP_CONTENT).also { it.topMargin = dp(24) })
            addView(hints(::dp), matchWidth(ViewGroup.LayoutParams.WRAP_CONTENT).also { it.topMargin = dp(28) })
        }

        return ScrollView(this).apply { addView(column) }
    }

    private fun matchWidth(height: Int) =
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height)

    private fun hints(dp: (Int) -> Int): ViewGroup {
        val samples = listOf(
            "je voudrais un café au lait" to "French",
            "kann ich das haben" to "German",
            "안녕하세요 만나서 반갑습니다" to "script is decisive",
            "la casa" to "a tie",
            "hi i am" to "too short to be sure",
        )
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(TextView(context).apply {
                text = "TRY"
                textSize = 11f
                setTextColor(Color.parseColor("#999999"))
            })
            samples.forEach { (text, note) ->
                addView(TextView(context).apply {
                    this.text = "$text  —  $note"
                    textSize = 14f
                    setPadding(0, dp(6), 0, dp(6))
                    setTextColor(Color.parseColor("#555555"))
                })
            }
        }
    }

    private fun show(text: String) {
        if (text.isBlank()) {
            headline.text = "…"
            subhead.text = ""
            candidates.text = ""
            return
        }
        val detection = tongue.detect(text)
        headline.text = headline(detection)
        subhead.text = subhead(detection)
        candidates.text = detection.candidates.joinToString("\n") {
            String.format(Locale.US, "%-4s %-16s %3.0f%%", it.language, name(it.language), it.probability * 100)
        }
    }

    /**
     * Two names when the top pair is too close to separate. "la casa" is equally
     * Italian and Spanish, and saying so beats crowning one at random.
     */
    private fun headline(detection: Detection): String {
        val first = detection.candidates.firstOrNull() ?: return "…"
        if (detection.isTooCloseToCall && detection.candidates.size > 1) {
            return "${name(first.language)} or ${name(detection.candidates[1].language)}"
        }
        return name(first.language)
    }

    private fun subhead(detection: Detection): String {
        val reliability = when (detection.reliability) {
            Reliability.CONFIDENT -> "confident"
            Reliability.LIKELY -> "likely"
            Reliability.TENTATIVE -> "too short to be sure"
            Reliability.EMPTY -> return ""
        }
        val route = when (detection.route.verdict) {
            Verdict.DECISIVE -> "script is decisive"
            Verdict.NARROWING -> "script narrowed the field"
            Verdict.AMBIGUOUS -> "no script evidence"
        }
        return "$reliability · $route"
    }

    /** The platform already knows every language name, localized to the reader. */
    private fun name(code: String): String =
        Locale.forLanguageTag(code).getDisplayLanguage(Locale.getDefault())
            .replaceFirstChar { it.uppercase() }
            .ifBlank { code }
}
