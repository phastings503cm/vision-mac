import Foundation

/// Transcripts in the shapes the real tools write, built from real files on the development Mac (read-only) with
/// every text, id and path replaced: the keys, nesting, wrappers and line kinds are the real ones.
enum ChatImportFixtures {
    // MARK: Claude Code — one session file (~/.claude/projects/<folder>/<session>.jsonl), Claude Code 2.1.2xx.

    static let claudeCodeSession = """
    {"type":"file-history-snapshot","messageId":"m0","snapshot":{"trackedFileBackups":{}},"isSnapshotUpdate":false}
    {"parentUuid":null,"isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Fix the login page <system-reminder>secret harness note</system-reminder>"},"uuid":"u1","timestamp":"2026-08-25T20:43:49.500Z","permissionMode":"bypassPermissions","origin":{"kind":"human"},"promptSource":"sdk","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"u1","isSidechain":false,"attachment":{"type":"total_tokens_reminder","tokens":12000},"type":"attachment","uuid":"a1","timestamp":"2026-08-25T20:43:49.600Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"u1","isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":"Caveat: the harness wrote this"},"isMeta":true,"uuid":"u2","timestamp":"2026-08-25T20:43:49.700Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"u2","isSidechain":false,"message":{"model":"claude-fable-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"private reasoning","signature":"sig"}],"stop_reason":null},"requestId":"r1","type":"assistant","uuid":"as1","timestamp":"2026-08-25T20:43:52.000Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"as1","isSidechain":false,"message":{"model":"claude-fable-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"I'll look at the login form first."}],"stop_reason":null},"requestId":"r1","type":"assistant","uuid":"as2","timestamp":"2026-08-25T20:43:53.000Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"as2","isSidechain":false,"message":{"model":"claude-fable-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Then I'll run the tests."}],"stop_reason":null},"requestId":"r1","type":"assistant","uuid":"as3","timestamp":"2026-08-25T20:43:53.500Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"as3","isSidechain":false,"message":{"model":"claude-fable-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01A","name":"Bash","input":{"command":"npm test -- login","description":"Run the login tests"},"caller":{"type":"direct"}}],"stop_reason":"tool_use"},"requestId":"r1","type":"assistant","uuid":"as4","timestamp":"2026-08-25T20:43:54.000Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"as4","isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01A","type":"tool_result","content":"PASS login.test.ts\\n3 tests passed","is_error":false}]},"uuid":"u3","timestamp":"2026-08-25T20:44:10.000Z","sourceToolAssistantUUID":"as4","toolUseResult":{"stdout":"PASS"},"userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"u3","isSidechain":false,"message":{"model":"claude-fable-5","id":"msg_2","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01B","name":"Read","input":{"file_path":"/Users/pat/code/demo/missing.ts"},"caller":{"type":"direct"}}]},"requestId":"r2","type":"assistant","uuid":"as5","timestamp":"2026-08-25T20:44:12.000Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"as5","isSidechain":false,"promptId":"p1","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"File does not exist.","is_error":true,"tool_use_id":"toolu_01B"}]},"uuid":"u4","timestamp":"2026-08-25T20:44:12.500Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"u4","isSidechain":true,"promptId":"p9","type":"user","message":{"role":"user","content":"a subagent's own prompt"},"uuid":"s1","timestamp":"2026-08-25T20:44:13.000Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"u4","isSidechain":false,"message":{"model":"claude-fable-5","id":"msg_3","type":"message","role":"assistant","content":[{"type":"text","text":"The login tests pass; the old helper file is gone."}]},"requestId":"r3","type":"assistant","uuid":"as6","timestamp":"2026-08-25T20:44:20.000Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"type":"custom-title","customTitle":"Login page fixes","sessionId":"5b1c9a1e-0000-4000-8000-000000000001"}
    {"type":"ai-title","aiTitle":"Fixing the login","sessionId":"5b1c9a1e-0000-4000-8000-000000000001"}
    {"parentUuid":"as6","isSidechain":false,"promptId":"p2","type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\\n            <command-message>model</command-message>\\n            <command-args>claude-opus-5</command-args>"},"uuid":"u5","timestamp":"2026-08-26T08:00:00.000Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"u5","isSidechain":false,"promptId":"p2","type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to claude-opus-5</local-command-stdout>"},"uuid":"u6","timestamp":"2026-08-26T08:00:00.100Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"u6","isSidechain":false,"promptId":"p3","type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/webp","data":"iVBORw0KGgo="}},{"type":"text","text":"Here is the broken screen"}]},"uuid":"u7","timestamp":"2026-08-26T08:01:00.000Z","origin":{"kind":"human"},"userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"u7","isSidechain":false,"attachment":{"type":"queued_command","prompt":"also check the signup page","source_uuid":"q1","commandMode":"prompt","origin":{"kind":"human"},"timestamp":"2026-08-26T08:01:30.000Z"},"type":"attachment","uuid":"a2","timestamp":"2026-08-26T08:01:30.000Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"a2","isSidechain":false,"attachment":{"type":"queued_command","prompt":"<task-notification>\\n<task-id>t1</task-id>\\n<status>completed</status>\\n<summary>Recon finished</summary>\\n</task-notification>","commandMode":"task-notification","timestamp":"2026-08-26T08:01:40.000Z"},"type":"attachment","uuid":"a3","timestamp":"2026-08-26T08:01:40.000Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"a3","isSidechain":false,"promptId":"p4","type":"user","message":{"role":"user","content":"<task-notification>\\n<task-id>t1</task-id>\\n<tool-use-id>toolu_09</tool-use-id>\\n<status>completed</status>\\n<summary>Recon finished</summary>\\n</task-notification>"},"uuid":"u8","timestamp":"2026-08-26T08:01:41.000Z","origin":{"kind":"task-notification"},"userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":null,"logicalParentUuid":"u8","isSidechain":false,"type":"system","subtype":"compact_boundary","content":"Conversation compacted","isMeta":false,"timestamp":"2026-08-26T09:00:00.000Z","uuid":"c1","level":"info","compactMetadata":{"trigger":"auto","preTokens":999299},"userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"c1","isSidechain":false,"promptId":"p5","type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation.\\n\\nSummary: the login page was fixed."},"isCompactSummary":true,"isVisibleInTranscriptOnly":true,"uuid":"u9","timestamp":"2026-08-26T09:00:01.000Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.227","gitBranch":"main"}
    {"parentUuid":"u9","isSidechain":false,"type":"assistant","uuid":"as7","timestamp":"2026-09-29T19:11:31.883Z","message":{"id":"e1","model":"<synthetic>","role":"assistant","type":"message","content":[{"type":"text","text":"Please run /login · API Error: 401"}]},"error":"authentication_failed","isApiErrorMessage":true,"userType":"external","entrypoint":"claude-desktop","cwd":"/Users/pat/code/demo","sessionId":"5b1c9a1e-0000-4000-8000-000000000001","version":"2.1.281","gitBranch":"main"}
    {"type":"last-prompt","lastPrompt":"also check the signup page","leafUuid":"as7","sessionId":"5b1c9a1e-0000-4000-8000-000000000001"}
    not json at all
    """

