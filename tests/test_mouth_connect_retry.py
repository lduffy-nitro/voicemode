"""The mouth waits out a TTS server that is refusing connections (Kokoro restarting)."""

from __future__ import annotations

import httpx
import numpy as np

from voice_mode.mouth import player


class FlakyServer:
    """Refuses the first ``refusals`` connections, then streams two blocks."""

    name = "flaky"
    sample_rate = 24000

    def __init__(self, refusals: int, error=httpx.ConnectError) -> None:
        self.refusals = refusals
        self.error = error
        self.calls = 0

    def stream(self, text, voice, speed):
        self.calls += 1
        if self.calls <= self.refusals:
            raise self.error("[Errno 61] Connection refused")
        yield np.zeros(10, dtype=np.float32)
        yield np.ones(5, dtype=np.float32)


def _synth(monkeypatch, backend, wait="5"):
    monkeypatch.setenv("VOICEMODE_MOUTH_CONNECT_WAIT", wait)
    monkeypatch.setattr(player, "_CONNECT_RETRY_S", 0.01)
    monkeypatch.setattr(player._backends, "resolve", lambda b, v: (backend, v))
    return player.Synth({"utt": "u1", "text": "hello", "voice": "af_sky"})


def _drain(s):
    return [b for b in s.blocks(tick=0.01) if b is not None]


def test_a_refused_connection_is_retried_until_the_server_answers(monkeypatch):
    server = FlakyServer(refusals=3)
    s = _synth(monkeypatch, server)
    blocks = _drain(s)
    assert server.calls == 4
    assert [len(b) for b in blocks] == [10, 5]
    assert s.finished and s.frames == 15


def test_it_gives_up_after_the_wait_and_reports_the_error(monkeypatch):
    server = FlakyServer(refusals=10**6)
    s = _synth(monkeypatch, server, wait="0.05")
    try:
        _drain(s)
    except httpx.ConnectError:
        pass
    else:
        raise AssertionError("expected the connection error once the wait ran out")
    assert not s.finished


def test_a_cancel_stops_the_wait(monkeypatch):
    server = FlakyServer(refusals=10**6)
    s = _synth(monkeypatch, server, wait="30")
    s.cancel()
    assert _drain(s) == []
    assert not s.finished and s.error is None


def test_other_errors_are_not_retried(monkeypatch):
    server = FlakyServer(refusals=1, error=RuntimeError)
    s = _synth(monkeypatch, server)
    try:
        _drain(s)
    except RuntimeError:
        pass
    else:
        raise AssertionError("expected the RuntimeError to surface")
    assert server.calls == 1
