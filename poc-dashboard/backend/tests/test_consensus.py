from app.services import consensus_svc


def test_local_inspection_url_uses_metrics_host_override(monkeypatch):
    monkeypatch.setenv(consensus_svc.METRICS_HOST_ENV, "host.docker.internal")

    assert consensus_svc._local_http_url("127.0.0.1", 40703) == "http://host.docker.internal:40703"
    assert consensus_svc._local_http_url("0.0.0.0", 40703) == "http://host.docker.internal:40703"
    assert consensus_svc._local_http_url("192.0.2.10", 40703) == "http://192.0.2.10:40703"