    // MARK: Codex — a rollout (~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-…-<id>.jsonl), Codex 0.117.

    static let codexID = "c0de0000-0000-4000-8000-0000000000c1"

    static let codexRollout = """
    {"timestamp":"2026-05-07T10:02:09.139Z","type":"session_meta","payload":{"id":"c0de0000-0000-4000-8000-0000000000c1","timestamp":"2026-05-07T10:02:09.139Z","cwd":"/Users/pat/infra","originator":"Codex Desktop","cli_version":"0.117.0-alpha.24","source":"vscode","model_provider":"openai","base_instructions":{"text":"..."}}}
    {"timestamp":"2026-05-07T10:03:45.439Z","type":"event_msg","payload":{"type":"task_started","turn_id":"t1","model_context_window":258400}}
    {"timestamp":"2026-05-07T10:03:45.439Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>\\nsandboxing</permissions instructions>"}]}}
    {"timestamp":"2026-05-07T10:03:45.439Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\\n  <cwd>/Users/pat/infra</cwd>\\n</environment_context>"}]}}
    {"timestamp":"2026-05-07T10:03:45.439Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/Users/pat/infra","approval_policy":"on-request","model":"gpt-5.4"}}
    {"timestamp":"2026-05-07T10:03:45.440Z","type":"event_msg","payload":{"type":"user_message","message":"I need an S3 bucket in Oregon\\n","images":[],"local_images":[],"text_elements":[]}}
    {"timestamp":"2026-05-07T10:03:45.440Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"I need an S3 bucket in Oregon\\n"}]}}
    {"timestamp":"2026-05-07T10:03:45.749Z","type":"event_msg","payload":{"type":"token_count","info":null}}
    {"timestamp":"2026-05-07T10:03:47.612Z","type":"response_item","payload":{"type":"reasoning","summary":[],"content":null,"encrypted_content":"gAAAA"}}
    {"timestamp":"2026-05-07T10:03:52.602Z","type":"event_msg","payload":{"type":"agent_message","message":"I'll inspect the workspace first.","phase":"commentary"}}
    {"timestamp":"2026-05-07T10:03:52.602Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I'll inspect the workspace first."}],"phase":"commentary"}}
    {"timestamp":"2026-05-07T10:03:52.602Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ls -la\\",\\"workdir\\":\\"/Users/pat/infra\\"}","call_id":"call_1"}}
    {"timestamp":"2026-05-07T10:03:52.686Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"Command: /bin/zsh -lc ls -la\\nProcess exited with code 0\\nOutput:\\nmain.tf\\n"}}
    {"timestamp":"2026-05-07T10:03:53.137Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"terraform plan\\"}","call_id":"call_2"}}
    {"timestamp":"2026-05-07T10:03:54.137Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_2","output":"Command: /bin/zsh -lc terraform plan\\nProcess exited with code 1\\nOutput:\\nError: no credentials\\n"}}
    {"timestamp":"2026-05-07T10:07:27.079Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"call_3","name":"apply_patch","input":"*** Begin Patch\\n*** Add File: /Users/pat/infra/bucket.tf\\n+resource {}\\n*** End Patch"}}
    {"timestamp":"2026-05-07T10:07:27.117Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_3","output":"{\\"output\\":\\"Success. Updated the following files:\\\\nA /Users/pat/infra/bucket.tf\\\\n\\",\\"metadata\\":{\\"exit_code\\":0,\\"duration_seconds\\":0.0}}"}}
    {"timestamp":"2026-05-07T10:08:13.137Z","type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"search","query":"terraform s3 bucket oregon"}}}
    {"timestamp":"2026-05-07T10:08:13.656Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Added bucket.tf; sign in to AWS so I can apply it."}],"phase":"final"}}
    {"timestamp":"2026-05-07T10:08:13.656Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","last_agent_message":"Added bucket.tf"}}
    {"timestamp":"2026-05-27T06:38:18.474Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t2","reason":"interrupted"}}
    """

