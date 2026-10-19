## Download

- **`Vision.dmg`** — open it and drag **Vision** into **Applications**. Every
  release is at https://github.com/phastings503cm/vision-mac/releases (0.15.x
  builds were published from an older repository; from 0.16.0 they are all
  here).

Builds are ad-hoc-signed for Apple Silicon (arm64), macOS 14+. Gatekeeper will
prompt on first launch — right-click the app and choose **Open**, or run:

```bash
xattr -d com.apple.quarantine /Applications/Vision.app
```

## What's new in 0.16.5 — your chats from Claude Code, Codex, OpenClaw, Claude.ai, ChatGPT and Guardian

- **Import Chats.** **File ▸ Import Chats…** (⇧⌘I) brings in your conversations from **Claude Code**, **Codex**,
  **OpenClaw**, a **Claude.ai** or **ChatGPT** data export (the ZIP, its folder or `conversations.json`), a Vision
  chat file, and — signed in — your **Guardian** chats and the Vision chats your account keeps there. Tick some or
  all; every message keeps its time, tool calls come in as tool cards, and a chat whose folder is on this Mac opens
  in that project. Carry any of them on with any model — a Claude Code session can continue on Bedrock, Guardian or
  your own hardware. Importing again brings only what's new, and a chat you already have (here, or the same one
  Guardian imported) shows as imported. Reading changes nothing in the other tools.
