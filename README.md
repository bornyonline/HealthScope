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
2. In Xcode, select your Apple Development team under **Signing & Capabilities**. The repository does not store a team identifier.
3. Open **Analysis & Advice** tab.
4. Tap the gear icon and set:
   - **Ollama Base URL** (use `http://<mac-lan-address>:11434` on a physical iPhone)
   - **Model** (default: `llama3.1:8b`)
   - **Stream responses** on/off
5. Send a message. With your consent, the app includes dated daily metrics and a bounded list of workout sessions for the selected 7-, 30-, or 90-day range.

### Notes
- Conversation history is stored locally on-device and persists across launches.
- Plaintext HTTP is accepted only for local-network endpoints. Prefer HTTPS when your server supports it.
- The assistant provides non-medical guidance only and encourages clinician follow-up for medical decisions.
