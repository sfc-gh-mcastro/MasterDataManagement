"""Unit tests for matching engine."""

from datetime import datetime, timezone

from nrt_mdm.matching import compute_match_score, is_match, MATCH_THRESHOLD
from nrt_mdm.models import SourceCustomer

TS = datetime(2026, 6, 1, 12, 0, 0, tzinfo=timezone.utc)


def _make_record(
    source_system="CRM_A", source_key="001",
    first_name="William", last_name="Smith",
    email="bill@acme.com", phone="+11043321819",
    **overrides,
) -> SourceCustomer:
    """Helper to create a SourceCustomer with defaults."""
    from nrt_mdm.mappers import _soundex, _email_domain, _phone_suffix, _initcap
    kw = dict(
        source_system=source_system, source_key=source_key,
        first_name=first_name, last_name=last_name,
        email=email, phone=phone, event_timestamp=TS,
        canonical_first_name=_initcap(first_name),
        block_soundex=_soundex(last_name),
        block_email_domain=_email_domain(email),
        block_phone_suffix=_phone_suffix(phone, 4),
    )
    kw.update(overrides)
    return SourceCustomer(**kw)


class TestDeterministicRules:
    def test_email_exact_match(self):
        a = _make_record(email="bill@acme.com")
        b = _make_record(source_system="CRM_B", source_key="B01", email="bill@acme.com", first_name="Bob", last_name="Jones")
        score = compute_match_score(a, b)
        assert score >= 1.0  # D01 fires
        assert is_match(a, b)

    def test_phone_last10_match(self):
        a = _make_record(phone="+11043321819", email="a@x.com")
        b = _make_record(source_system="CRM_B", source_key="B01", phone="1043321819", email="b@y.com", first_name="Bob", last_name="Jones")
        score = compute_match_score(a, b)
        assert score >= 0.95  # D02 fires
        assert is_match(a, b)

    def test_canonical_name_exact(self):
        a = _make_record(first_name="William", last_name="Smith", email="a@x.com", phone="+10000000001")
        b = _make_record(source_system="CRM_B", source_key="B01", first_name="William", last_name="Smith", email="b@y.com", phone="+10000000002")
        score = compute_match_score(a, b)
        # C01=0.80, P01 should fire (identical name JW=1.0 -> 0.30), P03 soundex match (0.20)
        assert score >= 0.80
        assert is_match(a, b)


class TestProbabilisticRules:
    def test_name_jw_similar(self):
        # "William Smith" vs "Willam Smith" (typo) -> JW should be >= 0.85
        a = _make_record(first_name="William", last_name="Smith", email="a@x.com", phone="+10000000001")
        b = _make_record(source_system="CRM_B", source_key="B01", first_name="Willam", last_name="Smith", email="b@y.com", phone="+10000000002")
        score = compute_match_score(a, b)
        # P01 + P03 (soundex) should contribute
        assert score > 0.0

    def test_soundex_match(self):
        # Smith and Smyth have same SOUNDEX (S530)
        a = _make_record(last_name="Smith", email="a@x.com", phone="+10000000001")
        b = _make_record(source_system="CRM_B", source_key="B01", last_name="Smyth", email="b@y.com", phone="+10000000002")
        score = compute_match_score(a, b)
        assert score >= 0.20  # P03 fires

    def test_email_domain_plus_first_name(self):
        # Same email domain, similar first names
        a = _make_record(first_name="William", last_name="Smith", email="william@acme.com", phone="+10000000001")
        b = _make_record(source_system="CRM_B", source_key="B01", first_name="William", last_name="Jones", email="william.j@acme.com", phone="+10000000002")
        score = compute_match_score(a, b)
        # P04 should fire (same domain, identical first_name -> JW=1.0 >= 0.90)
        assert score >= 0.15


class TestNoMatch:
    def test_completely_different(self):
        a = _make_record(first_name="Alice", last_name="Johnson", email="alice@foo.com", phone="+19999999999")
        b = _make_record(source_system="CRM_B", source_key="B01", first_name="Bob", last_name="Zhang", email="bob@bar.com", phone="+18888888888")
        score = compute_match_score(a, b)
        assert score < MATCH_THRESHOLD
        assert not is_match(a, b)

    def test_null_fields(self):
        a = _make_record(first_name=None, last_name=None, email=None, phone=None)
        b = _make_record(source_system="CRM_B", source_key="B01", first_name=None, last_name=None, email=None, phone=None)
        score = compute_match_score(a, b)
        assert score == 0.0
        assert not is_match(a, b)


class TestEdgeCases:
    def test_short_phone_no_match(self):
        a = _make_record(phone="123", email="a@x.com")
        b = _make_record(source_system="CRM_B", source_key="B01", phone="123", email="b@y.com", first_name="Bob", last_name="Jones")
        score = compute_match_score(a, b)
        # Phone too short for D02, no email match
        assert score < 1.0

    def test_same_record_different_systems(self):
        # Identical record in two systems -> high score
        a = _make_record(source_system="CRM_A", source_key="A01")
        b = _make_record(source_system="CRM_B", source_key="B01")
        score = compute_match_score(a, b)
        assert score >= 1.0  # email exact match alone is sufficient
        assert is_match(a, b)
