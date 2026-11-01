# Gemma 4 on a Raspberry Pi 5

A private chat assistant on your home network: **Gemma 4 E2B and E4B** running on a **Raspberry Pi 5 (8 GB)** with **llama.cpp**, served through an **OpenAI-compatible API** with a **built-in web UI** and a small **iOS app**. Optional: more models (**Qwen 3.5**, **Ministral 3**, **Granite 4.2**, **LFM2.5**) and **web search**.

```
 iPhone (Pi Chat app or Safari)  ─┐
 Laptop (browser, Python, curl)  ─┼──  http://pi-llm.local:8080  ──  Raspberry Pi 5
 Anything OpenAI-compatible      ─┘     /v1/chat/completions          llama-server (router)
                                        web UI at /                   ├─ gemma-4-e2b  (fast)
                                                                      ├─ gemma-4-e4b  (smarter)
                                                                      ├─ more models: Qwen 3.5, Ministral 3, ...  (optional)
                                                                      └─ web_search, web_fetch tools (optional)
```

- [What you get and what to expect](#what-to-expect)
- [What makes this setup fast](#what-makes-this-setup-fast)
- [Step-by-step guide](#step-by-step) (about an hour, most of it waiting)
- [More models](#more-models) (Qwen, Ministral, Granite, LFM) · [Web search](#web-search)
- [Using the API](#using-the-api) · [iOS app](ios/README.md) · [Tuning](#tuning) · [Troubleshooting](#troubleshooting)

## What to expect

| | Gemma 4 E2B | Gemma 4 E4B |
|---|---|---|
| File (Q4_0, QAT) | 2.8 GB + 0.56 GB vision | 4.6 GB + 0.56 GB vision |
| Good for | quick answers, summaries, everyday chat | harder questions, better writing and reasoning |
| Generation speed on a Pi 5 | roughly 6-10 tokens/s | roughly 3-5 tokens/s |
| Inputs | text, photos, audio (experimental) | text, photos, audio (experimental) |

The speeds are estimates from the Pi 5's memory bandwidth and published reports, not measurements on your board. Run `./pi/bench.sh` after installing to get your real numbers. For reference, people read at roughly 5 tokens/s, so E2B feels fluid and E4B feels like someone typing fast.

Both models stay on the Pi, but only one sits in RAM at a time. You switch per chat in the web UI or the iOS app. The first reply after a switch waits while the other model loads: a few seconds from an NVMe SSD, up to about a minute from a microSD card.

**About the article you read:** it reports E4B "swapping" on an 8 GB Pi. With this setup E4B fits. In a test with exactly these settings, the E4B process used about 4 GB of its own memory. The rest of the model file is memory-mapped: Linux keeps the parts in use cached and can drop the rest. Gemma 4's sliding-window attention keeps the KV cache small (about 300 MB for 16K tokens), and the server's prompt cache is capped. The swapping in the article most likely came from a much larger context size or a runtime's default settings. The article is right that llama.cpp beats Ollama here: you control the build flags, the quantization and the memory settings directly.

## What makes this setup fast

1. **Native build for the Pi 5's Cortex-A76.** llama.cpp is compiled on the Pi with `GGML_NATIVE`, so it uses the CPU's NEON, `dotprod` and fp16 instructions.
2. **The right 4-bit format.** The models are the official `ggml-org` Q4_0 conversions of Google's *quantization-aware-trained* (QAT) checkpoints. QAT means Google trained the model to tolerate 4-bit weights, so it loses very little quality. Q4_0 is also the format llama.cpp repacks at load time into the layout its fastest ARM dotprod kernels use.
3. **Sane memory settings.** The context is fixed at 16K tokens instead of the model's 128K maximum, the prompt cache is capped at 1 GB (the default is 8 GB, your whole RAM), and only one model is loaded at a time.
4. **Thinking off by default.** Gemma 4 can reason before answering, which at Pi speeds adds about a minute per reply. You can switch it on per chat when you need it.
5. **Prompt caching and two parallel slots.** Follow-up messages reuse the already-processed conversation, and two people can chat at once at little extra cost.
6. **A pinned llama.cpp release.** The scripts build a llama.cpp version they were tested with (`b12032`), so an upstream change can't silently break your setup. Upgrading is one command.

## Step by step

### 0. Hardware

| Item | Why |
|---|---|
| Raspberry Pi 5, 8 GB | you have it |
| **Official Active Cooler** (about €5) | LLM inference keeps all 4 cores at 100 %. Without a fan the Pi throttles within minutes. |
| **Official 27 W USB-C power supply** (5 V / 5 A) | Weaker supplies cause under-voltage, which also throttles the CPU. |
| microSD card, 32 GB+, A2 class | Works fine. The model is read once into RAM, so the SD card only affects boot and model-switch time. |
| *Optional:* NVMe SSD on the M.2 HAT+ | Much faster boot and model switching (seconds instead of up to a minute). |
| *Recommended:* Ethernet cable | Steadier than Wi-Fi, and the Pi is easier to find on the network. |

Mount the Active Cooler before the first boot (it clips into the two holes next to the CPU and plugs into the 4-pin `FAN` connector).

### 1. Flash Raspberry Pi OS Lite (64-bit)

1. Install [Raspberry Pi Imager](https://www.raspberrypi.com/software/) on your computer.
2. Choose **Device: Raspberry Pi 5**, then **OS: Raspberry Pi OS (other) > Raspberry Pi OS Lite (64-bit)**. Lite has no desktop, which leaves more RAM for the model.
3. Choose your SD card (or NVMe drive), then **Edit settings**:
   - Hostname: `pi-llm`
   - Username and password of your choice
   - Wi-Fi, if you are not using Ethernet
   - **Services > Enable SSH** (password or, better, your public key)
4. Write the image, put the card in the Pi and power it on. The first boot takes a minute or two.

### 2. Log in and update

From your computer:

```bash
ssh <your-user>@pi-llm.local
```

On the Pi:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo rpi-eeprom-update -a     # latest bootloader/firmware
sudo reboot
```

The bootloader update matters: Raspberry Pi tuned the Pi 5's SDRAM timings in late-2024 firmware, worth [10-20 % on memory-bound work](https://www.jeffgeerling.com/blog/2024/raspberry-pi-boosts-pi-5-performance-sdram-tuning/), and token generation is memory-bound.

### 3. Install everything

SSH back in after the reboot, then:

```bash
sudo apt install -y git
git clone https://github.com/nicolaszimmer/pi-edge-ai.git
cd pi-edge-ai/pi
./install.sh
```

(If the repository is private, copy it over instead: `scp -r pi-edge-ai <your-user>@pi-llm.local:` from your computer.)

The installer:

1. installs the build tools,
2. builds llama.cpp natively in `/opt/pi-llm/llama.cpp` (expect 20+ minutes on the first build),
3. downloads both models to `/opt/pi-llm/models` and verifies their checksums (about 8.7 GB; use `MODELS=e2b ./install.sh` for E2B only),
4. creates a locked-down `llm` system user, the config in `/etc/pi-llm/` and a random API key,
5. installs and starts the `pi-llm` systemd service, which also starts at boot,
6. sends a test prompt and prints your URL and API key.

The end of the output looks like this:

```
All set!

  Web UI (any browser on your network):  http://pi-llm.local:8080   (or http://192.168.1.50:8080)
  OpenAI-compatible API base URL:        http://pi-llm.local:8080/v1
  API key:                               sk-pi-3f9c…
```

Keep the API key: every client needs it. You can read it again with `sudo cat /etc/pi-llm/api-keys`.

### 4. Chat in the browser

Open `http://pi-llm.local:8080` on any device in your network. The first time, the web UI asks for the API key. Then pick a model from the dropdown and start chatting. You can attach photos, and switch on thinking when a question needs reasoning.

**On your iPhone:** open the URL in Safari, then **Share > Add to Home Screen**. You get an app icon that opens the chat full-screen.

> If `pi-llm.local` doesn't resolve on a device, use the Pi's IP address, which `hostname -I` prints. Better: give the Pi a fixed IP in your router's DHCP settings.

### 5. Optional: the native iOS app

[`ios/`](ios/README.md) contains **Pi Chat**, a small SwiftUI app that streams replies, keeps every chat, renders Markdown and LaTeX maths, shows tokens/s, switches models and sends photos. You build it with Xcode on a Mac and install it on your phone with a free Apple ID. [Instructions here](ios/README.md).

### 6. Check speed and health

```bash
cd ~/pi-edge-ai/pi
./status.sh        # service, loaded model, temperature, throttling, memory
./bench.sh         # prompt and generation speed of each model through the API
./bench.sh raw     # llama-bench, 3 vs 4 threads (stops the service briefly)
```

If `status.sh` reports **under-voltage** or **soft temperature limit**, fix the power supply or the cooling first. Nothing else matters as much.

## More models

Besides the two Gemmas, the scripts know a few more small models from other makers. They are optional; add any of them to your running Pi with one command:

```bash
cd ~/pi-edge-ai && git pull
cd pi
./add-model.sh                    # lists the models you can add
./add-model.sh ministral-3-3b     # downloads it, adds it to the model menu, restarts the server
```

| Model ID | Maker | File (Q4_0) | Speed on a Pi 5 (estimate) | Photos | Good for |
|---|---|---|---|---|---|
| `qwen3.5-2b` | Alibaba | 1.2 GB + 0.67 GB vision | roughly like Gemma 4 E2B | yes | quick answers; sometimes skips the web tools and answers from memory |
| `qwen3.5-4b` | Alibaba | 2.6 GB + 0.67 GB vision | roughly like Gemma 4 E4B | yes | harder questions; very reliable with the web tools |
| `ministral-3-3b` | Mistral AI | 2.0 GB + 0.84 GB vision | between Gemma 4 E2B and E4B | yes | everyday chat in many languages; very reliable with the web tools; answers without a thinking step |
| `granite-4.2-3b` | IBM | 2.1 GB | between Gemma 4 E2B and E4B | no | reasoning when you switch thinking on; searches well, but rarely opens a page itself |
| `lfm2.5-8b-a1b` | Liquid AI | 4.8 GB | almost like Gemma 4 E2B | no | assistant tasks and tool use; very reliable with the web tools; always thinks first |

The speeds are estimates: generation speed on a Pi is limited by how many bytes of the model it reads per token, which is roughly the file size. LFM2.5 8B-A1B is the exception: it is a *mixture of experts* with 8.3B parameters, but only 1.5B of them work on each token, so it reads much less than its 4.8 GB file per token. `./bench.sh api <model-id>` gives you real numbers. Only one model sits in RAM at a time, so every extra model costs disk space, not memory.

**How they did in a short test** (llama-server b12032 with the web tools, the same five questions twice per model, on an x86 machine, not a Pi): Ministral 3 3B, LFM2.5 8B-A1B and Qwen 3.5 4B chose the right tool every time and answered correctly from a page they fetched; Gemma 4 E2B did in 9 of 10 cases. Granite 4.2 3B searched when it should, but when given a link it searched instead of opening the page. Ministral doesn't know today's date and sometimes puts an old year into its searches ("… 2024"). On the same machine, LFM2.5 generated at about 90 % of Gemma 4 E2B's speed, Ministral and Granite at about 60 %, Qwen 3.5 4B at about 40 %.

Good to know:

- **Thinking** is off by default for every model (`reasoning = off` in `models.ini`), and the web UI's thinking toggle switches it on per chat. The exception is **LFM2.5 8B-A1B**: it always thinks before answering, about 200 tokens even for a one-sentence reply. The web UI shows that thinking folded away, but on a Pi it can add half a minute to each reply.
- **Sampling:** each model's section in `models.ini` uses its maker's recommended settings, for example temperature 0.1 for Ministral and 1.0 for Granite.
- **Sources:** Qwen and Mistral publish no Q4_0 GGUF, so those files come from [Unsloth's conversions](https://huggingface.co/unsloth). IBM and Liquid AI publish their own. Q4_0 is used throughout because it is the fastest 4-bit format on the Pi 5's CPU. Only Gemma's files are quantization-aware trained, so the others lose a bit more quality at 4 bits.
- **Licences:** Gemma has Google's Gemma terms; Qwen, Ministral and Granite are Apache 2.0. LFM2.5 uses the LFM Open License, which is free for personal use and for companies under $10 million in annual revenue.
- **Bigger models don't fit well.** Qwen 3.5 9B, Ministral 3 8B and Granite 4.2 8B are about 5 GB at 4 bits and would run at around 2 tokens/s; Gemma 4 12B is 7 GB, too much next to the OS. Newer Qwen generations (3.6, 3.8) start at 27B.
- **New install with extra models from the start:** `MODELS="e2b e4b ministral-3-3b" ./install.sh` (`./download-models.sh --list` shows every name).
- **Remove a model:** delete its `[section]` from `/etc/pi-llm/models.ini`, run `sudo systemctl restart pi-llm`, and delete its files from `/opt/pi-llm/models`.
- **Any other GGUF model** works the same way: download the file to `/opt/pi-llm/models` and add a section with a `model = /opt/pi-llm/models/<file>.gguf` line to `/etc/pi-llm/models.ini`.

## Web search

Optional: the models get two tools, `web_search` (titles, links and snippets from a search engine) and `web_fetch` (reads one web page as text). The built-in web UI uses them on its own. Ask "What's the weather in Hamburg tomorrow?" and the model searches, reads a page or two and answers. In short tests, Gemma 4 E2B, Qwen 3.5 4B, Ministral 3 3B and LFM2.5 8B-A1B chose the right tool almost every time and left questions like "what is 17 × 23" alone ([details](#more-models)).

You need a search engine. Pick one:

| Engine | Cost (at the time of writing, check their sites) | What you need |
|---|---|---|
| [Tavily](https://tavily.com) | free plan: 1,000 searches a month | an account (email), no credit card |
| [Brave Search API](https://brave.com/search/api/) | a monthly free credit covers about 1,000 searches | an account; signing up may ask for a payment card |
| [SearXNG](https://docs.searxng.org) | free | no account; you run it yourself ([below](#searxng-on-the-pi)) |

Then, on the Pi:

```bash
cd ~/pi-edge-ai && git pull
cd pi
./web-search.sh on
```

It asks which engine to use and for its API key (or SearXNG's address), runs a test search, and restarts the server. The first time the model wants to search in the web UI, a permission card appears: allow it once, or choose **Always allow**. You can switch the tools off under **Settings > Tools**.

```bash
./web-search.sh off           # back to fully local, your key is kept
./web-search.sh setup         # switch to another search engine
./web-search.sh test "query"  # search once from the Pi, without the model
./web-search.sh status
```

What to know:

- **Privacy:** search queries go to the engine you picked, and the pages the model reads are fetched by the Pi. Your conversation itself stays on the Pi. With SearXNG your queries go to the search engines through your own server instead of an API account.
- **Speed:** a search result adds about 300 tokens to the prompt, a fetched page up to about 1,500. The Pi processes prompts at tens of tokens per second (`./bench.sh` shows "prompt t/s"), so reading a page can add half a minute or more. For faster, shallower reading, lower `WEB_FETCH_MAX_CHARS` in `/etc/pi-llm/web-search.env` and restart the service.
- **Small models still make mistakes,** with or without search results. When it matters, ask for the links and check them. In the same test, Qwen 3.5 2B sometimes answered from memory instead of opening a page it was given.
- **Safety:** `web_fetch` only opens public web addresses, never your router or other devices on your network. A web page can contain text aimed at the model; with only these tools available, the worst case is the model opening a page it shouldn't, and that page's address could carry bits of the chat. If that worries you, don't use **Always allow**, and look at each tool call before you approve it.
- **Browser access from other sites:** with tools enabled, llama-server only accepts browser requests from other web pages if they are served from localhost (CORS). The built-in web UI, the iOS app, curl and Python are not affected. Only a separate browser-based chat app on another address would be; allow it with `--cors-origins http://<its-address>` in `LLM_EXTRA_ARGS` in `/etc/pi-llm/server.env`.
- **Where it works:** in the built-in web UI, which runs the tool calls. API clients see the tools at `GET /tools` and can run them with `POST /tools` (llama.cpp marks this endpoint as internal, so it may change in newer versions). The iOS app doesn't use them yet.
- **More tools:** `/etc/pi-llm/mcp.json` is a standard MCP server list. Any stdio MCP server you add there shows up in the web UI the same way. It runs as the `llm` service user, so only add programs you trust.

### SearXNG on the Pi

SearXNG is an open-source meta-search engine that you host yourself. It needs a few hundred MB of RAM, which leaves enough for every model here. With Docker:

```bash
curl -fsSL https://get.docker.com | sh
sudo mkdir -p /etc/searxng /var/cache/searxng
sudo docker run -d --name searxng --restart unless-stopped -p 127.0.0.1:8888:8080 \
  -v /etc/searxng:/etc/searxng -v /var/cache/searxng:/var/cache/searxng \
  docker.io/searxng/searxng:latest
```

The web tool talks to SearXNG's JSON API, which is off by default. Open `/etc/searxng/settings.yml` (it appears after the first start), find `formats:` under `search:` and add `- json` below `- html`. Then run `sudo docker restart searxng`, and `./web-search.sh setup` (choose 3, address `http://127.0.0.1:8888`). The [SearXNG docs](https://docs.searxng.org/admin/installation-docker.html) cover other installation methods.

## Using the API

Any OpenAI-compatible client works. Use base URL `http://pi-llm.local:8080/v1`, your API key, and model `gemma-4-e2b` or `gemma-4-e4b` (or the ID of any [model you added](#more-models); `GET /v1/models` lists them).

```bash
curl http://pi-llm.local:8080/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model": "gemma-4-e2b",
       "messages": [{"role": "user", "content": "Give me three dinner ideas with leeks."}]}'
```

```python
# pip install openai
from openai import OpenAI

client = OpenAI(base_url="http://pi-llm.local:8080/v1", api_key="sk-pi-…")
stream = client.chat.completions.create(
    model="gemma-4-e4b",
    messages=[{"role": "user", "content": "Explain how a heat pump works, briefly."}],
    stream=True,
    # extra_body={"chat_template_kwargs": {"enable_thinking": True}},  # slower, smarter
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

Useful extras:

- **Images:** send OpenAI-style `image_url` content parts with a `data:image/jpeg;base64,…` URL. Smaller images are faster; about 1024 px is plenty.
- **Thinking:** add `"chat_template_kwargs": {"enable_thinking": true}`. The reasoning arrives separately in `reasoning_content`.
- **Speed info:** every response includes a `timings` object with prompt and generation tokens/s.
- `GET /v1/models` lists the models and shows which one is loaded.
- The server also speaks the Anthropic Messages API (`/v1/messages`), and other llama.cpp endpoints are documented [upstream](https://github.com/ggml-org/llama.cpp/tree/master/tools/server).

## Configuration

| File | What it controls |
|---|---|
| `/etc/pi-llm/models.ini` | models, context size, threads, sampling, thinking default, MTP |
| `/etc/pi-llm/server.env` | listen address and port, extra server flags |
| `/etc/pi-llm/api-keys` | API keys, one per line (add one per device if you like) |
| `/etc/pi-llm/web-search.env` | web search on/off, search engine and its API key (root-only, created by `./web-search.sh`) |
| `/etc/pi-llm/mcp.json` | tool servers llama-server starts when web search is on |

After a change: `sudo systemctl restart pi-llm`. Logs: `journalctl -u pi-llm -f`.

Re-running `./install.sh` is safe: it never overwrites your edited config. It writes the new default next to it as `*.new`.

**Update llama.cpp** (new optimizations land often):

```bash
cd ~/pi-edge-ai/pi
LLAMA_REF=b12345 ./build-llama.sh   # a tag from github.com/ggml-org/llama.cpp/releases
sudo systemctl restart pi-llm
./bench.sh                          # did it get faster?
```

If a new version misbehaves, run `./build-llama.sh` without `LLAMA_REF` to go back to the tested one.

## Tuning

Measure before and after each change with `./bench.sh`.

| Idea | How | Notes |
|---|---|---|
| Threads | `threads = 3` in `models.ini` | 4 is usually best on a dedicated Pi. Try 3 if other services run on it. `./bench.sh raw` compares both. |
| Arm KleidiAI kernels | `KLEIDIAI=ON ./build-llama.sh`, then restart | Extra ARM micro-kernels. Can help prompt processing; benchmark it. |
| MTP speculative decoding | uncomment `spec-type` / `model-draft` in `models.ini` | Uses Gemma's multi-token-prediction head to draft tokens. On an x86 test machine it made generation **slower**: only about 20 % of drafted tokens were accepted. Try it on your Pi, but don't expect much. |
| Save RAM | remove the `mmproj` line of a model | No photo input, about 0.6 GB less RAM and faster loading. |
| Bigger context | `ctx-size = 32768` | Memory is fine (E4B: about 0.6 GB of KV cache), but long prompts take minutes to process on a Pi. |
| Overclock | `arm_freq=2800` in `/boot/firmware/config.txt` | Only with the Active Cooler. Helps prompt processing more than generation, which is limited by memory bandwidth. At your own risk; check stability with `./bench.sh`. |
| Free RAM when idle | `LLM_EXTRA_ARGS=--sleep-idle-seconds 1800` in `server.env` | Unloads the model after 30 min idle; the next request reloads it. |

## Away from home

Don't forward the port on your router: the server is meant for a trusted network. To reach it from your phone on the go, install [Tailscale](https://tailscale.com/download) on the Pi and the phone:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Then use `http://pi-llm:8080` (MagicDNS) from anywhere. `sudo tailscale serve --bg 8080` additionally gives you an HTTPS URL (`https://pi-llm.<your-tailnet>.ts.net`).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `pi-llm.local` not found | Use the IP address (`hostname -I` on the Pi). Some Android and older Windows devices don't resolve `.local` names. |
| `401 Invalid API Key` | The key must match a line in `/etc/pi-llm/api-keys`, sent as `Authorization: Bearer <key>`. |
| `model 'x' not found` | The `model` field must be one of the IDs from `GET /v1/models`, e.g. `gemma-4-e2b`. |
| The model doesn't search | Is it on? `./web-search.sh status` should list `web_search web_fetch`. Then reload the web UI and check **Settings > Tools**. Asking "search the web for …" also helps small models. |
| `web search is not set up` or `rejected the API key` | Run `./web-search.sh setup` and enter the key again; `./web-search.sh test` shows the engine's answer. |
| First reply takes long | The model is loading (after boot or a model switch). `./status.sh` shows its status. |
| Slow, getting slower | `./status.sh`: look for throttling. Check the cooler, then the power supply. |
| Service won't start | `journalctl -u pi-llm -n 100 --no-pager` usually says why, often a wrong path in `models.ini`. |
| Replies are empty but tokens were generated | Thinking is on and `max_tokens` ran out during reasoning. Raise `max_tokens` or turn thinking off. |

## Repository layout

```
pi/
  install.sh          one-shot installer (build, models, service, config)
  build-llama.sh      build or update llama.cpp natively (pinned release)
  download-models.sh  fetch and checksum-verify the GGUFs (Gemma 4, Qwen 3.5, Ministral 3, Granite 4.2, LFM2.5)
  add-model.sh        add a model to an installed server
  models.ini          model presets (installed to /etc/pi-llm/)
  server.env          listen address, port, extra flags (installed to /etc/pi-llm/)
  pi-llm.service      hardened systemd unit
  web-search.sh       switch web search on or off, pick the search engine
  web-search-mcp.py   the web_search / web_fetch tools (MCP server, Python, no dependencies)
  web-search.env      web search settings template (installed to /etc/pi-llm/)
  mcp.json            tool server list for llama-server (installed to /etc/pi-llm/)
  common.sh           helpers shared by the scripts
  test-api.sh         smoke test: health, models, one chat completion
  bench.sh            speed benchmark (API or raw llama-bench)
  status.sh           health report: service, temperature, throttling, memory
ios/
  PiChat/             SwiftUI app sources
  project.yml         XcodeGen project spec
```

## Uninstall

```bash
sudo systemctl disable --now pi-llm
sudo rm -rf /etc/systemd/system/pi-llm.service /etc/pi-llm /opt/pi-llm /var/lib/pi-llm /var/cache/pi-llm
sudo userdel llm
```
