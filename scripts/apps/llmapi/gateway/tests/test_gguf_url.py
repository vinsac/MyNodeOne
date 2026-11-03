"""S22, the gateway's validation of admin-supplied GGUF URLs."""

import pytest
from fastapi import HTTPException

from conftest import ADMIN_KEY, bearer

GOOD = "https://huggingface.co/org/repo/resolve/main/model-Q4_K_M.gguf"


@pytest.mark.parametrize("url,model_file", [
    (GOOD, "model-Q4_K_M.gguf"),
    ("https://hf.co/org/repo/model.gguf", "model.gguf"),
    ("https://HuggingFace.co/org/repo/model.gguf", "model.gguf"),
    ("https://huggingface.co:443/org/repo/model.gguf", "model.gguf"),
    ("https://huggingface.co/org/repo/model.gguf?download=true", "model.gguf"),
])
def test_accepted_urls(gateway, url, model_file):
    assert gateway._validate_gguf_model_url(url) == (url, model_file)


@pytest.mark.parametrize("url", [
    "http://huggingface.co/org/repo/model.gguf",
    "ftp://huggingface.co/org/repo/model.gguf",
    "https://evil.example/model.gguf",
    "https://huggingface.co.evil.example/model.gguf",
    "https://evilhuggingface.co/model.gguf",
    "https://huggingface.co@evil.example/model.gguf",
    "https://user:pass@huggingface.co/model.gguf",
    "https://huggingface.co:8443/model.gguf",
    "https://169.254.169.254/latest/meta-data/x.gguf",
    "https://huggingface.co/org/repo/model.bin",
    "https://huggingface.co/org/../../etc/model.gguf",
    "https://huggingface.co/.gguf/../model.gguf",
    "https://huggingface.co/org/$(id).gguf",
    "https://huggingface.co/org/`id`.gguf",
    "https://huggingface.co/org/a;id;.gguf",
    "https://huggingface.co/org/a b.gguf",
    "https://huggingface.co/org/a.gguf\n",
    "https://huggingface.co/org/a.gguf?x=$(id)",
    "https://huggingface.co/org/a.gguf#frag",
    "",
    None,
    123,
    ["https://huggingface.co/org/a.gguf"],
])
def test_rejected_urls(gateway, url):
    with pytest.raises(HTTPException) as rejected:
        gateway._validate_gguf_model_url(url)
    assert rejected.value.status_code == 400


def test_allowed_hosts_are_configurable(gateway, monkeypatch):
    monkeypatch.setattr(gateway.config, "GGUF_MODEL_ALLOWED_HOSTS", {"models.internal.example"})

    url = "https://models.internal.example/a/b.gguf"
    assert gateway._validate_gguf_model_url(url) == (url, "b.gguf")
    with pytest.raises(HTTPException):
        gateway._validate_gguf_model_url(GOOD)


@pytest.mark.parametrize("path", ["/admin/backend/llamacpp", "/admin/backend/embedding"])
def test_endpoints_reject_before_touching_the_cluster(client, gateway, fake_postgres, monkeypatch, path):
    fake_postgres.add_key(ADMIN_KEY, scopes=["admin"])

    def fail_if_called():
        raise AssertionError("the Kubernetes API must not be reached")

    monkeypatch.setattr(gateway, "get_k8s_clients", fail_if_called)

    response = client.post(path, json={"model_url": "https://evil.example/m.gguf"}, headers=bearer(ADMIN_KEY))

    assert response.status_code == 400
    assert "huggingface.co" in response.json()["detail"]
