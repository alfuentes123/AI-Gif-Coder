
# AI Gif Coder

AI Gif Coder is a reactive chat interface built with Dart and Flutter.

Unlike traditional static chat interfaces, AI Gif Coder changes its background animations dynamically depending on the AI's state. Whether it's waiting for input, processing a thought, or streaming a reply. Additionally, it features a dedicated file system bridge to output cleanly formatted code files directly to your local machine.

✔️ Reactive GIF Interface: State driven backgrounds. Set different animated GIFs for Waiting, Thinking, Replying, and Working states to give your AI a distinct personality.

✔️ Direct Code File Output: Toggle the Code File Output switch to have generated code directly written into files on your local machine.

✔️ LLM Integration: Built to connect seamlessly with any OpenAI compatible API endpoint.

✔️ Customizable: Easily map your own GIF folders directly from the UI settings.

✔️ Offline Speech Input: Record a prompt from the microphone and transcribe it locally with the bundled multilingual Whisper model.

📦 Windows: Available Now

📦 Linux/MacOS: Planned

⚙️⚙️⚙️ Configuration & Setup ⚙️⚙️⚙️

Configure App Settings: Click the Gear Icon in the top right corner. Enter your AI connection URL. Target your specific Model name (local-model works by default with LM Studio).

Select your custom asset folder containing your state GIFs (waiting.gif, thinking.gif, replying.gif).

Save and Chat. Toggle Code File Output whenever you want the AI to write scripts directly to your Documents folder.
