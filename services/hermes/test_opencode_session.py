"""Exercise MiniMax M3 main/auxiliary streaming through the real HTTP SDK.

Run inside the built Hermes image with no network or production data mounted.
The mock relay rejects missing session headers just like OpenCode Go.
"""

import json
import unittest

import anthropic
import httpx

from agent import auxiliary_client as aux
from agent.anthropic_adapter import create_anthropic_message
from agent.chat_completion_helpers import build_api_kwargs
from agent.portal_tags import reset_conversation_context, set_conversation_context
from run_agent import AIAgent


class OpenCodeSessionTest(unittest.TestCase):
    def test_minimax_streams_and_compression_share_conversation_header(self):
        requests = []

        def relay(request):
            self.assertEqual(request.headers.get("x-opencode-session"), "conversation-root")
            self.assertEqual(request.url.path, "/zen/go/v1/messages")
            body = json.loads(request.content)
            self.assertEqual(body["model"], "minimax-m3")
            self.assertTrue(body["stream"])
            requests.append(request)
            events = [
                {"type": "message_start", "message": {
                    "id": "msg_test", "type": "message", "role": "assistant",
                    "model": "minimax-m3", "content": [], "stop_reason": None,
                    "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 0},
                }},
                {"type": "content_block_start", "index": 0,
                 "content_block": {"type": "text", "text": ""}},
                {"type": "content_block_delta", "index": 0,
                 "delta": {"type": "text_delta", "text": "OK"}},
                {"type": "content_block_stop", "index": 0},
                {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                 "usage": {"output_tokens": 1}},
                {"type": "message_stop"},
            ]
            stream = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events)
            return httpx.Response(200, headers={"content-type": "text/event-stream"}, content=stream)

        url = "https://opencode.ai/zen/go"
        messages = [{"role": "user", "content": "Return OK."}]
        agent = AIAgent(
            api_key="test-key", provider="opencode-go", model="minimax-m3",
            base_url=url, api_mode="anthropic_messages", session_id="physical-session-1",
            enabled_toolsets=[], quiet_mode=True, skip_context_files=True, skip_memory=True,
        )
        conversation_token = set_conversation_context("conversation-root")
        runtime_token = aux.set_runtime_main(
            "opencode-go", "minimax-m3", base_url=url, session_id="physical-session-1"
        )
        try:
            with anthropic.Anthropic(
                api_key="test-key", base_url=url, max_retries=0,
                http_client=httpx.Client(transport=httpx.MockTransport(relay)),
            ) as client:
                first = create_anthropic_message(client, build_api_kwargs(agent, messages))
                self.assertEqual(first.content[0].text, "OK")
                auxiliary = aux.AnthropicAuxiliaryClient(client, "minimax-m3", "test-key", url)
                compressed = auxiliary.chat.completions.create(**aux._build_call_kwargs(
                    "opencode-go", "minimax-m3", messages, base_url=url
                ))
                self.assertEqual(compressed.choices[0].message.content, "OK")
                # Compression may rotate the physical session; the root stays stable.
                agent.session_id = "physical-session-2"
                following = create_anthropic_message(client, build_api_kwargs(agent, messages))
                self.assertEqual(following.content[0].text, "OK")
            self.assertEqual(len(requests), 3)
        finally:
            aux._RUNTIME_MAIN_CONTEXT.reset(runtime_token)
            reset_conversation_context(conversation_token)


if __name__ == "__main__":
    unittest.main()
