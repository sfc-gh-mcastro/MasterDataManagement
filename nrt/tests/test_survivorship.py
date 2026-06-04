"""Unit tests for survivorship engine (logic only, no DB)."""

from nrt_mdm.survivorship import _pick_best, _is_valid_name, _is_valid_email, _is_valid_phone


class TestPickBest:
    def test_completeness_wins(self):
        """Valid value wins over null/empty regardless of priority."""
        records = [
            {"source_system": "CRM_A", "first_name": None},
            {"source_system": "CRM_B", "first_name": "William"},
        ]
        assert _pick_best(records, "first_name", _is_valid_name) == "William"

    def test_priority_breaks_tie(self):
        """When both valid, higher trust source wins."""
        records = [
            {"source_system": "CRM_B", "first_name": "Bob"},
            {"source_system": "CRM_A", "first_name": "William"},
        ]
        # CRM_A has priority 1, CRM_B has priority 2 -> CRM_A wins
        assert _pick_best(records, "first_name", _is_valid_name) == "William"

    def test_all_null_returns_none(self):
        records = [
            {"source_system": "CRM_A", "email": None},
            {"source_system": "CRM_B", "email": None},
        ]
        assert _pick_best(records, "email", _is_valid_email) is None

    def test_email_validity(self):
        """Email without @ is not valid."""
        records = [
            {"source_system": "CRM_A", "email": "noatsign"},
            {"source_system": "CRM_B", "email": "valid@acme.com"},
        ]
        assert _pick_best(records, "email", _is_valid_email) == "valid@acme.com"

    def test_phone_validity(self):
        """Phone with < 7 digits is not valid."""
        records = [
            {"source_system": "CRM_A", "phone": "123"},
            {"source_system": "CRM_B", "phone": "+11043321819"},
        ]
        assert _pick_best(records, "phone", _is_valid_phone) == "+11043321819"

    def test_single_record(self):
        records = [{"source_system": "CRM_A", "first_name": "Alice"}]
        assert _pick_best(records, "first_name", _is_valid_name) == "Alice"

    def test_short_name_invalid(self):
        """Single character name is not valid."""
        records = [
            {"source_system": "CRM_A", "first_name": "A"},
            {"source_system": "CRM_B", "first_name": "Alice"},
        ]
        assert _pick_best(records, "first_name", _is_valid_name) == "Alice"
