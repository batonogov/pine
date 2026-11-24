#!/bin/sh
# Sanitized fake official Claude ACP adapter for deterministic spawn tests.
# It speaks the tagged v0.109.1 ACP v1 shapes without provider auth or quota.

scenario="${2:-${1:-turn}}"
answered_form=0
answered_permission=0
prompt_count=0

reply() {
  printf '%s\n' "$1"
}

INIT_RESULT='{"id":0,"jsonrpc":"2.0","result":{"agentCapabilities":{"loadSession":true},"agentInfo":{"name":"@agentclientprotocol/claude-agent-acp","version":"0.109.1"},"protocolVersion":1}}'
NEW_RESULT='{"id":1,"jsonrpc":"2.0","result":{"configOptions":[],"sessionId":"ses_fake"}}'
COMMANDS='{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_fake","update":{"availableCommands":[],"sessionUpdate":"available_commands_update"}}}'
CHUNK='{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_fake","update":{"content":{"text":"Fixture result.","type":"text"},"sessionUpdate":"agent_message_chunk"}}}'
FORM='{"jsonrpc":"2.0","id":"form","method":"elicitation/create","params":{"mode":"form","sessionId":"ses_fake","toolCallId":"question-tool","message":"Which color?","requestedSchema":{"type":"object","required":["color"],"properties":{"color":{"type":"string","oneOf":[{"const":"blue"}]}}}}}'
PERMISSION='{"jsonrpc":"2.0","id":"permission","method":"session/request_permission","params":{"sessionId":"ses_fake","toolCall":{"toolCallId":"write-1","title":"Write fixture","kind":"edit"},"options":[{"optionId":"once","kind":"allow_once"},{"optionId":"reject","kind":"reject_once"}]}}'
QUESTION_DONE='{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_fake","update":{"sessionUpdate":"tool_call_update","toolCallId":"question-tool","status":"completed"}}}'
WRITE_DONE='{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_fake","update":{"sessionUpdate":"tool_call_update","toolCallId":"write-1","status":"completed"}}}'
FULL_RESULT='{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ses_fake","update":{"content":{"text":"Fake complete.","type":"text"},"sessionUpdate":"agent_message_chunk"}}}'

# JSONEncoder may escape '/', so match the method's prefix and final component.
while IFS= read -r line; do
  case "$line" in
    *'"method":"initialize"'*)
      reply "$INIT_RESULT"
      ;;
    *'"method":"session'*'new"'*)
      reply "$NEW_RESULT"
      reply "$COMMANDS"
      ;;
    *'"method":"session'*'prompt"'*)
      prompt_count=$((prompt_count + 1))
      if [ "$scenario" = "full" ]; then
        if [ "$prompt_count" -eq 1 ]; then
          reply "$FORM"
          reply "$PERMISSION"
        fi
      else
        reply "$CHUNK"
        if [ "$scenario" = "turn" ]; then
          reply '{"id":2,"jsonrpc":"2.0","result":{"stopReason":"end_turn"}}'
        fi
      fi
      ;;
    *'"method":"session'*'cancel"'*)
      if [ "$scenario" = "full" ]; then
        reply '{"id":3,"jsonrpc":"2.0","result":{"stopReason":"cancelled"}}'
      else
        reply '{"id":2,"jsonrpc":"2.0","result":{"stopReason":"cancelled"}}'
      fi
      ;;
    *'"id":"form"'*)
      answered_form=1
      ;;
    *'"id":"permission"'*)
      answered_permission=1
      ;;
  esac
  if [ "$answered_form" -eq 1 ] && [ "$answered_permission" -eq 1 ]; then
    answered_form=2
    reply "$QUESTION_DONE"
    reply "$WRITE_DONE"
    reply "$FULL_RESULT"
    reply '{"id":2,"jsonrpc":"2.0","result":{"stopReason":"end_turn"}}'
  fi
done
