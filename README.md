# HealthScope

## Analysis & Advice (Ollama)
HealthScope includes an AI-powered **Analysis & Advice** tab that can connect directly to an Ollama server running on your Mac.

### Configure Ollama on Mac
1. Start Ollama on your Mac and ensure it listens on your LAN IP.
2. Pull the model you want to use, for example:
   ```bash
   ollama pull llama3.1:8b
   ```
3. Verify from your Mac:
   ```bash
   curl http://127.0.0.1:11434/api/tags
   ```

### Configure the iPhone app
1. Connect iPhone and Mac to the same Wi-Fi network.
2. Open **Analysis & Advice** tab.
3. Tap the gear icon and set:
   - **Ollama Base URL** (default: `http://127.0.0.1:11434`)
   - **Model** (default: `llama3.1:8b`)
   - **Stream responses** on/off
4. Send a message. The app includes a short health metrics summary with your prompt context.

### Notes
- Conversation history is stored locally on-device and persists across launches.
- The assistant provides non-medical guidance only and encourages clinician follow-up for medical decisions.
