#!/bin/bash
# Local launcher; the complete upstream engine remains at /opt/codex/bin/codex.
set -euo pipefail
if [ ! -r /etc/codex/config.toml ] || [ ! -r /etc/codex/requirements.toml ]; then
    echo '烤鱼运行策略缺失，已拒绝启动引擎。请重新执行环境检查。' >&2
    exit 78
fi
# Do not inherit OpenAI API, OAuth, PAT or workload-identity credentials from a shell.
for key in ${!OPENAI_@} ${!OTEL_@} ${!SENTRY_@}; do unset "$key"; done
unset CODEX_API_KEY CODEX_ACCESS_TOKEN CODEX_AUTHAPI_BASE_URL CODEX_AGENT_IDENTITY_AUTHAPI_BASE_URL CODEX_APP_SERVER_LOGIN_CLIENT_ID

command=''; skip=0; informational=0
for argument in "$@"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$argument" in
        -c|--config|-m|--model|-p|--profile|-C|--cd|--add-dir|--enable|--disable) skip=1; continue;;
        --remote|--remote=*|--remote-control|--remote-control=*|--enable-remote-control) echo '此版本未启用 Codex 官方远程服务。' >&2; exit 64;;
        --) echo '请直接传入命令参数；此受管理启动器不接受 --。' >&2; exit 64;;
        -h|--help|-V|--version) informational=1; continue;;
        -*) continue;;
    esac
    command=$argument
    break
done
case "$command" in
    login|logout|cloud|cloud-tasks|remote-control|update|doctor|plugin|app|debug|tcp-tunnel|responses-api-proxy|mcp|apply|a)
        echo "此版本未启用 Codex 官方功能：$command" >&2; exit 64;;
    exec|e|review|app-server|completion|migrate-rollouts|sandbox|execpolicy|stdio-to-uds|features) ;;
    '')
        [ "$informational" = 1 ] || { echo '请使用烤鱼界面或 codex exec；此版本未启用上游交互式 TUI。' >&2; exit 64; };;
    *) echo '此版本仅启用本地引擎；请使用烤鱼界面或 codex exec。' >&2; exit 64;;
esac
if [ "$command" = app-server ]; then
    listen_next=0
    for argument in "$@"; do
        if [ "$listen_next" = 1 ]; then
            [ "$argument" = stdio:// ] || { echo '此版本仅启用本地 stdio app-server。' >&2; exit 64; }
            listen_next=0
        fi
        case "$argument" in
        --listen) listen_next=1;;
        --listen=stdio://) ;;
        daemon|proxy|bootstrap|--enable-remote-control|--remote|--remote=*|--remote-control|--remote-control=*|--listen=*)
            echo '此版本仅启用本地 stdio app-server。' >&2; exit 64;;
        esac
    done
fi

strict=()
case "$command" in
    ''|agents|exec|e|review|exec-server|resume|queue|archive|delete|unarchive|fork|app-server) strict=(--strict-config);;
    completion|mcp|migrate-rollouts|sandbox|execpolicy|apply|a|stdio-to-uds|features) ;;
    *) strict=(--strict-config);;
