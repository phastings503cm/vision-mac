import Foundation

/// Claude Code stream-json and CLI output for the tests.
///
/// REAL (captured once, 2026-10-19, from Claude Code 2.1.299 — the copy the Claude desktop app keeps on this Mac):
/// `notLoggedIn` is what `claude -p --output-format stream-json --verbose --max-turns 1` printed with no sign-in on
/// this Mac (paths changed to /tmp/project and /Users/me), and `help` is that CLI's `claude --help`. No signed-in
/// claude CLI was available here, so no real model turn could be captured.
///
/// SCHEMA-BUILT: every other turn is built strictly from Claude Code's documented stream-json schema (the Agent SDK
/// message types: system/init, stream_event, assistant, user tool_result + tool_use_result, system/api_retry,
/// compact_boundary, status, informational, permission_denied, rate_limit_event, control_request can_use_tool,
/// result) and from the shapes of real Claude Code transcripts on disk
/// (one content block per assistant message, tool_result content as a string or text blocks, `Write`'s
/// tool_use_result `type: "create"`).
enum ClaudeCodeFixtures {
    static let sessionID = "4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d"

    static let notLoggedIn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"75eaed3b-8da5-4492-8a96-9893fcfccdac","tools":["Task","Bash","CronCreate","CronDelete","CronList","DesignSync","Edit","EnterWorktree","ExitWorktree","ListAgents","Monitor","NotebookEdit","PushNotification","Read","ReportFindings","ScheduleWakeup","SendMessage","Skill","TaskStop","ToolSearch","WebFetch","WebSearch","Workflow","Write"],"mcp_servers":[],"model":"claude-haiku-5-5","permissionMode":"default","slash_commands":["deep-research","design","design-sync","dataviz","update-config","verify","debug","code-review","simplify","batch","fewer-permission-prompts","doctor","loop","claude-api","workflow-authoring","run","run-skill-generator","plugin-authoring","advisor","agents","auto-mode-setup","autocompact","clear","color","compact","config","output-style","context","effort","fast","focus","heapdump","init","mcp","import","model","__remote-workflow","workflow-launch-exec","reload-plugins","reload-skills","rename","security-review","usage","insights","recap","skill-doctor","goal","design-consent","design-revoke","list-agents","team-onboarding"],"terminal_slash_commands":["doctor","color","focus","reload-plugins"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":["claude","Explore","general-purpose","Plan","statusline-setup"],"skills":["deep-research","design","design-sync","dataviz","update-config","verify","debug","code-review","simplify","batch","fewer-permission-prompts","doctor","loop","claude-api","workflow-authoring","run","run-skill-generator","plugin-authoring"],"plugins":[{"name":"cc-plugin-agents-md","path":"builtin","source":"cc-plugin-agents-md@builtin"},{"name":"cc-plugin-telemetry","path":"builtin","source":"cc-plugin-telemetry@builtin"},{"name":"cc-plugin-plugin-authoring","path":"builtin","source":"cc-plugin-plugin-authoring@builtin"}],"capabilities":["interrupt_receipt_v1","interrupt_cancel_queued_v1","interrupt_send_now_v1","msg_lifecycle_v1","request_marker_lists_v1","sdk_mcp_tools_list_changed","sdk_mcp_manifests","mcp_read_resource_v1","mcp_tool_ui_meta_v1","ui_surface_v1"],"analytics_disabled":false,"product_feedback_disabled":false,"uuid":"b200d31f-9882-4f29-86d3-52553fb8c90a","memory_paths":{"auto":"/Users/me/.claude/projects/-tmp-project/memory/"},"messaging_socket_path":"/tmp/cc-socks/20540.sock","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","per_turn_effort_active":true,"view_mode":"default"}
{"type":"assistant","message":{"diagnostics":null,"id":"81b4619d-ab4d-4f49-9dc7-765e3c72539e","container":null,"model":"<synthetic>","role":"assistant","stop_details":null,"stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"output_tokens_details":null,"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":null,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":null,"iterations":null,"speed":null,"fallback_credit":null},"content":[{"type":"text","text":"Not logged in · Please run /login"}],"context_management":null},"parent_tool_use_id":null,"session_id":"75eaed3b-8da5-4492-8a96-9893fcfccdac","uuid":"ebeba5da-bd12-4934-ac14-51b8174c14eb","timestamp":"2026-10-19T18:36:11.860Z","error":"authentication_failed","is_api_error_message":true}
{"duration_api_ms":0,"stop_reason":"stop_sequence","session_id":"75eaed3b-8da5-4492-8a96-9893fcfccdac","total_cost_usd":0,"usage":{"output_tokens_details":{"thinking_tokens":0},"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":"","iterations":[],"speed":"standard","fallback_credit":null},"modelUsage":{},"permission_denials":[],"terminal_reason":"api_error","fast_mode_state":"off","fast_mode_disabled_reason":"sdk_opt_in_required","subagent_stats":{"spawned":0,"requested":{"background":0,"foreground":0,"unset":0},"started_in_background":0,"max_depth":0,"spawned_by_subagents":0,"completed":0,"failed":0,"killed":{"parent":0,"user":0,"system":0},"refused":{"depth_limit":0,"concurrency_limit":0,"budget":0},"by_type":{}},"safety_stops":0,"is_error":true,"num_turns":1,"subtype":"success","api_error_status":null,"result":"Not logged in · Please run /login","type":"result","duration_ms":201,"uuid":"198459c4-4a95-45e3-b6f6-cffd23db0c33","queued_turn_count":0,"result_index":0}
"""#

    static let help = #"""
Usage: claude [options] [command] [prompt]

Claude Code - starts an interactive session by default, use -p/--print for
non-interactive output

Arguments:
  prompt                                Your prompt

Options:
  --add-dir <directories...>            Additional directories to allow tool
                                        access to
  --agent <agent>                       Agent for the current session. Overrides
                                        the 'agent' setting.
  --agents <json-or-file>               JSON object defining custom agents, or
                                        with --print the path to a file that
                                        holds one (e.g. '{"reviewer":
                                        {"description": "Reviews code",
                                        "prompt": "You are a code reviewer"}}')
  --allow-dangerously-skip-permissions  Enable bypassing all permission checks
                                        as an option, without it being enabled
                                        by default. Recommended only for
                                        sandboxes with no internet access.
  --allowedTools, --allowed-tools <tools...>
      Comma or space-separated list of tool names to allow (e.g. "Bash(git *)
      Edit")
  --append-system-prompt <prompt>       Append a system prompt to the default
                                        system prompt
  --autocompact <auto|tokens>           Auto-compact window size (auto, or
                                        100k–1M tokens)
  --ax-screen-reader                    Render screen-reader friendly output
                                        (flat text, no decorative borders or
                                        animations).
  --bg, --background                    Start the session in the background and
                                        return immediately. Prints the id that
                                        `claude attach`, `logs`, `stop` and `rm`
                                        take; `claude agents` lists them. With
                                        --resume <session-id>, continues that
                                        session in the background under the same
                                        ID, or starts a copy and says so when
                                        the session is already running
  --bare                                Minimal mode: skip hooks (those defined
                                        in settings and by installed plugins;
                                        features built into Claude Code are
                                        unaffected), LSP, plugin sync,
                                        attribution, auto-memory, background
                                        prefetches, keychain reads, and
                                        CLAUDE.md auto-discovery. Sets
                                        CLAUDE_CODE_SIMPLE=1. Anthropic auth is
                                        strictly ANTHROPIC_API_KEY or
                                        apiKeyHelper via --settings (OAuth and
                                        keychain are never read). 3P providers
                                        (Bedrock/Vertex/Foundry) use their own
                                        credentials. Skills still resolve via
                                        /skill-name. Explicitly provide context
                                        via: --system-prompt[-file],
                                        --append-system-prompt[-file], --add-dir
                                        (CLAUDE.md dirs), --mcp-config,
                                        --settings, --agents, --plugin-dir.
  --betas <betas...>                    Beta headers to include in API requests
                                        (API key users only)
  --brief                               Enable SendUserMessage tool for
                                        agent-to-user communication
  --chrome                              Enable Claude in Chrome integration
  --cloud [description|session_id|url]  Create a cloud session with the given
                                        description, or attach to an existing
                                        one by session ID or claude.ai/code URL
  -c, --continue                        Continue the most recent conversation in
                                        the current directory
  --dangerously-skip-permissions        Bypass all permission checks.
                                        Recommended only for sandboxes with no
                                        internet access.
  -d, --debug [filter]                  Enable debug mode with optional category
                                        filtering (e.g., "api,hooks" or
                                        "!1p,!file")
  --debug-file <path>                   Write debug logs to a specific file path
                                        (implicitly enables debug mode)
  --desktop                             Open in the Claude Desktop app instead
                                        of the terminal (with --continue or
                                        --resume <id> to pick the session)
  --disable-slash-commands              Disable all skills
  --disallowedTools, --disallowed-tools <tools...>
      Comma or space-separated list of tool names to deny (e.g. "Bash(git *)
      Edit")
  --effort <level>                      Effort level for the current session
                                        (low, medium, high, xhigh, max)
  --environment <environment_id>        Create a new cloud session that runs on
                                        the given self-hosted environment
                                        (ccpool_...).
  --exclude-dynamic-system-prompt-sections
      Move per-machine sections (cwd, env info, memory paths, git status) from
      the system prompt into the first user message. Improves cross-user
      prompt-cache reuse. Only applies with the default system prompt (ignored
      with --system-prompt). (default: false)
  --fallback-model <model>              Enable automatic fallback to specified
                                        model(s) when the default model is
                                        overloaded or not available. Accepts a
                                        comma-separated list to try each in
                                        order. Re-tries the primary at the start
                                        of each user turn.
  --file <specs...>                     File resources to download at startup.
                                        Format: file_id:relative_path (e.g.,
                                        --file file_abc:doc.txt
                                        file_def:img.png)
  --fork-session                        When resuming, create a new session ID
                                        instead of reusing the original (use
                                        with --resume or --continue)
  --forward-subagent-text               Forward subagent text and thinking
                                        blocks as assistant/user messages with
                                        parent_tool_use_id set (only works with
                                        --print and --output-format=stream-json)
  --from-pr [value]                     Resume a session linked to a PR by PR
                                        number/URL, or open interactive picker
                                        with optional search term
  -h, --help                            Display help for command
  --ide                                 Automatically connect to IDE on startup
                                        if exactly one valid IDE is available
  --include-hook-events                 Include all hook lifecycle events in the
                                        output stream (only works with
                                        --output-format=stream-json)
  --include-partial-messages            Include partial message chunks as they
                                        arrive (only works with --print and
                                        --output-format=stream-json)
  --input-format <format>               Input format (only works with --print):
                                        "text" (default), or "stream-json"
                                        (realtime streaming input) (choices:
                                        "text", "stream-json")
  --json-schema <schema>                JSON Schema for structured output
                                        validation. Example:
                                        {"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
  --max-budget-usd <amount>             Maximum dollar amount to spend on API
                                        calls (only works with --print)
  --mcp-config <configs...>             Load MCP servers from JSON files or
                                        strings (space-separated)
  --model <model>                       Model for the current session. Provide
                                        an alias for the latest model (e.g.
                                        'fable', 'opus', or 'sonnet') or a
                                        model's full name.
  -n, --name <name>                     Set a display name for this session
                                        (shown in the prompt box, /resume
                                        picker, and terminal title)
  --no-chrome                           Disable Claude in Chrome integration
  --no-session-persistence              Disable session persistence - sessions
                                        will not be saved to disk and cannot be
                                        resumed (only works with --print)
  --output-format <format>              Output format (only works with --print):
                                        "text" (default), "json" (single
                                        result), or "stream-json" (realtime
                                        streaming) (choices: "text", "json",
                                        "stream-json")
  --permission-mode <mode>              Permission mode to use for the session
                                        (choices: "acceptEdits", "auto",
                                        "bypassPermissions", "manual",
                                        "dontAsk", "plan")
  --permission-prompts <target>         Who answers permission prompts with
                                        --print: "host" (the SDK host or
                                        --permission-prompt-tool) or "none"
                                        (nobody: anything that would prompt is
                                        denied automatically; the permission
                                        mode still decides everything else)
                                        (choices: "host", "none", default:
                                        "host")
  --plugin-dir <path>                   Load a plugin from a directory or .zip
                                        for this session only; a folder of
                                        plugins loads each child (repeatable:
                                        --plugin-dir A --plugin-dir B.zip)
                                        (default: [])
  --plugin-url <url>                    Fetch a plugin .zip from a URL for this
                                        session only (repeatable: --plugin-url A
                                        --plugin-url B) (default: [])
  -p, --print                           Print response and exit (useful for
                                        pipes). Note: The workspace trust dialog
                                        is skipped when Claude is run in
                                        non-interactive mode (via -p, or when
                                        stdout is not a TTY, e.g. piped or
                                        redirected output). Only use this in
                                        directories you trust. Settings files
                                        that fail validation are silently
                                        ignored in this mode (no error dialog is
                                        shown).
  --prompt-suggestions [value]          Enable prompt suggestions. In print/SDK
                                        mode, emits a prompt_suggestion message
                                        after each turn with a predicted next
                                        user prompt (choices: "true", "false",
                                        "1", "0", "yes", "no", "on", "off",
                                        preset: "true")
  --remote-control [name]               Start an interactive session with Remote
                                        Control enabled (optionally named)
  --remote-control-session-name-prefix <prefix>
      Prefix for auto-generated Remote Control session names (default: hostname)
  --replay-user-messages                Re-emit user messages from stdin back on
                                        stdout for acknowledgment (only works
                                        with --input-format=stream-json and
                                        --output-format=stream-json)
  --restricted                          Restricted mode: removes the built-in
                                        tools that run commands or code (Bash,
                                        PowerShell, REPL and the other
                                        code-running tools) and WebFetch unless
                                        --tools names them, and ignores user,
                                        project and local settings files
                                        (managed settings and --settings still
                                        apply; add --strict-mcp-config to skip
                                        MCP servers too). Also confines the file
                                        tools to the working directories
                                        (--add-dir included), refuses
                                        bypassPermissions, and lets only a
                                        person or the configured permission
                                        handler approve writes to settings, git
                                        and tool-configuration files.
  -r, --resume [value]                  Resume a conversation by session ID, or
                                        open interactive picker with optional
                                        search term
  --safe-mode                           Start with all customizations
                                        (CLAUDE.md, skills, installed plugins,
                                        hooks, MCP servers, custom commands and
                                        agents, output styles, workflows, custom
                                        themes, keybindings, and more) disabled
                                        — useful for troubleshooting a broken
                                        configuration. Admin-managed (policy)
                                        settings still apply. Auth, model
                                        selection, built-in tools and plugins,
                                        and permissions work normally. Sets
                                        CLAUDE_CODE_SAFE_MODE=1.
  --session-id <uuid>                   Use a specific session ID for the
                                        conversation (must be a valid UUID)
  --setting-sources <sources>           Comma-separated list of setting sources
                                        to load (user, project, local).
  --settings <file-or-json>             Path to a settings JSON file or a JSON
                                        string to load additional settings from
  --strict-mcp-config                   Only use MCP servers from --mcp-config,
                                        ignoring all other MCP configurations
  --system-prompt <prompt>              System prompt to use for the session
  --system-prompt-snapshot <on|off>     Record the system prompt once per
                                        conversation and reuse it verbatim on
                                        every request and resume. on (the
                                        default): the prompt is rendered on the
                                        conversation's first request — a
                                        --system-prompt or
                                        --append-system-prompt included — sent,
                                        and recorded; every later request and
                                        resume sends the record as-is, even when
                                        a later launch passes different text,
                                        until the conversation is compacted.
                                        off: never record; the prompt is
                                        rendered fresh every request (for
                                        iterating on prompt text). No effect
                                        where system-prompt recording is not yet
                                        enabled. (choices: "on", "off")
  --teleport [session]                  Resume a teleport session, optionally
                                        specify session ID
  --tmux                                Create a tmux session for the worktree
                                        (requires --worktree). Uses iTerm2
                                        native panes when available; use
                                        --tmux=classic for traditional tmux.
  --tools <tools...>                    Specify the list of available tools from
                                        the built-in set. Use "" to disable all
                                        tools, "default" to use all tools, or
                                        specify tool names (e.g.
                                        "Bash,Edit,Read").
  --verbose                             Override verbose mode setting from
                                        config
  -v, --version                         Output the version number
  -w, --worktree [name]                 Create a new git worktree for this
                                        session (optionally specify a name)

Commands:
  agents [options]                      Manage background agents
  attach <id|name>                      Open a background session in this
                                        terminal. <id> is the short id that
                                        `claude --bg` prints and `claude agents`
                                        lists. Part of the session name works
                                        too
  auth                                  Manage authentication
  auto-mode                             Inspect or reset auto mode classifier
                                        configuration
  doctor                                Check the health of your Claude Code
                                        installation. Reads settings files in
                                        the current directory without a trust
                                        prompt. For a full checkup that can also
                                        fix issues, run /doctor in a session.
  gateway [options]                     Run the enterprise auth/telemetry
                                        gateway
  import [options] [source]             Import config from another AI coding
                                        agent into Claude Code
  install [options] [target]            Install Claude Code native build. Use
                                        [target] to specify version (stable,
                                        latest, or specific version)
  logs <id|name>                        Print a background session's recent
                                        terminal output
  mcp                                   Configure and manage MCP servers
  plugin|plugins                        Manage Claude Code plugins
  purge [options] [path]                Delete all Claude Code state for a
                                        project (transcripts, tasks, file
                                        history, config entry)
  respawn [options] [id]                Restart a background session, or all of
                                        them with --all, so it runs the current
                                        Claude Code version
  rm <id>                               Delete a background session, and its
                                        worktree when that is safe. Works on
                                        sessions that have already exited
  setup-token                           Set up a long-lived authentication token
                                        (requires Claude subscription)
  stop|kill <id>                        Stop a background session. Its
                                        conversation is kept: `claude attach
                                        <id>` opens it again, `claude --resume`
                                        works once it is stopped
  ultrareview [options] [target]        Run a cloud-hosted multi-agent code
                                        review of the current branch (or a PR
                                        number / base branch) and print the
                                        findings
  update|upgrade                        Check for updates and install if
                                        available
"""#

    static let toolTurn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","tools":["Agent","Bash","Edit","Glob","Grep","Read","TodoWrite","Write"],"mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","slash_commands":["compact"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u"}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[],"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The greeting has a typo."}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_stop","index":0},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"thinking","thinking":"The greeting has a typo.","signature":"c2ln"}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"I'll fix the "}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"greeting."}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_stop","index":1},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"I'll fix the greeting."}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_edit","name":"Edit","input":{}}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"file_path\": \"/tmp/project/hello.txt\"}"}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_stop","index":2},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"toolu_edit","name":"Edit","input":{"file_path":"/tmp/project/hello.txt","old_string":"helo","new_string":"hello"}}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":80}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"message_stop"},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_edit","type":"tool_result","content":"The file /tmp/project/hello.txt has been updated. Here's the result of running `cat -n` on a snippet of the edited file:\n     1\thello world"}]},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u","tool_use_result":{"filePath":"/tmp/project/hello.txt","oldString":"helo","newString":"hello","originalFile":"helo world\n","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-helo world","+hello world"]}],"userModified":false,"replaceAll":false}}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":300,"cache_read_input_tokens":10200,"output_tokens":1}}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_2","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"toolu_bash","name":"Bash","input":{"command":"cat hello.txt","description":"Show the file"}}],"stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":300,"cache_read_input_tokens":10200,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"message_stop"},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_bash","type":"tool_result","content":"hello world"}]},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u","tool_use_result":{"stdout":"hello world","stderr":"","interrupted":false,"isImage":false}}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_3","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":200,"cache_read_input_tokens":10500,"output_tokens":1}}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_3","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"toolu_write","name":"Write","input":{"file_path":"/tmp/project/NOTES.md","content":"Fixed the greeting.\n"}}],"stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":200,"cache_read_input_tokens":10500,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_3","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"toolu_todo","name":"TodoWrite","input":{"todos":[{"content":"Fix the typo","status":"completed","activeForm":"Fixing the typo"},{"content":"Write a note","status":"in_progress","activeForm":"Writing a note"}]}}],"stop_reason":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":200,"cache_read_input_tokens":10500,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"message_stop"},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_write","type":"tool_result","content":[{"type":"text","text":"File created successfully at: /tmp/project/NOTES.md"}]}]},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u","tool_use_result":{"type":"create","filePath":"/tmp/project/NOTES.md","content":"Fixed the greeting.\n","structuredPatch":[],"originalFile":null}}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_todo","type":"tool_result","content":"Todos have been modified successfully."}]},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u","tool_use_result":{"oldTodos":[],"newTodos":[]}}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_4","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[],"usage":{"input_tokens":4,"cache_creation_input_tokens":150,"cache_read_input_tokens":10900,"output_tokens":1}}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done — fixed the typo."}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_stop","index":0},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_4","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"Done — fixed the typo."}],"stop_reason":null,"usage":{"input_tokens":4,"cache_creation_input_tokens":150,"cache_read_input_tokens":10900,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":12}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"message_stop"},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":8123,"duration_api_ms":7000,"num_turns":4,"result":"Done — fixed the typo.","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","total_cost_usd":0.0421,"usage":{"input_tokens":12,"cache_creation_input_tokens":1500,"cache_read_input_tokens":30000,"output_tokens":420},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":12,"outputTokens":420,"cacheReadInputTokens":30000,"cacheCreationInputTokens":1500,"costUSD":0.0421}},"permission_denials":[],"uuid":"u"}
"""#

    static let plainTurn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","tools":["Agent","Bash","Edit","Glob","Grep","Read","TodoWrite","Write"],"mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","slash_commands":["compact"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u"}
{"type":"assistant","message":{"id":"msg_a","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"Looking at it."}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_a","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"toolu_read","name":"Read","input":{"file_path":"/tmp/project/hello.txt"}}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_read","type":"tool_result","content":"     1\thello world"}]},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u","tool_use_result":{"type":"text","file":{"filePath":"/tmp/project/hello.txt","content":"hello world","numLines":1,"startLine":1,"totalLines":1}}}
{"type":"assistant","message":{"id":"msg_b","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"It says hello world."}],"stop_reason":null,"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":11000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":8123,"duration_api_ms":7000,"num_turns":2,"result":"It says hello world.","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","total_cost_usd":0.01,"usage":{"input_tokens":12,"cache_creation_input_tokens":1500,"cache_read_input_tokens":30000,"output_tokens":420},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":12,"outputTokens":420,"cacheReadInputTokens":30000,"cacheCreationInputTokens":1500,"costUSD":0.01}},"permission_denials":[],"uuid":"u"}
"""#

    static let deniedTurn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","tools":["Agent","Bash","Edit","Glob","Grep","Read","TodoWrite","Write"],"mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","slash_commands":["compact"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u"}
{"type":"assistant","message":{"id":"msg_d","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"toolu_rm","name":"Bash","input":{"command":"rm -rf build","description":"Clean the build"}}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"toolu_rm","decision_reason_type":"rule","decision_reason":"Bash(rm *)","message":"Permission to use Bash with command rm -rf build has been denied.","uuid":"u","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_rm","type":"tool_result","content":"<tool_use_error>Permission to use Bash with command rm -rf build has been denied.</tool_use_error>","is_error":true}]},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_e","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"I wasn't allowed to delete the build folder."}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":8123,"duration_api_ms":7000,"num_turns":2,"result":"I wasn't allowed to delete the build folder.","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","total_cost_usd":0.02,"usage":{"input_tokens":12,"cache_creation_input_tokens":1500,"cache_read_input_tokens":30000,"output_tokens":420},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":12,"outputTokens":420,"cacheReadInputTokens":30000,"cacheCreationInputTokens":1500,"costUSD":0.02}},"permission_denials":[{"tool_name":"Bash","tool_use_id":"toolu_rm","tool_input":{"command":"rm -rf build"}}],"uuid":"u"}
"""#

    static let subagentTurn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","tools":["Agent","Bash","Edit","Glob","Grep","Read","TodoWrite","Write"],"mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","slash_commands":["compact"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u"}
{"type":"assistant","message":{"id":"msg_s","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"toolu_agent","name":"Agent","input":{"description":"Find the greeting","prompt":"Find where the greeting is defined.","subagent_type":"Explore"}}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Find where the greeting is defined."}]},"parent_tool_use_id":"toolu_agent","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_sub","type":"message","role":"assistant","model":"claude-haiku-5-5","content":[{"type":"tool_use","id":"toolu_grep","name":"Grep","input":{"pattern":"greeting","path":"/tmp/project/src"}}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":"toolu_agent","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_grep","type":"tool_result","content":"src/app.js"}]},"parent_tool_use_id":"toolu_agent","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_sub2","type":"message","role":"assistant","model":"claude-haiku-5-5","content":[{"type":"text","text":"It is in src/app.js."}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":"toolu_agent","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_agent","type":"tool_result","content":[{"type":"text","text":"It is in src/app.js."}]}]},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_t","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"The greeting lives in src/app.js."}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":8123,"duration_api_ms":7000,"num_turns":2,"result":"The greeting lives in src/app.js.","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","total_cost_usd":0.03,"usage":{"input_tokens":12,"cache_creation_input_tokens":1500,"cache_read_input_tokens":30000,"output_tokens":420},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":12,"outputTokens":420,"cacheReadInputTokens":30000,"cacheCreationInputTokens":1500,"costUSD":0.03}},"permission_denials":[],"uuid":"u"}
"""#

    static let retryTurn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","tools":["Agent","Bash","Edit","Glob","Grep","Read","TodoWrite","Write"],"mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","slash_commands":["compact"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u"}
{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":2000,"error_status":529,"error":"overloaded","uuid":"u","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d"}
{"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"retry_delay_ms":4000,"error_status":529,"error":"overloaded","uuid":"u","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d"}
{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_r","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[],"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Back."}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_r","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"Back."}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":180000,"post_tokens":21000},"uuid":"u","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d"}
{"type":"system","subtype":"status","status":"compacting","uuid":"u","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d"}
{"type":"system","subtype":"informational","level":"warning","content":"The model is slow right now.","uuid":"u","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":8123,"duration_api_ms":7000,"num_turns":1,"result":"Back.","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","total_cost_usd":0.005,"usage":{"input_tokens":12,"cache_creation_input_tokens":1500,"cache_read_input_tokens":30000,"output_tokens":420},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":12,"outputTokens":420,"cacheReadInputTokens":30000,"cacheCreationInputTokens":1500,"costUSD":0.005}},"permission_denials":[],"uuid":"u"}
"""#

    static let maxTurnsTurn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","tools":["Agent","Bash","Edit","Glob","Grep","Read","TodoWrite","Write"],"mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","slash_commands":["compact"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u"}
{"type":"assistant","message":{"id":"msg_m","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"toolu_ls","name":"Glob","input":{"pattern":"**/*.swift"}}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_ls","type":"tool_result","content":"a.swift\nb.swift"}]},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"result","subtype":"error_max_turns","is_error":true,"duration_ms":8123,"duration_api_ms":7000,"num_turns":1,"result":"","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","total_cost_usd":0.002,"usage":{"input_tokens":12,"cache_creation_input_tokens":1500,"cache_read_input_tokens":30000,"output_tokens":420},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":12,"outputTokens":420,"cacheReadInputTokens":30000,"cacheCreationInputTokens":1500,"costUSD":0.002}},"permission_denials":[],"uuid":"u","errors":[]}
"""#

    static let usageLimitTurn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","tools":["Agent","Bash","Edit","Glob","Grep","Read","TodoWrite","Write"],"mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","slash_commands":["compact"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u"}
{"type":"assistant","message":{"id":"x","type":"message","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"You've hit your limit · resets 3pm (America/Los_Angeles)"}],"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u","error":"rate_limit","is_api_error_message":true}
{"type":"result","subtype":"success","is_error":true,"duration_ms":8123,"duration_api_ms":7000,"num_turns":1,"result":"You've hit your limit · resets 3pm (America/Los_Angeles)","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","total_cost_usd":0,"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":12,"outputTokens":420,"cacheReadInputTokens":30000,"cacheCreationInputTokens":1500,"costUSD":0}},"permission_denials":[],"uuid":"u"}
"""#

    static let planTurn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","tools":["Agent","Bash","Edit","Glob","Grep","Read","TodoWrite","Write"],"mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"plan","slash_commands":["compact"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u"}
{"type":"assistant","message":{"id":"msg_p","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"Here's my plan."}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"assistant","message":{"id":"msg_p","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"toolu_plan","name":"ExitPlanMode","input":{"plan":"1. Fix the typo\n2. Run the tests"}}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_plan","type":"tool_result","content":"Exit plan mode? The user must approve this.","is_error":true}]},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":8123,"duration_api_ms":7000,"num_turns":1,"result":"Here's my plan.","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","total_cost_usd":0.01,"usage":{"input_tokens":12,"cache_creation_input_tokens":1500,"cache_read_input_tokens":30000,"output_tokens":420},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":12,"outputTokens":420,"cacheReadInputTokens":30000,"cacheCreationInputTokens":1500,"costUSD":0.01}},"permission_denials":[{"tool_name":"ExitPlanMode","tool_use_id":"toolu_plan","tool_input":{"plan":"1. Fix the typo"}}],"uuid":"u"}
"""#

    static let warningTurn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","tools":["Agent","Bash","Edit","Glob","Grep","Read","TodoWrite","Write"],"mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","slash_commands":["compact"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u"}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"five_hour","utilization":0.82,"resetsAt":1792000000},"uuid":"u","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d"}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"five_hour","utilization":0.9,"resetsAt":1792000000},"uuid":"u","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d"}
{"type":"assistant","message":{"id":"msg_w","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"Done."}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":8123,"duration_api_ms":7000,"num_turns":1,"result":"Done.","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","total_cost_usd":0.01,"usage":{"input_tokens":12,"cache_creation_input_tokens":1500,"cache_read_input_tokens":30000,"output_tokens":420},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":12,"outputTokens":420,"cacheReadInputTokens":30000,"cacheCreationInputTokens":1500,"costUSD":0.01}},"permission_denials":[],"uuid":"u"}
"""#

    static let rejectedTurn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","tools":["Agent","Bash","Edit","Glob","Grep","Read","TodoWrite","Write"],"mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","slash_commands":["compact"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u"}
{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"seven_day","resetsAt":1792000000},"uuid":"u","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d"}
{"type":"assistant","message":{"id":"y","type":"message","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"Claude AI usage limit reached"}],"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u","error":"rate_limit","is_api_error_message":true}
{"type":"result","subtype":"success","is_error":true,"duration_ms":8123,"duration_api_ms":7000,"num_turns":1,"result":"Claude AI usage limit reached","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","total_cost_usd":0,"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":12,"outputTokens":420,"cacheReadInputTokens":30000,"cacheCreationInputTokens":1500,"costUSD":0}},"permission_denials":[],"uuid":"u"}
"""#

    static let permissionTurn = #"""
{"type":"system","subtype":"init","cwd":"/tmp/project","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","tools":["Agent","Bash","Edit","Glob","Grep","Read","TodoWrite","Write"],"mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","slash_commands":["compact"],"apiKeySource":"none","claude_code_version":"2.1.299","output_style":"default","agents":[],"skills":[],"plugins":[],"uuid":"u"}
{"type":"assistant","message":{"id":"msg_q","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"tool_use","id":"toolu_q","name":"Bash","input":{"command":"rm -rf build","description":"Clean"}}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build","description":"Clean"},"tool_use_id":"toolu_q","decision_reason":"\u001b[1mrm\u001b[0m deletes files","decision_reason_type":"safetyCheck","classifier_approvable":false}}
{"type":"control_request","request_id":"req-2","request":{"subtype":"hook_callback","callback_id":"x"}}
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_q","type":"tool_result","content":""}]},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u","tool_use_result":{"stdout":"","stderr":"","interrupted":false}}
{"type":"assistant","message":{"id":"msg_r2","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"Cleaned."}],"stop_reason":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":1200,"cache_read_input_tokens":9000,"output_tokens":1}},"parent_tool_use_id":null,"session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","uuid":"u"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":8123,"duration_api_ms":7000,"num_turns":2,"result":"Cleaned.","session_id":"4f1c2a9e-7b3d-4e8a-9c21-5d6f7a8b9c0d","total_cost_usd":0.01,"usage":{"input_tokens":12,"cache_creation_input_tokens":1500,"cache_read_input_tokens":30000,"output_tokens":420},"modelUsage":{"claude-sonnet-5-5":{"inputTokens":12,"outputTokens":420,"cacheReadInputTokens":30000,"cacheCreationInputTokens":1500,"costUSD":0.01}},"permission_denials":[],"uuid":"u"}
"""#

    static func lines(_ blob: String) -> [String] { blob.components(separatedBy: "\n") }
}