- **Export a chat.** **File ▸ Export Chat ▸ Markdown… / JSON…** (or the chat's right-click menu). The JSON imports
  back into Vision on any computer, Mac or Windows. **Send Chat to Guardian** keeps it with your account, masked
  first like the prompts Guardian's notebook gets; an open chat's plan goes along as a checklist, and a Sensitive
  chat stays Sensitive when it comes back.
- **Search all chats.** The field above the chat list (⇧⌘F) finds every word of a search in titles, prompts,
  answers and tool calls across every chat, made here or imported; narrow it to one source, and click a result to
  open the chat at that row.

## What's new in 0.16.4 — MCP servers, undo a turn's file changes, and Sensitive chats

- **MCP servers.** **Settings ▸ MCP Servers** connects Vision to Model Context Protocol servers — a program it
  starts, or a URL — and their tools join every chat. **Import** brings in the servers you already set up in
  Claude Code, Claude Desktop and Cursor. Keys and tokens go into the Keychain, not the settings file. Every call
  asks first unless you trust the server; `/mcp` lists them in a chat. A project's own servers arrive switched
  off, showing exactly what they run, until you turn them on.
- **See and undo what a turn changed.** When a turn ends, **Files changed (N)** lists the files the agent wrote —
  with its shell commands' changes too, in a git repository — and shows each one's diff. **Rewind this turn…** puts
  them back as they were and removes the files it created; it says first which ones changed again since, and leaves
  alone a file that changes while you decide. `/rewind` or **Session ▸ Rewind…** lists the chat's recent turns; an
  older turn's changes are also under its prompt in **Prompts**. The model is told which files went back.
- **Sensitive chats.** Mark a chat **Sensitive** (the menu under the composer, **Session ▸ Sensitive Chat** or
  `/sensitive on`) and it talks only to private models — your own hardware, Guardian, Amazon Bedrock in your AWS
  account — or to other models only through the shield, which masks what it detects before sending. Claude Code,
  which reads your files itself, is never used for it. The strip at the top says what that means for the chat's
  model, the model menu greys out the ones it can't use, and its backups, subagents, `/compact`, skills written
  from it and tasks it queues follow the same rule. A project can start all its chats Sensitive.

## What's new in 0.16.3 — DeepSeek, Claude with an API key, and Guardian's models in every chat

- **DeepSeek has its own card.** Choose **DeepSeek — API key** in the wizard (or **Settings ▸ AI Models ▸ Add ▸
  DeepSeek…**), paste a key from platform.deepseek.com, and pick **V4 Pro** or **V4.1 Flash** — both with a 1M
  context. The thinking menu (Off, Low, High, Max) and tools work; a refused key or an empty balance is said in
  plain words instead of retried. DeepSeek's servers are in China, so the route starts out not private and the
  shield masks sensitive details before sending.
- **Claude with an Anthropic API key.** **Anthropic API (Claude) — API key** in the wizard (or **Add ▸ Anthropic
  API (key)…**) talks to Claude directly: streaming, tools, pictures, PDFs, thinking, prompt caching, and
  Anthropic's hand-over to another Claude model when one declines, with a line saying so. Paste a Claude Pro or
  Max sign-in token by mistake and the guide tells you it isn't an API key.
- **Guardian's models are in every chat's model menu.** Signed in to Guardian, its models appear by themselves
  under **Guardian** in each chat's menu — no button to press. The list is read at launch, at sign-in, on an
  organization switch, every 15 minutes and by **Settings ▸ Guardian ▸ Refresh**. Sign out and they leave the
  menus; a chat that was on one says *Sign in to Guardian to use this model.* and works again as soon as you sign
  back in. The **Use Guardian's Models** button is gone.
- Guardian routes no longer ask for model-server details before every turn, and the badges under a sent message
  say exactly how each file went — "sent as text" when a request is past Anthropic's room for pictures and PDFs.

## What's new in 0.16.2 — copy any prompt, long chats load a page at a time

- **Copy any prompt or reply.** Hover a message for its copy button, right-click it for **Copy Prompt** or **Copy
  Reply**, or click it and press **⇧⌘C**. A prompt copies exactly as you sent it, a big paste included; the Prompts
  timeline has the same button on every row.
- **Long chats open fast and stay put.** The transcript shows the newest 50 messages. **Load earlier messages** at
  the top (or just scrolling up to it) adds the ones before, and what you were reading stays where it is.
- **New output follows you only while you're at the end.** Scroll up to read and nothing moves under you; **Latest**
  brings you back.
- **Jump from Prompts finds any prompt**, however far back: the chat loads the messages around it and flashes it.
- **Very long messages fold.** Anything over 40 lines shows its first lines with **Show more**; a huge one opens in
  its own scrolling box.

## What's new in 0.16.1 — fixes from the 0.16.0 review

- **Signing in to Guardian again renews the Guardian model routes too**, and signing out clears them, so chats on
  Guardian's models stop failing with "sign in again" after you did. Settings ▸ Guardian has **Use Guardian's Models**.
- **A `/goal` with a big paste starts a goal** (the paste goes with its first round) — also when queued or re-sent.
- **Stop (⌘. or ⌃⌥⌘.) ends typing that is already going out**, and subagents driving the Mac light the glow and are
  stopped by ⌃⌥⌘. too.
- **Exporting keys to OpenClaw never writes Guardian's run-only secrets** to `~/.openclaw/.env`.
- **Download a Copy from Guardian** goes into a new folder and never writes outside it.
- The Task Queue panel shows only the unattended queue; deleting a chat task removes its saved attachments; Guardian's
  background syncs no longer pop the refusal dialog; the browser sign-in page escapes the error text it shows.

## What's new in 0.16.0 — each chat its own model, files that just work, and you can see what runs where

- **Each chat keeps its own model.** Pick a model in a chat's menu and only that
  chat changes — two projects open at once each talk to their own server, with
  their own retries, `/goal` rounds, compaction and subagents. A new chat starts
  with what its project's chats last used; **Make This the Primary** is explicit.
- **Kimi and Z.ai (GLM) work.** Each model gets only the parameters it takes
  (Kimi K2.6/K2.7's fixed temperature, GLM-5.3's thinking levels, Kimi's
  reasoning sent back with tool calls). A server that refuses a parameter gets
  it dropped and remembered, with one grey line in the chat instead of a failed
  turn — never the messages, tools or model. **Z.ai (GLM)** is a first-class
  choice with an endpoint picker (Coding Plan or General API, global or China)
  and a **Test** that names the fix ("This looks like a GLM Coding Plan key —
  switch the endpoint to Coding Plan"); its balance and plan errors say so in
  plain words instead of retrying for ever.
- **PDFs, Markdown, Word, Excel and pictures in any chat.** Vision reads
  attachments itself — PDF text (scans by OCR), Office files, rich text, the text
  in a picture — and sends what the model can take: a model server never gets a
  part it refuses ("file type not supported" is gone). A file too long for the
  context window goes in parts the model reads with `read_attachment`. Chips say
  how each file goes ("PDF · 40 pages · sent as text in 3 parts").
- **Huge pastes.** A paste over 400 lines or 20,000 characters becomes a
  "Pasted text" chip you can open and edit, the message box stays responsive,
  long messages collapse in the transcript with **Show all**, and the transcript
  scrolls freely. `/goal` with a big paste runs as a goal, the paste going with
  its first round (sent, queued or sent again from Prompts).
- **Prompts.** ⇧⌘H shows every prompt a chat sent and how it ended — completed,
  finished with issues, needs you, failed, stopped — with its duration against
  the estimate, the model it ran on and its evidence; **Copy**, **Add to
  composer**, **Jump** and **Results** on each. ⌥⇧⌘H searches every chat. Kept
  on disk; older chats are filled in from their transcripts.
- **Tasks: the current work first, then what's queued.** ⇧⌘P shows the chat's
  running `/goal` or prompt as its first task with its plan and the subagents on
  each step. Press ↩ while the agent works (or ⌘↩ any time) to add the draft —
  attachments and big pastes included — to the chat's tasks; they start by
  themselves, in order, and you can reorder, edit, pause and run them again.
- **A goal fixes what validation finds.** When a `/goal` says it's done but its
  closing words report an error, it goes back to fix it — no retry cap by
  default; it stops when two attempts in a row get nowhere.
- **Background activity.** The bolt in the toolbar (⌥⌘A) lists every chat's
  main agent and subagents with the model and server each runs on, what it was
  given, its plan step, its log and its tokens. Subagents on another server now
  use that server's own settings, and a hosted subagent server is used even when
  its key can't list models.
- **Code mode puts the chat first.** Toggle the file tree (⌘B), editor (⌥⌘E) and
  terminal (⌃\`), or **Chat and Project Status Only** (⌥⌘↩): the chat in the
  middle with the branch, changes, plan and what's queued beside it. Opening a
  file brings the editor back.
- **Screen control takes turns.** Clicks and typing go through Accessibility or
  straight to the target app first, so your mouse stays yours; when a chat needs
  the real mouse it waits its turn (and for you to stop moving it), the glow's
  pill says who has it, and ⌃⌥⌘. stops every chat at once — subagents included,
  in the foreground or the background, and typing stops mid-text. `/control
  only <App>` limits a chat to the apps it opened.
- **Import & Export with OpenClaw.** Settings ▸ Import & Export brings the local
  OpenClaw's skills, memory, keys and model servers into Vision, and sends
  Vision's back (keys only after you confirm; Guardian secrets used for this
  run never leave memory).
- **Guardian sign-in, finished.** Sign in through the browser (Entra SSO,
  passwordless), pick the organization, see your limits and when they reset,
  use your "Usable in Vision" vault secrets, and upload or download code
  projects (never `.env` files or keys; a copy goes into a new folder, never over
  one that is there). Signing in again renews Guardian's models too, and **Use
  Guardian's Models** adds them after a browser sign-in. A refusal is a dialog
  that says what is missing and who can grant it (background syncs stay quiet). Prompts go to your Guardian notebook masked
  (vault secrets always, and what the sensitive-data shield masks), with how
  they ended — or switch that off in Settings ▸ Guardian.

## 0.15.0 — the app is now called Vision

<!-- The one place these notes name the app's old name (users need to recognise it); keep it to this sentence. -->
Vision was previously called DSH: the first launch of Vision brings its chats, settings, keys and vault over, so there is nothing to set up again.

- **Moving over.**
  - Quit the old app before you open Vision the first time. If it is still
    open, Vision offers to quit it for you, and changes nothing until it has.
  - macOS keeps its permissions per app, so it asks again for **Screen
    Recording**, **Accessibility** and **Automation** the first time Vision
    needs each one (System Settings ▸ Privacy & Security). It may also ask once
    to let Vision use each key in your Keychain: choose **Always Allow**.
  - Vision keeps its data in `~/Library/Application Support/Vision`. It copies
    the old app's folder there and checks the copy before using it. The old
    folder stays where it was, with a note inside saying where its data went:
    delete it, and the old app in Applications, once you're happy.
  - Projects keep working: the old project folder for skills, agents and
    plugins, and the old instructions file, are still read. New ones go in
    `.vision/` and `VISION.md`.
  - New Amazon Bedrock sign-ins use the AWS profile `vision-bedrock`; models
    you already set up keep the profile they have.
- **The keyboard tool presses the keys it's asked for.** Several letters were
  mapped to the wrong keys (q to p, g and h, j to l) — ⌘T pressed ⌘⌫. Combos
  accept `cmd+s` as well as `cmd,s`, the punctuation keys and F13–F20 work,
  and a misspelt modifier is an error instead of being dropped. One bad combo
  fails the whole call before any key is pressed.
- **The keyboard guard knows the app itself.** It refuses to type into Vision
  by its process, bundle id and executable, not only by the app's name, and it
  refuses when macOS won't say which app is in front (grant Automation) instead
  of typing blind.
- `process_write` with `ctrl-z` sends ^Z instead of pressing Enter.

## Also new since 0.13.0 — connect a Swapper with one code, subscription plans, private models

- **Connect a Spark Swapper with one code.** Copy the connection code from the
  Swapper's Connect tab (Swapper 2.0, on a DGX Spark or a Strix Halo) and
  choose **My Spark Swapper** in the setup wizard. Vision checks the box's
  certificate against the code, shows what it serves with each model's context
  and speed, can switch models or install one the box hasn't downloaded, and
  saves the route with the certificate pinned and an app token in your
  Keychain — your Swapper password isn't kept. Older Swappers still connect
  with an address and login.
- **Several Swapper boxes.** **Settings ▸ Model Servers** lists every box — what
  it serves, its models installed or not (**Install on <box>**), its
  certificate — and the model menu has a section per box. `/swap` lists every
  box's models and switches the box behind the primary, or the one you name.
  Your existing Spark setup is carried over.
- **Subscription plans: GLM, Kimi, Qwen, OpenAI.** A guide for Z.ai's GLM
  Coding Plan and API, Kimi Code and the Moonshot API, Alibaba Cloud's Qwen
  Coding Plan and Model Studio, and the OpenAI API: where to get the key, a
  check with errors in plain words, the plan's models, done. GLM-5.3's
  always-on thinking is handled, Vision identifies itself honestly to Kimi, and
  the Qwen Coding Plan is marked *interactive use only*, so the queue and
  `/goal` won't run on it.
- **The AI roster.** **Settings ▸ AI Models** has a row per model with
  switches for On, Primary, Subagent, Backup and Private, and the model menu
  groups them the same way. A **backup** takes over a turn when the primary
  doesn't answer, and the chat says so.
- **Private models and the sensitive-data shield.** Models on your own network
  are private; online services aren't. Before anything goes to a model that
  isn't private, Vision swaps keys, passwords, emails, phone numbers, ID and card
  numbers and your own custom terms for placeholders, and puts the real values
  back as the answer arrives — a shield on the reply says what was masked.
  Tasks marked `sensitive` run only on a private subagent server. Choose what
  counts, and try it, in Settings ▸ AI Models ▸ Sensitive data.
- **The plan panel.** ⇧⌘P (or the checklist button) shows the selected chat's
  goal, steps, proposed plan and running subagents beside the chat, in both
  modes. It opens by itself when the agent makes a plan.
- **Chats without a project are just chats.** No more asking for a folder: a
  chat without a project is a regular conversation, with your own instructions
  and skills, and a folder of its own for any files. **New Chat Without a
  Project** (⇧⌘N) starts one even while a project is open.
- Any route can trust a self-signed server by its certificate's fingerprint
  (Settings ▸ AI Models ▸ Edit).

## Earlier

- **0.13.0** — several model servers at once (subagents on a second Spark or
  Bedrock, **Make Main**, **Test All**) and Amazon Bedrock, with a guide for
  people new to AWS.
- **0.12.0** — background subagents and background tasks: `agent` with
  `run_in_background` (up to four per chat, `agent_status` / `agent_stop`, an
  idle chat picks the work back up), a bar above the composer, and
  `queue_task` for unattended follow-up work.
- **0.11.0** — the Credentials Vault: API keys and passwords in the Keychain that
  the agent uses as `{{vault:NAME}}` without ever seeing them.
- **0.10.0** — the queue works unattended: model outages retry until the model
  is back, `/goal` runs with no round cap until the model says it's done, and
  a long list of Task Queue fixes.
- **0.9.0** — the Task Queue: queue up work and let the harness run it
  unattended, one task at a time, with a timestamped log.

- **0.8.1** — SGLang 400 fix: tool parameter schemas are always valid JSON
  objects (five specs shipped corrupted in 0.8.0).
- **0.8.0** — Interact with live processes and the machine: `process_*` tools
  (start/read/write/stop/list with streaming, until-matching, named keys),
  `screenshot` / `list_windows` / `screen_watch` / `ui_tree` /
  `inspect_process` / `mouse` / `keyboard` / `focus_app` / `view_image`, and
  the baked-in godot-debugging skill.
- **0.7.0** — Skills: generate, approve, import, export, per-chat selection.