esac
# CLI overrides follow user arguments; requirements also pin the feature policy.
overrides=(
    -c 'model_provider="kaoyu"'
    -c 'check_for_update_on_startup=false'
    -c 'cli_auth_credentials_store="ephemeral"'
    -c 'web_search="disabled"'
    -c 'include_apps_instructions=false'
    -c 'analytics.enabled=false'
    -c 'feedback.enabled=false'
    -c 'otel.exporter="none"'
    -c 'otel.trace_exporter="none"'
    -c 'otel.metrics_exporter="none"'
    -c 'otel.log_user_prompt=false'
    -c 'otel.log_agent_responses=false'
    -c 'otel.log_guardian_assessments=false'
    -c 'skills.bundled.enabled=false'
    -c 'agents.enabled=true'
    -c 'tools.experimental_request_user_input.enabled=true'
    -c 'features.analytics_plan_history=false'
    -c 'features.daemon_auto_start=false'
    -c 'features.shell_tool=true'
    -c 'features.view_image=true'
    -c 'features.sleep_tool=true'
    -c 'features.secret_auth_storage=false'
    -c 'features.unified_exec=true'
    -c 'features.unified_exec_tty=true'
    -c 'features.shell_snapshot=true'
    -c 'features.login_shell_package_path=false'
    -c 'features.powershell_shell_version=false'
    -c 'features.shell_snapshot_v2=false'
    -c 'features.deferred_executor=false'
    -c 'features.cwd_relative_turn_diffs=false'
    -c 'features.content_item_kinds=false'
    -c 'features.executed_tool_call_metadata=false'
    -c 'features.stable_environment_tools=false'
    -c 'features.code_mode=false'
    -c 'features.code_mode_tool_search=false'
    -c 'features.code_mode_host=false'
    -c 'features.code_mode_host_grpc=false'
    -c 'features.code_mode_prewarm=false'
    -c 'features.code_mode_interrupt=false'
    -c 'features.code_mode_tool_description_first=false'
    -c 'features.instant_interrupt=true'
    -c 'features.code_mode_only=false'
    -c 'features.code_mode_only_strict_3p_tools=false'
    -c 'features.standalone_web_search=false'
    -c 'features.runtime_metrics=false'
    -c 'features.memories=false'
    -c 'features.external_agent_memory_import=false'
    -c 'features.local_thread_store_compression=false'
    -c 'features.background_paginated_rollout_migration=false'
    -c 'features.chronicle=false'
    -c 'features.apply_patch_streaming_events=false'
    -c 'features.exec_permission_approvals=false'
    -c 'features.write_stdin_approval=true'
    -c 'features.hooks=false'
    -c 'features.request_permissions_tool=false'
    -c 'features.windows_sandbox_service=false'
    -c 'features.prefer_mxc=false'
    -c 'features.api_key_model_discovery=false'
    -c 'features.cli_daybreak=false'
    -c 'features.api_key_cyber_access_programs=false'
    -c 'features.enable_request_compression=true'
    -c 'features.unbounded_connection_retries=false'
    -c 'features.network_proxy=false'
    -c 'features.credential_masking=false'
    -c 'features.worktrees=false'
    -c 'features.respect_system_proxy=false'
    -c 'features.system_proxy_fallback=false'
    -c 'features.multi_agent=true'
    -c 'features.multi_agent_v2=false'
    -c 'features.model_catalog_in_context=false'
    -c 'features.multi_agent_v2_dynamic_tools=false'
    -c 'features.subagent_default_context_limits=false'
    -c 'features.defer_mailbox_preemption=false'
    -c 'features.agent_message_board=false'
    -c 'features.apps=false'
    -c 'features.psp=false'
    -c 'features.enable_mcp_apps=false'
    -c 'features.mcp_2026_07_28=false'
    -c 'features.codex_apps_mcp_2026_07_28=false'
    -c 'features.mcp_oauth_refresh_coordination=false'
    -c 'features.use_xaa=false'
    -c 'features.deferred_tool_world_state=false'
    -c 'features.incremental_tools=false'
    -c 'features.non_prefixed_mcp_tool_names=false'
    -c 'features.tool_suggest=false'
    -c 'features.recommended_plugins=false'
    -c 'features.plugins=false'
    -c 'features.executor_capability_discovery=false'
    -c 'features.skip_host_skill_discovery=false'
    -c 'features.remote_plugin=false'
    -c 'features.plugin_sharing=false'
    -c 'features.image_generation=false'
    -c 'features.omit_app_server_notification_media=false'
    -c 'features.image_resize_notice=false'
    -c 'features.unified_image_budget=false'
    -c 'features.concurrent_reasoning_summaries=false'
    -c 'features.output_token_replay=false'
    -c 'features.skill_mcp_dependency_install=false'
    -c 'features.skill_search=false'
    -c 'features.mentions_v2=false'
    -c 'features.default_mode_request_user_input=true'
    -c 'features.send_message_to_user_async=false'
    -c 'features.terminal_visualization_instructions=false'
    -c 'features.guardian_approval=false'
    -c 'features.guardian_reuse_parent_compaction=false'
    -c 'features.guardian_root_handoff_context=false'
    -c 'features.guardian_enhanced_node_repl_transcripts=false'
    -c 'features.guardian_node_repl_transcript_images=false'
    -c 'features.guardian_trust_orchestrator_connectors=false'
    -c 'features.guardian_conversation_history_tools=false'
    -c 'features.guardianv2=false'
    -c 'features.guardianv2_decisions_comparison=false'
    -c 'features.goals=false'
    -c 'features.token_budget=false'
    -c 'features.context_management=false'
    -c 'features.rollout_budget=false'
    -c 'features.reasoning_effort_override=false'
    -c 'features.current_time_reminder=false'
    -c 'features.nonfatal_clock_read_errors=false'
    -c 'features.tool_call_mcp_elicitation=true'
    -c 'features.auth_elicitation=false'
    -c 'features.bedrock_setup_wizard=false'
    -c 'features.artifact=false'
    -c 'features.fast_mode=false'
    -c 'features.ultrafast_mode=false'
    -c 'features.step_model_switching=false'
    -c 'features.realtime_conversation=false'
    -c 'features.prevent_idle_sleep=false'
    -c 'features.async_compaction=false'
    -c 'features.compaction_image_budget=true'
    -c 'features.retain_client_developer_messages=false'
    -c 'features.retain_client_tool_outputs=false'
    -c 'features.use_agent_identity=false'
    -c 'features.workspace_dependencies=false'
)
exec /opt/codex/bin/codex "${strict[@]}" "$@" "${overrides[@]}"
