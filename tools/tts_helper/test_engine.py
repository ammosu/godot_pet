#!/usr/bin/env python3
"""Black-box tests for the engine-backed helper using the fake qwen C API."""

import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import unittest
import wave


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BINARY = Path(os.environ.get("TTS_HELPER_FAKE", ROOT / "build" / "tts_helper_fake"))


def write_reference(path, amplitude):
    samples = [amplitude, -amplitude] * 64
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(24000)
        output.writeframes(struct.pack("<%dh" % len(samples), *samples))


class EngineHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(
            [str(HERE / "build_fake.sh"), str(BINARY)],
            check=True,
            capture_output=True,
            text=True,
        )

    def run_protocol(self, directory, requests, model_name="models", idle="300",
                     extra=()):
        models = directory / model_name
        models.mkdir(exist_ok=True)
        output = directory / ("responses-" + model_name + ".jsonl")
        spool = directory / ("spool-" + model_name)
        log = directory / ("helper-" + model_name + ".log")
        command = [
            str(BINARY),
            "--models", str(models),
            "--out", str(output),
            "--spool", str(spool),
            "--log", str(log),
            "--threads", "4",
            "--idle", idle,
            "--protocol", "1",
            *extra,
        ]
        result = subprocess.run(
            command,
            input=requests,
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )
        events = [
            json.loads(line)
            for line in output.read_text(encoding="utf-8").splitlines()
        ]
        return result, events, models, log

    def start_protocol(self, directory, idle="300"):
        models = directory / "models"
        models.mkdir(exist_ok=True)
        output = directory / "responses.jsonl"
        spool = directory / "spool"
        log = directory / "helper.log"
        command = [
            str(BINARY),
            "--models", str(models),
            "--out", str(output),
            "--spool", str(spool),
            "--log", str(log),
            "--threads", "4",
            "--idle", idle,
            "--protocol", "1",
        ]
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return process, output, spool, models

    def wait_for(self, predicate, message):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.01)
        self.fail(message)

    @staticmethod
    def read_events(path):
        if not path.exists():
            return []
        return [
            json.loads(line)
            for line in path.read_text(encoding="utf-8").splitlines()
        ]

    def test_metadata_identifies_fake_linked_adapter(self):
        result = subprocess.run(
            [str(BINARY), "--self-test"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {"ok": True, "protocol": 1, "engine": "fake-qwen"},
        )

    def test_clone_embedding_then_say_writes_pcm16_wav(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            reference = directory / "reference.wav"
            embedding = directory / "voices" / "我的聲音.emb"
            write_reference(reference, 12000)
            requests = "\n".join([
                json.dumps({
                    "op": "clone",
                    "id": 1,
                    "wav": str(reference),
                    "out": str(embedding),
                }, ensure_ascii=False),
                json.dumps({
                    "op": "say",
                    "id": 2,
                    "text": "繁體中文與「跳脫」",
                    "lang": "zh",
                    "voice": str(embedding),
                }, ensure_ascii=False),
                '{"op":"quit"}',
                "",
            ])
            result, events, _, _ = self.run_protocol(directory, requests)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(events[0]["event"], "ready")
            self.assertEqual(events[1], {
                "event": "cloned",
                "id": 1,
                "path": str(embedding),
                "dims": 4,
            })
            self.assertEqual(events[2]["event"], "audio")
            self.assertEqual(events[2]["id"], 2)
            self.assertEqual(events[2]["rate"], 24000)
            self.assertEqual(events[2]["samples"], 7)
            self.assertEqual(events[3], {"event": "bye"})

            magic, version, dimensions, *values = struct.unpack(
                "<4sII4f", embedding.read_bytes()
            )
            self.assertEqual((magic, version, dimensions), (b"Q3EM", 1, 4))
            self.assertEqual(values, [0.125, -0.25, 0.5, 1.0])

            audio_path = Path(events[2]["path"])
            with wave.open(str(audio_path), "rb") as audio:
                self.assertEqual(audio.getnchannels(), 1)
                self.assertEqual(audio.getsampwidth(), 2)
                self.assertEqual(audio.getframerate(), 24000)
                self.assertEqual(audio.getnframes(), 7)
                pcm = struct.unpack("<7h", audio.readframes(7))
            self.assertEqual(pcm[-2:], (32767, -32768))

    def test_language_mapping_uses_qwen_traditional_chinese_id(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result, events, _, _ = self.run_protocol(
                directory,
                '{"op":"say","id":8,"text":"EXPECT_ZH","lang":"zh"}\n'
                '{"op":"quit"}\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events[1]["event"], "audio")
            self.assertEqual(events[1]["id"], 8)

    def test_runaway_limits_reach_the_engine(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result, events, _, _ = self.run_protocol(
                directory,
                '{"op":"say","id":9,"text":"REPORT_LIMITS"}\n'
                '{"op":"quit"}\n',
                extra=("--max-tokens", "512", "--temperature", "0.5"),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events[1]["event"], "error")
            self.assertEqual(events[1]["id"], 9)
            self.assertIn("max_audio_tokens=512", events[1]["message"])
            self.assertIn("temperature=0.500000", events[1]["message"])

    def test_omitted_limits_leave_the_library_defaults(self):
        """The flags are optional, and omitting them must be the library's own
        defaults rather than a zero — 0 tokens synthesises nothing and
        temperature 0 is greedy decoding, which never draws EOS at all."""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result, events, _, _ = self.run_protocol(
                directory,
                '{"op":"say","id":10,"text":"REPORT_LIMITS"}\n'
                '{"op":"quit"}\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events[1]["event"], "error")
            self.assertIn("max_audio_tokens=4096", events[1]["message"])
            self.assertIn("temperature=0.900000", events[1]["message"])

    def test_negative_limits_are_refused_at_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for flag, value in (("--max-tokens", "-1"), ("--temperature", "-0.5")):
                result = subprocess.run(
                    [
                        str(BINARY),
                        "--models", str(directory),
                        "--out", str(directory / "out.jsonl"),
                        "--spool", str(directory / "spool"),
                        "--log", str(directory / "helper.log"),
                        "--threads", "4",
                        "--idle", "300",
                        "--protocol", "1",
                        flag, value,
                    ],
                    input="",
                    text=True,
                    capture_output=True,
                    check=False,
                    timeout=10,
                )
                self.assertNotEqual(result.returncode, 0, flag)
                self.assertIn(flag, result.stderr)

    def test_json_whitespace_only_say_gets_exactly_one_empty_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            requests = (
                '{"op":"say","id":801,"text":" \\t\\r\\n"}\n'
                '{"op":"quit"}\n'
            )
            result, events, models, _ = self.run_protocol(directory, requests)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events, [
                {"event": "ready", "protocol": 1, "engine": "fake-qwen"},
                {
                    "event": "error",
                    "id": 801,
                    "op": "say",
                    "code": "empty",
                    "message": "nothing to say",
                },
                {"event": "bye"},
            ])
            self.assertFalse((models / "fake_engine_trace").exists())

    def test_silent_clone_is_rejected_before_engine(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            reference = directory / "silence.wav"
            write_reference(reference, 0)
            result, events, _, _ = self.run_protocol(
                directory,
                json.dumps({
                    "op": "clone",
                    "id": 9,
                    "wav": str(reference),
                    "out": str(directory / "silent.emb"),
                }) + '\n{"op":"quit"}\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events[1]["code"], "silent")
            self.assertEqual(events[1]["id"], 9)

    def test_cancel_answers_every_accepted_say_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            requests = "".join(
                json.dumps({"op": "say", "id": request_id, "text": "queued"}) + "\n"
                for request_id in range(10, 30)
            )
            requests += '{"op":"cancel"}\n{"op":"quit"}\n'
            result, events, _, _ = self.run_protocol(directory, requests)
            self.assertEqual(result.returncode, 0, result.stderr)
            terminals = [
                event for event in events
                if event.get("event") in {"audio", "error"}
            ]
            self.assertEqual(sorted(event["id"] for event in terminals), list(range(10, 30)))
            self.assertEqual(len(terminals), 20)
            self.assertTrue(all(
                event["event"] == "audio" or event.get("code") == "cancelled"
                for event in terminals
            ))
            self.assertEqual(events[-1], {"event": "bye"})

    def test_engine_failure_is_correlated_and_processing_continues(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result, events, _, _ = self.run_protocol(
                directory,
                '{"op":"say","id":31,"text":"FAIL"}\n'
                '{"op":"say","id":32,"text":"still alive"}\n'
                '{"op":"quit"}\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events[1]["id"], 31)
            self.assertEqual(events[1]["code"], "engine_error")
            self.assertEqual(events[2]["event"], "audio")
            self.assertEqual(events[2]["id"], 32)

    def test_load_failure_still_terminates_each_request(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result, events, _, _ = self.run_protocol(
                directory,
                '{"op":"say","id":41,"text":"one"}\n'
                '{"op":"clone","id":42,"wav":"/missing.wav","out":"/tmp/x.emb"}\n'
                '{"op":"quit"}\n',
                model_name="fail-load",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            terminals = [event for event in events if event.get("id") in {41, 42}]
            self.assertEqual([event["id"] for event in terminals], [41, 42])
            self.assertTrue(all(event["code"] == "engine_error" for event in terminals))

    def test_engine_is_lazy_and_unload_allows_reload(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result, events, models, _ = self.run_protocol(
                directory,
                '{"op":"unload"}\n'
                '{"op":"say","id":51,"text":"first"}\n'
                '{"op":"unload"}\n'
                '{"op":"say","id":52,"text":"second"}\n'
                '{"op":"quit"}\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                [event["id"] for event in events if event.get("event") == "audio"],
                [51, 52],
            )
            self.assertEqual(
                (models / "fake_engine_trace").read_text(encoding="utf-8").splitlines(),
                ["load", "unload", "load", "unload"],
            )

    def test_idle_zero_unloads_and_later_request_reloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            process, output, _, models = self.start_protocol(directory, idle="0")
            process.stdin.write('{"op":"say","id":53,"text":"first"}\n')
            process.stdin.flush()
            self.wait_for(
                lambda: any(
                    event.get("id") == 53 for event in self.read_events(output)
                ),
                "first request did not finish",
            )
            trace = models / "fake_engine_trace"
            self.wait_for(
                lambda: trace.exists() and "unload" in trace.read_text().splitlines(),
                "idle timeout did not unload engine",
            )
            process.stdin.write(
                '{"op":"say","id":54,"text":"second"}\n{"op":"quit"}\n'
            )
            process.stdin.flush()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stdout, "")
            self.assertEqual(
                [event["id"] for event in self.read_events(output)
                 if event.get("event") == "audio"],
                [53, 54],
            )
            self.assertEqual(
                trace.read_text(encoding="utf-8").splitlines(),
                ["load", "unload", "load", "unload"],
            )

    def test_cancel_during_synthesis_only_drops_queued_request(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            process, output, _, models = self.start_protocol(directory)
            process.stdin.write('{"op":"say","id":61,"text":"SLOW"}\n')
            process.stdin.flush()
            trace = models / "fake_engine_trace"
            self.wait_for(
                lambda: trace.exists() and "slow-start" in trace.read_text().splitlines(),
                "slow synthesis did not start",
            )
            process.stdin.write(
                '{"op":"say","id":62,"text":"queued"}\n'
                '{"op":"cancel"}\n{"op":"quit"}\n'
            )
            process.stdin.flush()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stdout, "")
            terminals = {
                event["id"]: event for event in self.read_events(output)
                if event.get("id") in {61, 62}
            }
            self.assertEqual(terminals[61]["event"], "audio")
            self.assertEqual(terminals[62]["code"], "cancelled")
            self.assertEqual(len(terminals), 2)

    def test_eof_drains_work_and_shuts_down(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result, events, models, _ = self.run_protocol(
                directory, '{"op":"say","id":63,"text":"eof"}\n'
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events[1]["event"], "audio")
            self.assertEqual(events[-1], {"event": "bye"})
            self.assertEqual(
                (models / "fake_engine_trace").read_text().splitlines(),
                ["load", "unload"],
            )

    def test_engine_exception_is_terminal_and_processing_continues(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result, events, _, _ = self.run_protocol(
                directory,
                '{"op":"say","id":64,"text":"THROW"}\n'
                '{"op":"say","id":65,"text":"still alive"}\n'
                '{"op":"quit"}\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events[1]["code"], "internal_error")
            self.assertEqual(events[1]["id"], 64)
            self.assertEqual(events[2]["event"], "audio")
            self.assertEqual(events[2]["id"], 65)

    def test_invalid_sample_rate_is_rejected_without_replacing_old_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            spool = directory / "spool-models"
            spool.mkdir()
            old = spool / "66.wav"
            old.write_bytes(b"old audio")
            result, events, _, _ = self.run_protocol(
                directory,
                '{"op":"say","id":66,"text":"BAD_RATE"}\n{"op":"quit"}\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events[1]["code"], "write_failed")
            self.assertEqual(old.read_bytes(), b"old audio")

    def test_invalid_embedding_bounds_and_truncation_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            voices = []
            for name, dimensions, body in [
                ("zero.emb", 0, b""),
                ("over.emb", 4097, b""),
                ("short.emb", 4, struct.pack("<f", 1.0)),
                ("nan.emb", 1, struct.pack("<f", float("nan"))),
                ("positive-inf.emb", 1, struct.pack("<f", float("inf"))),
                ("negative-inf.emb", 1, struct.pack("<f", float("-inf"))),
                ("trailing.emb", 1, struct.pack("<f", 1.0) + b"x"),
            ]:
                path = directory / name
                path.write_bytes(b"Q3EM" + struct.pack("<II", 1, dimensions) + body)
                voices.append(path)
            requests = "".join(
                json.dumps({
                    "op": "say", "id": 70 + index,
                    "text": "voice", "voice": str(path),
                }) + "\n"
                for index, path in enumerate(voices)
            ) + '{"op":"quit"}\n'
            result, events, _, _ = self.run_protocol(directory, requests)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected_ids = set(range(70, 70 + len(voices)))
            errors = [event for event in events if event.get("id") in expected_ids]
            self.assertEqual(
                [event["code"] for event in errors],
                ["invalid_voice"] * len(voices),
            )

    def test_nonfinite_engine_embedding_does_not_replace_existing_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            reference = directory / "BAD_EMBEDDING_NAN.wav"
            write_reference(reference, 12000)
            output = directory / "voice.emb"
            output.write_bytes(b"existing embedding")
            result, events, _, _ = self.run_protocol(
                directory,
                json.dumps({
                    "op": "clone", "id": 77, "wav": str(reference),
                    "out": str(output),
                }) + '\n{"op":"quit"}\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events[1]["id"], 77)
            self.assertEqual(events[1]["code"], "write_failed")
            self.assertIn("non-finite", events[1]["message"])
            self.assertEqual(output.read_bytes(), b"existing embedding")

    def test_invalid_audio_result_is_freed_by_raii_error_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result, events, models, _ = self.run_protocol(
                directory,
                '{"op":"say","id":78,"text":"BAD_AUDIO"}\n{"op":"quit"}\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(events[1]["id"], 78)
            self.assertEqual(events[1]["code"], "engine_error")
            self.assertEqual(
                (models / "fake_engine_trace").read_text().splitlines(),
                ["load", "audio-free", "unload"],
            )

    def test_nonfinite_audio_is_freed_and_never_replaces_old_wav(self):
        for text in ("BAD_AUDIO_NAN", "BAD_AUDIO_INF"):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                spool = directory / "spool-models"
                spool.mkdir()
                old_output = spool / "79.wav"
                old_output.write_bytes(b"existing wav")
                result, events, models, _ = self.run_protocol(
                    directory,
                    json.dumps({"op": "say", "id": 79, "text": text}) +
                    '\n{"op":"quit"}\n',
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(events[1]["id"], 79)
                self.assertEqual(events[1]["code"], "write_failed")
                self.assertIn("non-finite", events[1]["message"])
                self.assertEqual(old_output.read_bytes(), b"existing wav")
                self.assertEqual(
                    (models / "fake_engine_trace").read_text().splitlines(),
                    ["load", "audio-free", "unload"],
                )

    def test_malformed_wav_chunks_are_bounded_and_fail_open(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            huge = directory / "huge.wav"
            huge.write_bytes(
                b"RIFF" + struct.pack("<I", 12) + b"WAVEfmt " +
                struct.pack("<I", 0xFFFFFFFF)
            )
            truncated = directory / "truncated.wav"
            truncated.write_bytes(
                b"RIFF" + struct.pack("<I", 20) + b"WAVEfmt " +
                struct.pack("<I", 16) + b"\x01\x00"
            )
            requests = "".join(
                json.dumps({
                    "op": "clone", "id": 73 + index,
                    "wav": str(path), "out": str(directory / f"{index}.emb"),
                }) + "\n"
                for index, path in enumerate([huge, truncated])
            ) + '{"op":"quit"}\n'
            result, events, _, _ = self.run_protocol(directory, requests)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                [event["event"] for event in events if event.get("id") in {73, 74}],
                ["cloned", "cloned"],
            )

    def test_symlink_outputs_are_refused_and_temp_name_is_not_predictable(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            spool = directory / "spool-models"
            spool.mkdir()
            victim = directory / "victim"
            victim.write_bytes(b"do not replace")
            (spool / "80.wav").symlink_to(victim)
            regular_target = spool / "81.wav"
            regular_target.write_bytes(b"old audio")
            predictable = spool / "81.wav.part"
            predictable.write_bytes(b"sentinel")
            reference = directory / "reference.wav"
            write_reference(reference, 12000)
            clone_link = directory / "voice.emb"
            clone_link.symlink_to(victim)
            result, events, _, _ = self.run_protocol(
                directory,
                '{"op":"say","id":80,"text":"symlink"}\n'
                '{"op":"say","id":81,"text":"regular"}\n' +
                json.dumps({
                    "op": "clone", "id": 82, "wav": str(reference),
                    "out": str(clone_link),
                }) + '\n{"op":"quit"}\n',
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            by_id = {event.get("id"): event for event in events}
            self.assertEqual(by_id[80]["code"], "write_failed")
            self.assertEqual(by_id[81]["event"], "audio")
            self.assertEqual(by_id[82]["code"], "write_failed")
            self.assertEqual(victim.read_bytes(), b"do not replace")
            self.assertTrue((spool / "80.wav").is_symlink())
            self.assertTrue(clone_link.is_symlink())
            self.assertTrue(regular_target.read_bytes().startswith(b"RIFF"))
            self.assertEqual(predictable.read_bytes(), b"sentinel")
            self.assertEqual(
                [path.name for path in spool.iterdir() if ".part." in path.name],
                [],
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
