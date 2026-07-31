#!/usr/bin/env python3
"""Black-box tests for the native TTS protocol stub."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BINARY = Path(os.environ.get("TTS_HELPER_STUB", ROOT / "build" / "tts_helper_stub"))


class StubTests(unittest.TestCase):
    def invoke(self, *args, input_text=None):
        return subprocess.run(
            [str(BINARY), *args],
            input=input_text,
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )

    def run_protocol(self, requests):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            output = directory / "responses.jsonl"
            spool = directory / "spool"
            log = directory / "helper.log"
            spool.mkdir()
            command = [
                "--models", str(directory / "models"),
                "--out", str(output),
                "--spool", str(spool),
                "--log", str(log),
                "--threads", "4",
                "--idle", "300",
                "--protocol", "1",
            ]
            result = self.invoke(*command, input_text=requests)
            lines = output.read_text(encoding="utf-8").splitlines()
            return result, [json.loads(line) for line in lines]

    def run_protocol_bytes(self, requests):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            output = directory / "responses.jsonl"
            spool = directory / "spool"
            log = directory / "helper.log"
            spool.mkdir()
            command = [
                str(BINARY),
                "--models", str(directory / "models"),
                "--out", str(output),
                "--spool", str(spool),
                "--log", str(log),
                "--threads", "4",
                "--idle", "300",
                "--protocol", "1",
            ]
            result = subprocess.run(
                command,
                input=requests,
                text=False,
                capture_output=True,
                check=False,
                timeout=5,
            )
            response_text = output.read_bytes().decode("utf-8", errors="strict")
            return result, [
                json.loads(line) for line in response_text.splitlines()
            ]

    def test_metadata_flags_report_stable_values(self):
        version = self.invoke("--version")
        protocol = self.invoke("--protocol-version")

        self.assertEqual(version.returncode, 0, version.stderr)
        self.assertEqual(version.stdout, "godot-pet-tts-helper 0.1.0\n")
        self.assertEqual(protocol.returncode, 0, protocol.stderr)
        self.assertEqual(protocol.stdout, "1\n")

    def test_self_test_reports_stub_health(self):
        result = self.invoke("--self-test")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {"ok": True, "protocol": 1, "engine": "unavailable"},
        )

    def test_say_and_clone_get_exactly_one_correlated_engine_error(self):
        result, events = self.run_protocol(
            '{"op":"say","id":41,"text":"hello"}\n'
            '{"op":"clone","id":42,"wav":"/tmp/in.wav","out":"/tmp/v.emb"}\n'
            '{"op":"quit"}\n'
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(events[0]["event"], "ready")
        self.assertEqual(events[1], {
            "event": "error",
            "id": 41,
            "op": "say",
            "code": "engine_unavailable",
            "message": "qwen engine is not linked",
        })
        self.assertEqual(events[2], {
            "event": "error",
            "id": 42,
            "op": "clone",
            "code": "engine_unavailable",
            "message": "qwen engine is not linked",
        })
        self.assertEqual(events[3], {"event": "bye"})
        self.assertEqual(len(events), 4)

    def test_json_whitespace_only_say_gets_one_empty_error(self):
        result, events = self.run_protocol(
            '{"op":"say","id":43,"text":" \\t\\r\\n"}\n'
            '{"op":"quit"}\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events[1], {
            "event": "error",
            "id": 43,
            "op": "say",
            "code": "empty",
            "message": "nothing to say",
        })
        self.assertEqual(events[2], {"event": "bye"})
        self.assertEqual(len(events), 3)

    def test_malformed_requests_emit_errors_and_processing_continues(self):
        result, events = self.run_protocol(
            '{"op":"say","id":1,\n'
            '["not", "an", "object"]\n'
            '{"id":2}\n'
            '{"op":"say","id":3,"text":"still alive"}\n'
            '{"op":"quit"}\n'
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [event.get("code") for event in events[1:4]],
            ["malformed_request", "malformed_request", "malformed_request"],
        )
        self.assertEqual(events[4]["id"], 3)
        self.assertEqual(events[4]["code"], "engine_unavailable")
        self.assertEqual(events[5], {"event": "bye"})

    def test_malformed_object_fields_preserve_available_correlation(self):
        result, events = self.run_protocol(
            '{"op":"say"}\n'
            '{"op":"say","id":"7"}\n'
            '{"id":8}\n'
            '{"op":3,"id":9}\n'
            '{"op":"dance","id":10}\n'
            '{"op":"quit"}\n'
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        errors = events[1:6]
        self.assertEqual(
            [(event["id"], event["op"], event["code"]) for event in errors],
            [
                (0, "say", "malformed_request"),
                (0, "say", "malformed_request"),
                (8, "request", "malformed_request"),
                (9, "request", "malformed_request"),
                (10, "dance", "malformed_request"),
            ],
        )
        self.assertEqual(events[6], {"event": "bye"})

    def test_invalid_raw_utf8_is_rejected_and_responses_stay_valid_utf8(self):
        invalid_lines = {
            "overlong": b'{"op":"bad\xc0\xaf","id":9}\n',
            "isolated continuation": b'{"op":"bad\x80","id":9}\n',
            "surrogate code point": b'{"op":"bad\xed\xa0\x80","id":9}\n',
            "above U+10FFFF": b'{"op":"bad\xf4\x90\x80\x80","id":9}\n',
            "truncated": b'{"op":"bad\xe2\x82\n',
        }

        for label, invalid_line in invalid_lines.items():
            with self.subTest(label=label):
                requests = (
                    invalid_line +
                    b'{"op":"say","id":10,"text":"still alive"}\n'
                    b'{"op":"quit"}\n'
                )
                result, events = self.run_protocol_bytes(requests)

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(events[1]["id"], 0)
                self.assertEqual(events[1]["op"], "request")
                self.assertEqual(events[1]["code"], "malformed_request")
                self.assertEqual(events[2]["id"], 10)
                self.assertEqual(events[2]["op"], "say")
                self.assertEqual(events[2]["code"], "engine_unavailable")
                self.assertEqual(events[3], {"event": "bye"})

    def test_cancel_unload_and_quit_are_accepted(self):
        result, events = self.run_protocol(
            '{"op":"cancel"}\n'
            '{"op":"unload"}\n'
            '{"op":"quit"}\n'
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, [
            {"event": "ready", "protocol": 1, "engine": "unavailable"},
            {"event": "bye"},
        ])

    def test_op_must_be_non_empty_but_literal_request_is_unknown(self):
        result, events = self.run_protocol(
            '{"op":"","id":81}\n'
            '{"op":"request","id":82}\n'
            '{"op":"quit"}\n'
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [(event["id"], event["op"], event["code"]) for event in events[1:3]],
            [
                (81, "request", "malformed_request"),
                (82, "request", "malformed_request"),
            ],
        )
        self.assertIn("no non-empty string op", events[1]["message"])
        self.assertIn("unknown op: request", events[2]["message"])

    def test_escaped_quotes_and_traditional_chinese_utf8_are_valid(self):
        result, events = self.run_protocol(
            '{"op":"say","id":77,'
            '"text":"他說：「你好，\\\\\\"朋友\\\\\\"」"}\n'
            '{"op":"quit"}\n'
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events[1]["event"], "error")
        self.assertEqual(events[1]["id"], 77)
        self.assertEqual(events[1]["op"], "say")
        self.assertEqual(events[1]["code"], "engine_unavailable")
        self.assertEqual(events[2], {"event": "bye"})

    def test_eof_exits_cleanly(self):
        result, events = self.run_protocol("")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events, [
            {"event": "ready", "protocol": 1, "engine": "unavailable"},
            {"event": "bye"},
        ])


if __name__ == "__main__":
    unittest.main(verbosity=2)
