#!/bin/bash
# Step 6: testes pytest no arquivo do David (appending na suíte existente, seguindo helpers dele)
set -e
python3 - <<'PYEOF'
path = "tests/gateway/test_homeassistant.py"
code = open(path).read()

# Ver helpers existentes pra reusar o estilo
assert "_make_deliver_adapter" in code, "helper do David deve existir"

tests = '''

# ---------------------------------------------------------------------------
# Session-integrated delivery (deliver_mode, issue #35060 follow-up)
# ---------------------------------------------------------------------------


def _make_session_mode_adapter(**extra) -> HomeAssistantAdapter:
    """Adapter for session-mode tests: no network, deliver:whatsapp by default."""
    config = PlatformConfig(enabled=True, token="tok", extra=extra)
    return HomeAssistantAdapter(config)


class _Entry:
    """Minimal SessionEntry stand-in for store fakes."""

    def __init__(self, session_key, chat_id, updated_at=1):
        self.session_key = session_key
        self.session_id = session_key
        self.updated_at = updated_at
        self.origin = SessionSource(
            platform=Platform.WHATSAPP, chat_id=chat_id, chat_type="group",
            user_id="u1", user_name="Tester",
        )


class _Store:
    def __init__(self, entries):
        self._entries = entries

    def list_sessions(self, active_minutes=None):
        return list(self._entries)


class _RecordingAdapter:
    """Target adapter fake: records handle_message / send calls."""

    def __init__(self, accept=True):
        self.accept = accept
        self.handled = []
        self.sent = []

    async def handle_message(self, event):
        self.handled.append(event)
        if self.accept:
            event._gateway_accepted = True

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        self.sent.append((chat_id, content))
        return SendResult(success=True, message_id="bc-1")


class _Runner:
    """GatewayRunner stand-in: profile-scoped adapter + home channel + store."""

    def __init__(self, adapter, store, home_chat_id="G"):
        self._adapter = adapter
        self.session_store = store
        self.home_chat_id = home_chat_id

    def _authorization_adapter(self, platform, profile):
        return self._adapter

    class _cfg:
        @staticmethod
        def get_home_channel(platform):
            return None

    config = _cfg()

    def home(self):
        class _h:
            chat_id = self.home_chat_id
        return _h()


def _wire_session_mode(adapter, runner, home):
    adapter.gateway_runner = runner
    adapter._owner_profile = None
    runner.config.get_home_channel = staticmethod(lambda p, _h=home: _h)


def test_deliver_mode_defaults_to_broadcast():
    adapter = _make_session_mode_adapter(watch_domains=["zone"], deliver="whatsapp")
    assert adapter.resolve_deliver_mode("zone.x") == "broadcast"


def test_deliver_mode_top_level_session():
    adapter = _make_session_mode_adapter(deliver="whatsapp", deliver_mode="session")
    assert adapter.resolve_deliver_mode("sensor.any") == "session"


def test_deliver_mode_per_entry_overrides_domain_and_top():
    adapter = _make_session_mode_adapter(
        deliver="whatsapp", deliver_mode="session",
        watch_entities=[{"alarm_control_panel.x": {"deliver_mode": "broadcast"}}],
    )
    assert adapter.resolve_deliver_mode("alarm_control_panel.x") == "broadcast"
    assert adapter.resolve_deliver_mode("sensor.other") == "session"


def test_deliver_mode_invalid_falls_back_to_broadcast():
    adapter = _make_session_mode_adapter(deliver="whatsapp", deliver_mode="banana")
    assert adapter._default_deliver_mode == "broadcast"


def test_handle_event_tag_carries_session_suffix():
    adapter = _make_session_mode_adapter(
        watch_entities=["sensor.s"], deliver="whatsapp", deliver_mode="session",
    )
    target = adapter.resolve_deliver_target("sensor.s")
    mode = adapter.resolve_deliver_mode("sensor.s")
    tag = f"ha_events:{target}" + (";session" if mode == "session" else "")
    assert tag == "ha_events:whatsapp;session"


@pytest.mark.asyncio
async def test_session_mode_injects_internal_event_with_guards():
    """Session mode: event reaches the target session via admit_internal_event with
    internal=True and allow_gateway_control=False (untrusted text stays conversational)."""
    adapter = _make_session_mode_adapter(deliver="whatsapp", deliver_mode="session")
    wa = _RecordingAdapter()
    entry = _Entry("agent:main:whatsapp:group:G:u1", "G")
    runner = _Runner(wa, _Store([entry]))
    _wire_session_mode(adapter, runner, runner.home())

    result = await adapter.send("ha_events:whatsapp;session", "portao opened")

    assert result.success
    # The injection must actually have happened — fail if handle_message was skipped.
    assert wa.handled, "session mode must inject via admit_internal_event (handle_message)"
    assert not wa.sent, "session mode must not double-deliver via broadcast"
    event = wa.handled[0]
    assert event.internal is True
    assert event.allow_gateway_control is False
    assert event.metadata["hermes_cross_platform_delivery"] is True
    assert event.metadata["gateway_session_key"] == entry.session_key
    assert "[Home Assistant] portao opened" in event.text
    assert event.source.chat_id == "G"


@pytest.mark.asyncio
async def test_session_mode_omitted_injection_fails_the_assertion():
    """Guard against vacuous tests: broadcast tag (no ;session) must NOT inject."""
    adapter = _make_session_mode_adapter(deliver="whatsapp")
    wa = _RecordingAdapter()
    entry = _Entry("agent:main:whatsapp:group:G:u1", "G")
    runner = _Runner(wa, _Store([entry]))
    _wire_session_mode(adapter, runner, runner.home())

    result = await adapter.send("ha_events:whatsapp", "plain broadcast")

    assert result.success
    assert not wa.handled, "broadcast mode must not inject"
    assert wa.sent, "broadcast mode must deliver via adapter.send"


@pytest.mark.asyncio
async def test_session_mode_without_prior_session_falls_back_to_broadcast():
    adapter = _make_session_mode_adapter(deliver="whatsapp", deliver_mode="session")
    wa = _RecordingAdapter()
    runner = _Runner(wa, _Store([]))
    _wire_session_mode(adapter, runner, runner.home())

    result = await adapter.send("ha_events:whatsapp;session", "event")

    assert result.success
    assert not wa.handled
    assert wa.sent and wa.sent[0][0] == "G"


@pytest.mark.asyncio
async def test_session_mode_injection_not_accepted_falls_back_to_broadcast():
    """admit_internal_event raises WakeNotAccepted when the adapter does not accept:
    delivery must degrade to broadcast, never drop."""
    adapter = _make_session_mode_adapter(deliver="whatsapp", deliver_mode="session")
    wa = _RecordingAdapter(accept=False)
    entry = _Entry("agent:main:whatsapp:group:G:u1", "G")
    runner = _Runner(wa, _Store([entry]))
    _wire_session_mode(adapter, runner, runner.home())

    result = await adapter.send("ha_events:whatsapp;session", "event")

    assert result.success
    assert wa.handled  # injection was attempted
    assert wa.sent  # and broadcast picked it up


@pytest.mark.asyncio
async def test_session_mode_without_runner_falls_back_to_ha_notification(monkeypatch):
    adapter = _make_session_mode_adapter(deliver="whatsapp", deliver_mode="session")
    adapter.gateway_runner = None
    monkeypatch.setattr(
        HomeAssistantAdapter, "_send_ha_notification",
        AsyncMock(return_value=SendResult(success=True, message_id="ha-1")),
    )
    result = await adapter.send("ha_events:whatsapp;session", "event")
    assert result.success and result.message_id == "ha-1"


@pytest.mark.asyncio
async def test_session_mode_selects_most_recent_session_for_chat():
    """Owner-only selection: when several sessions exist for the chat (per-participant
    group sessions), the most recently updated entry wins."""
    adapter = _make_session_mode_adapter(deliver="whatsapp", deliver_mode="session")
    wa = _RecordingAdapter()
    older = _Entry("agent:main:whatsapp:group:G:u1", "G", updated_at=1)
    newer = _Entry("agent:main:whatsapp:group:G:u2", "G", updated_at=2)
    runner = _Runner(wa, _Store([older, newer]))
    _wire_session_mode(adapter, runner, runner.home())

    await adapter.send("ha_events:whatsapp;session", "event")

    assert wa.handled
    assert wa.handled[0].metadata["gateway_session_key"] == newer.session_key


@pytest.mark.asyncio
async def test_session_mode_with_default_target_logs_and_falls_back():
    """deliver_mode: session with the default target (homeassistant) has no target
    session to integrate with: log + fall back to the HA notification path."""
    adapter = _make_session_mode_adapter(deliver_mode="session")
    # resolve target default = homeassistant → _handle_ha_event tags plain "ha_events"
    assert adapter.resolve_deliver_target("sensor.s") == "homeassistant"
    monkeypatched = SendResult(success=True, message_id="ha-fb")
    orig = HomeAssistantAdapter._send_ha_notification

    async def fake_ha(self, content):
        return monkeypatched

    HomeAssistantAdapter._send_ha_notification = fake_ha
    try:
        result = await adapter.send("ha_events", "event")  # untagged = local path
    finally:
        HomeAssistantAdapter._send_ha_notification = orig
    assert result.message_id == "ha-fb"


@pytest.mark.asyncio
async def test_fallback_chain_broadcast_failure_reaches_ha_notification(monkeypatch):
    """Fallback chain stage 2→3: when broadcast adapter.send raises, the HA
    notification path takes over (the alert is never dropped)."""
    adapter = _make_session_mode_adapter(deliver="whatsapp")
    wa = _RecordingAdapter()
    wa.send = AsyncMock(side_effect=RuntimeError("platform down"))
    entry = _Entry("agent:main:whatsapp:group:G:u1", "G")
    runner = _Runner(wa, _Store([entry]))
    _wire_session_mode(adapter, runner, runner.home())
    monkeypatch.setattr(
        HomeAssistantAdapter, "_send_ha_notification",
        AsyncMock(return_value=SendResult(success=True, message_id="ha-fb")),
    )
    result = await adapter.send("ha_events:whatsapp", "event")
    assert result.message_id == "ha-fb"
'''

code += tests
open(path, "w").write(code)
print("step6 OK: testes adicionados")
PYEOF