
# AI Gif Coder

AI Gif Coder is a reactive, local-first chat interface built with Dart and Flutter.

It bridges the gap between local LLM servers (like LM Studio or Ollama) and an interactive, visually responsive user experience.

Unlike traditional static chat interfaces, AI Gif Coder changes its background animations dynamically depending on the AI's state—whether it's waiting for input, processing a thought, or streaming a reply. Additionally, it features a dedicated file system bridge to output cleanly formatted code files directly to your local machine.

✔️ Reactive GIF Interface: Fully customized state-driven backgrounds. Set different animated GIFs for Waiting, Thinking, Replying, and Working states to give your AI a distinct personality.

✔️ Direct Code File Output: Toggle the Code File Output switch to have generated code directly written into files on your local machine instead of just printing raw text in a chat bubble.

✔️ Local LLM Integration: Built to connect seamlessly with any OpenAI-compatible API endpoint running locally (e.g., LM Studio, Ollama, Open WebUI) via port mapping (http://localhost:1234).

✔️ Customizable: Easily map your own GIF folders directly from the UI settings.

✔️ Offline Speech Input: Record a prompt from the microphone and transcribe it
locally with the bundled multilingual Whisper model on Windows, macOS, and
Linux. Audio is deleted after transcription and is never uploaded.

### Desktop speech requirements

- Windows: a working microphone recognized by Windows.
- macOS: grant microphone access when prompted.
- Linux: PipeWire or PulseAudio must expose a capture device. GStreamer is
  available by default on many distributions; install it through your package
  manager if microphone initialization reports that it is missing.
- Speech recordings stop automatically after 60 seconds. Transcribed text is
  inserted into the prompt for review and is not sent automatically.

🛠️ Flutter/Dart

🛠️ API Compatibility: OpenAI-compatible REST API endpoints

📦 Windows: Available Now

📦 Linux: ⏳ Coming Soon

📦 macOS: 🗓️ Planned

⚙️⚙️⚙️ Configuration & Setup ⚙️⚙️⚙️

Launch your Local LLM Server: Ensure your local backend (like LM Studio) is running and the cross-origin resource sharing (CORS) and local server port is active (Default: http://localhost:1234).

Configure App Settings: Click the Gear Icon in the top right corner. Enter your local server connection URL. Target your specific Model name (local-model works by default with LM Studio).

Select your custom asset folder containing your state GIFs (waiting.gif, thinking.gif, replying.gif).

Save and Chat. Toggle Code File Output whenever you want the AI to write scripts directly to your Documents folder.