    static let codexIndex = """
    {"id":"c0de0000-0000-4000-8000-0000000000c1","thread_name":"Provision bucket","updated_at":"2026-05-07T10:03:49.450383Z"}
    {"id":"other","thread_name":"Another","updated_at":"2026-05-12T06:37:13Z"}
    """

    /// An early rollout: no wrapper, no user_message events.
    static let codexLegacy = """
    {"id":"legacy-1","timestamp":"2025-05-01T10:00:00.000Z","instructions":null}
    {"type":"message","role":"user","content":[{"type":"input_text","text":"<user_instructions>be brief</user_instructions>"}]}
    {"type":"message","role":"user","content":[{"type":"input_text","text":"What does main.py do?"}]}
    {"type":"function_call","name":"shell","arguments":"{\\"command\\":[\\"bash\\",\\"-lc\\",\\"cat main.py\\"]}","call_id":"c1"}
    {"type":"function_call_output","call_id":"c1","output":"{\\"output\\":\\"print('hi')\\",\\"metadata\\":{\\"exit_code\\":0}}"}
    {"type":"message","role":"assistant","content":[{"type":"output_text","text":"It prints hi."}]}
    """

    // MARK: OpenClaw — agent session events (format 3), as transcript_events.event_json rows and as JSONL files.

