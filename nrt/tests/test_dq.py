"""Unit tests for DQ scoring."""

from nrt_mdm.dq import compute_dq_score
from nrt_mdm.models import GoldenCustomer


def _golden(**kwargs) -> GoldenCustomer:
    defaults = dict(cluster_id=1, first_name="William", last_name="Smith",
                    email="william@acme.com", phone="+11043321819",
                    dq_score=0, source_count=1)
    defaults.update(kwargs)
    return GoldenCustomer(**defaults)


class TestDQScoring:
    def test_perfect_record(self):
        g = _golden()
        score = compute_dq_score(g)
        # Valid email, name, phone + name-in-email bonus
        assert score >= 95

    def test_name_in_email_bonus(self):
        g = _golden(first_name="William", email="william@acme.com")
        score = compute_dq_score(g)
        # Base 100 + bonus 5 = 105, clamped to 100
        assert score == 100

    def test_no_email_no_phone(self):
        g = _golden(email=None, phone=None)
        score = compute_dq_score(g)
        # DQ-001 (-20) + DQ-C01 (-20) = 60
        assert score <= 60

    def test_disposable_email(self):
        g = _golden(email="test@mailinator.com")
        score = compute_dq_score(g)
        # DQ-002 fires (-5), no name-in-email bonus
        assert score == 95

    def test_missing_first_name(self):
        g = _golden(first_name=None)
        score = compute_dq_score(g)
        # DQ-003 (-20), no name-in-email bonus
        assert score <= 80

    def test_short_first_name(self):
        g = _golden(first_name="A")
        score = compute_dq_score(g)
        # DQ-003 fires (length <= 1)
        assert score <= 80

    def test_placeholder_phone(self):
        g = _golden(phone="0000000000")
        score = compute_dq_score(g)
        # DQ-008 (-20) + DQ-X03 bonus (+5) = 85
        assert score == 85

    def test_no_name_at_all(self):
        g = _golden(first_name=None, last_name=None)
        score = compute_dq_score(g)
        # DQ-003 (-20) + DQ-005 (-20) + DQ-C02 (-20) = 40
        assert score <= 40

    def test_special_chars_in_name(self):
        g = _golden(first_name="W1lliam")
        score = compute_dq_score(g)
        # DQ-004 fires (-5)
        assert score <= 95

    def test_clamped_at_zero(self):
        # Everything wrong
        g = _golden(first_name=None, last_name=None, email=None, phone="123")
        score = compute_dq_score(g)
        assert score >= 0

    def test_clamped_at_100(self):
        g = _golden(first_name="William", email="william@acme.com")
        score = compute_dq_score(g)
        assert score <= 100
