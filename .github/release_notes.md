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
  scrolls freely.
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
  pill says who has it, and ⌃⌥⌘. stops every chat at once. `/control only <App>`
  limits a chat to the apps it opened.
- **Import & Export with OpenClaw.** Settings ▸ Import & Export brings the local
  OpenClaw's skills, memory, keys and model servers into Vision, and sends
  Vision's back (keys only after you confirm).
- **Guardian sign-in, finished.** Sign in through the browser (Entra SSO,
  passwordless), pick the organization, see your limits and when they reset,
  use your "Usable in Vision" vault secrets, and upload or download code
  projects (never `.env` files or keys). A refusal is a dialog that says what is
  missing and who can grant it. Prompts go to your Guardian notebook masked
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
