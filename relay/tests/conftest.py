import base64

import pytest

from parley_relay.voicelab import WebhookSecret

# A test-only webhook secret (not a real one): whsec_ and 32 bytes of base64.
TEST_SECRET = "whsec_" + base64.b64encode(b"parley-test-secret-0123456789abc").decode()


@pytest.fixture
def anyio_backend():
    return "asyncio"


@pytest.fixture
def secret() -> WebhookSecret:
    return WebhookSecret.parse(TEST_SECRET)