    static let openClawChatEvents: [String] = [
        #"{"type":"session","version":3,"id":"7f0c2a11-0000-4000-8000-0000000000aa","timestamp":"2026-09-01T00:00:02.938Z","cwd":"/Users/pat/.openclaw/workspace"}"#,
        #"{"type":"model_change","id":"e1","parentId":null,"timestamp":"2026-09-01T00:00:02.940Z","provider":"amazon-bedrock","modelId":"us.anthropic.claude-opus-4-8"}"#,
        #"{"type":"custom","customType":"model-snapshot","data":{"modelId":"us.anthropic.claude-opus-4-8"},"id":"e2","parentId":"e1","timestamp":"2026-09-01T00:00:02.944Z"}"#,
        #"{"type":"message","id":"e3","parentId":"e2","timestamp":"2026-09-01T00:00:03.000Z","message":{"role":"user","content":[{"type":"text","text":"How many open tickets are there?"}]}}"#,
        #"{"type":"message","id":"e4","parentId":"e3","timestamp":"2026-09-01T00:00:06.898Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"I'll check Freshdesk."},{"type":"toolCall","id":"tooluse_1","name":"exec","arguments":{"command":"python3 tickets.py --open"}}],"model":"us.anthropic.claude-opus-4-8","stopReason":"toolUse"}}"#,
        #"{"type":"message","id":"e5","parentId":"e4","timestamp":"2026-09-01T00:00:08.041Z","message":{"role":"toolResult","toolCallId":"tooluse_1","toolName":"exec","content":[{"type":"text","text":"12 open"}],"isError":false}}"#,
        #"{"type":"message","id":"e6","parentId":"e5","timestamp":"2026-09-01T00:00:10.000Z","message":{"role":"assistant","content":[{"type":"text","text":"There are 15 open tickets."}],"stopReason":"stop"}}"#,
        #"{"type":"leaf","id":"l1","parentId":"e6","timestamp":"2026-09-01T00:01:00.000Z","targetId":"e5"}"#,
        #"{"type":"message","id":"e7","parentId":"e5","timestamp":"2026-09-01T00:01:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"There are 12 open tickets."}],"stopReason":"stop"}}"#,
        #"{"type":"custom_message","customType":"openclaw.sessions_yield","content":"waiting on a subagent","display":false,"id":"e8","parentId":"e7","timestamp":"2026-09-01T00:01:02.000Z"}"#,
    ]

    static let openClawCronEvents: [String] = [
        #"{"type":"session","version":3,"id":"9a9a9a9a-0000-4000-8000-0000000000bb","timestamp":"2026-10-19T18:30:00.000Z","cwd":"/Users/pat/.openclaw/workspace"}"#,
        #"{"type":"message","id":"c1","parentId":null,"timestamp":"2026-10-19T18:30:00.100Z","message":{"role":"user","content":[{"type":"text","text":"[cron:c4a1e000-0000-4000-8000-0000000000c2 helpdesk-sweep-30min] Scan the helpdesk for open tickets."}]}}"#,
        #"{"type":"message","id":"c2","parentId":"c1","timestamp":"2026-10-19T18:30:09.000Z","message":{"role":"assistant","content":[{"type":"text","text":"NO_REPLY"}]}}"#,
    ]

    // MARK: Claude.ai data export — conversations.json

