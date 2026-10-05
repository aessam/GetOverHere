package com.aessam.comeoverhere.debug

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.aessam.comeoverhere.ComeOverHereApp
import com.aessam.comeoverhere.MainActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** ADB may open consent, but neither extras nor deep links can activate commands. */
class GatewayDebugActivity : Activity() {
    private lateinit var state: TextView
    private lateinit var enable: Button
    private val handler = Handler(Looper.getMainLooper())
    private var starting = false
    private val refresh = object : Runnable {
        override fun run() { render(); handler.postDelayed(this, 1000) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val spacing = (24 * resources.displayMetrics.density).toInt()
            setPadding(spacing, spacing, spacing, spacing)
        }
        layout.addView(TextView(this).apply {
            text = "Debug control\n\nAllow an authorized ADB controller to operate this app for 10 minutes. " +
                "Control is localhost-only, encrypted, authenticated and absent from Release. " +
                "This does not keep the screen awake. Commands that change state require the app in foreground."
            textSize = 18f
        })
        state = TextView(this).apply { contentDescription = "Debug control state" }
        layout.addView(state)
        enable = Button(this).apply {
            text = "Enable debug control for 10 minutes"
            setOnClickListener { activate() }
        }
        layout.addView(enable)
        layout.addView(Button(this).apply {
            text = "Disable debug control"
            setOnClickListener { current?.stop(); current = null; render() }
        })
        layout.addView(Button(this).apply {
            text = "Record app observations for 2 minutes"
            setOnClickListener {
                try { GatewayScenarioRecorder.start(application as ComeOverHereApp, 120) }
                catch (error: Exception) { state.text = "Recording rejected: ${error.javaClass.simpleName}" }
            }
        })
        layout.addView(Button(this).apply {
            text = "Cancel observation recording"
            setOnClickListener { GatewayScenarioRecorder.cancel() }
        })
        layout.addView(Button(this).apply {
            text = "Return to tour"
            setOnClickListener {
                startActivity(Intent(this@GatewayDebugActivity, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
                finish()
            }
        })
        setContentView(layout)
    }

    private fun activate() {
        if (starting || current?.active == true) return
        starting = true; render()
        current?.stop()
        val candidate = GatewayDebugControl(application as ComeOverHereApp)
        current = candidate
        // Application-scoped startup survives this Activity closing; endpoint
        // expiration is owned by the server, not an Activity or an attached Mac.
        activationScope.launch {
            try {
                withContext(Dispatchers.IO) { candidate.start() }
                state.text = "Active for up to 10 minutes. Retrieve credentials with authorized ADB."
            } catch (error: Exception) {
                candidate.stop()
                state.text = "Debug control failed: ${error.javaClass.simpleName}"
            } finally {
                starting = false; enable.isEnabled = current?.active != true
            }
        }
    }

    private fun render() {
        val canEnable = !starting && current?.active != true
        if (enable.isEnabled != canEnable) enable.isEnabled = canEnable
        val message = when {
            starting -> "Starting encrypted control endpoint…"
            current?.active == true -> "Debug control active. No debug keep-awake."
            else -> "Debug control inactive."
        }
        // Reassigning unchanged text continuously emits accessibility events and
        // prevents UIAutomator/Espresso from observing an idle screen.
        if (state.text.toString() != message) state.text = message
    }

    override fun onResume() { super.onResume(); handler.post(refresh) }
    override fun onPause() { handler.removeCallbacks(refresh); super.onPause() }

    companion object {
        private val activationScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        @Volatile private var current: GatewayDebugControl? = null
    }
}