    static let claudeAIExport = """
    [{"uuid":"c0ffee00-0000-4000-8000-000000000001","name":"Trip planning","summary":"","created_at":"2026-05-01T17:43:26.474811Z","updated_at":"2026-05-01T18:00:00.000000Z","account":{"uuid":"acct"},
      "chat_messages":[
        {"uuid":"m1","text":"Plan a weekend in Portland","content":[{"start_timestamp":"2026-05-01T17:43:26.474811Z","stop_timestamp":"2026-05-01T17:43:26.474811Z","type":"text","text":"Plan a weekend in Portland","citations":[]}],"sender":"human","created_at":"2026-05-01T17:43:26.474811Z","updated_at":"2026-05-01T17:43:26.474811Z","attachments":[{"file_name":"budget.txt","file_size":12,"file_type":"txt","extracted_content":"Budget: $400"}],"files":[{"file_name":"map.png"}]},
        {"uuid":"m2","text":"","content":[{"type":"thinking","thinking":"secret"},{"type":"tool_use","name":"web_search","input":{"query":"portland weekend events"}},{"type":"tool_result","name":"web_search","content":[{"type":"text","text":"Saturday market"}],"is_error":false},{"type":"text","text":"Here's a plan: Saturday market, then Powell's."}],"sender":"assistant","created_at":"2026-05-01T17:44:00.000000Z","updated_at":"2026-05-01T17:44:00.000000Z","attachments":[],"files":[]}
      ]},
     {"uuid":"c0ffee00-0000-4000-8000-000000000002","name":"","created_at":"2026-05-02T09:00:00Z","updated_at":"2026-05-02T09:00:00Z","chat_messages":[]}]
    """

    // MARK: ChatGPT data export — conversations.json (a tree per conversation)

    static let chatGPTExport = """
    [{"title":"Fibonacci in Python","create_time":1767225600.5,"update_time":1767225900.25,"conversation_id":"6790aaaa-0000-4000-8000-000000000001","id":"6790aaaa-0000-4000-8000-000000000001","current_node":"n6","default_model_slug":"gpt-4o",
      "mapping":{
        "root":{"id":"root","message":null,"parent":null,"children":["n0"]},
        "n0":{"id":"n0","message":{"id":"n0","author":{"role":"system","name":null,"metadata":{}},"create_time":null,"content":{"content_type":"text","parts":[""]},"metadata":{"is_visually_hidden_from_conversation":true},"recipient":"all"},"parent":"root","children":["n1"]},
        "n1":{"id":"n1","message":{"id":"n1","author":{"role":"user"},"create_time":1767225601.0,"content":{"content_type":"multimodal_text","parts":[{"content_type":"image_asset_pointer","asset_pointer":"file-service://x"},"Write fib in Python"]},"metadata":{},"recipient":"all"},"parent":"n0","children":["n2a","n2"]},
        "n2a":{"id":"n2a","message":{"id":"n2a","author":{"role":"assistant"},"create_time":1767225602.0,"content":{"content_type":"text","parts":["An abandoned first answer"]},"metadata":{"model_slug":"gpt-4o"},"recipient":"all"},"parent":"n1","children":[]},
        "n2":{"id":"n2","message":{"id":"n2","author":{"role":"assistant"},"create_time":1767225610.0,"content":{"content_type":"code","language":"python","text":"def fib(n):\\n    return n if n < 2 else fib(n-1)+fib(n-2)\\nprint(fib(10))"},"metadata":{"model_slug":"gpt-4o"},"recipient":"python"},"parent":"n1","children":["n3"]},
        "n3":{"id":"n3","message":{"id":"n3","author":{"role":"tool","name":"python"},"create_time":1767225611.0,"content":{"content_type":"execution_output","text":"55"},"metadata":{},"recipient":"all"},"parent":"n2","children":["n4"]},
        "n4":{"id":"n4","message":{"id":"n4","author":{"role":"assistant"},"create_time":1767225612.0,"content":{"content_type":"thoughts","thoughts":[{"summary":"x","content":"y"}]},"metadata":{},"recipient":"all"},"parent":"n3","children":["n5"]},
        "n5":{"id":"n5","message":{"id":"n5","author":{"role":"assistant"},"create_time":1767225613.0,"content":{"content_type":"text","parts":["fib(10) is 55."]},"metadata":{"model_slug":"gpt-4o"},"recipient":"all"},"parent":"n4","children":["n6"]},
        "n6":{"id":"n6","message":{"id":"n6","author":{"role":"user"},"create_time":1767225700.0,"content":{"content_type":"text","parts":["Thanks!"]},"metadata":{},"recipient":"all"},"parent":"n5","children":[]}
      }}]
    """
}
