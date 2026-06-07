"""Unit tests for field mappers."""

from datetime import datetime, timezone

from nrt_mdm.mappers import (
    map_crm_a,
    map_crm_b,
    map_crm_c,
    _initcap,
    _lower_trim,
    _digits_only,
    _soundex,
    _email_domain,
    _phone_suffix,
)


TS = datetime(2026, 6, 1, 12, 0, 0, tzinfo=timezone.utc)


# ---------------------------------------------------------------------------
# Helper function tests
# ---------------------------------------------------------------------------

class TestHelpers:
    def test_initcap_normal(self):
        assert _initcap("bill") == "Bill"
        assert _initcap("WILLIAM") == "William"
        assert _initcap("  john  ") == "John"

    def test_initcap_empty(self):
        assert _initcap(None) is None
        assert _initcap("") is None
        assert _initcap("   ") is None

    def test_lower_trim(self):
        assert _lower_trim("  Bill@ACME.com  ") == "bill@acme.com"
        assert _lower_trim(None) is None

    def test_digits_only(self):
        assert _digits_only("+1 (104) 332-1819") == "+11043321819"
        assert _digits_only(None) is None
        assert _digits_only("abc") is None

    def test_soundex(self):
        assert _soundex("Smith") == "S530"
        assert _soundex("Smth") == "S530"  # same soundex
        assert _soundex(None) is None

    def test_email_domain(self):
        assert _email_domain("bill@acme.com") == "@acme.com"
        assert _email_domain("noatsign") is None
        assert _email_domain(None) is None

    def test_phone_suffix(self):
        assert _phone_suffix("+11043321819", 4) == "1819"
        assert _phone_suffix("123", 4) is None  # too short
        assert _phone_suffix(None, 4) is None


# ---------------------------------------------------------------------------
# CRM_A mapper tests
# ---------------------------------------------------------------------------

class TestMapCrmA:
    def test_basic(self):
        msg = {
            "src_customer_id": "A001",
            "first_name": "bill",
            "last_name": "SMITH",
            "email": "  Bill@Acme.com  ",
            "phone": "+1 (104) 332-1819",
        }
        rec = map_crm_a(msg, TS)
        assert rec.source_system == "CRM_A"
        assert rec.source_key == "A001"
        assert rec.first_name == "Bill"
        assert rec.last_name == "Smith"
        assert rec.email == "bill@acme.com"
        assert rec.phone == "+11043321819"
        assert rec.canonical_first_name == "Bill"
        assert rec.block_soundex == "S530"
        assert rec.block_email_domain == "@acme.com"
        assert rec.block_phone_suffix == "1819"
        assert rec.event_timestamp == TS

    def test_nulls(self):
        msg = {"src_customer_id": "A002", "first_name": None, "last_name": None, "email": None, "phone": None}
        rec = map_crm_a(msg, TS)
        assert rec.first_name is None
        assert rec.block_soundex is None
        assert rec.block_email_domain is None


# ---------------------------------------------------------------------------
# CRM_B mapper tests
# ---------------------------------------------------------------------------

class TestMapCrmB:
    def test_name_split(self):
        msg = {"customer_key": "B001", "name": "William Smith", "email_address": "wsmith@acme.com", "mobile": "104-332-1819"}
        rec = map_crm_b(msg, TS)
        assert rec.source_system == "CRM_B"
        assert rec.source_key == "B001"
        assert rec.first_name == "William"
        assert rec.last_name == "Smith"
        assert rec.email == "wsmith@acme.com"
        assert rec.phone == "1043321819"

    def test_single_name(self):
        msg = {"customer_key": "B002", "name": "Madonna", "email_address": None, "mobile": None}
        rec = map_crm_b(msg, TS)
        assert rec.first_name == "Madonna"
        assert rec.last_name is None


# ---------------------------------------------------------------------------
# CRM_C mapper tests
# ---------------------------------------------------------------------------

class TestMapCrmC:
    def test_caller_name_split(self):
        msg = {"ticket_customer_id": "C001", "caller_name": "Bill Smth", "callback_email": "bill@acme.com", "callback_phone": "(104) 332-1819"}
        rec = map_crm_c(msg, TS)
        assert rec.source_system == "CRM_C"
        assert rec.source_key == "C001"
        assert rec.first_name == "Bill"
        assert rec.last_name == "Smth"
        assert rec.email == "bill@acme.com"

    def test_empty_caller(self):
        msg = {"ticket_customer_id": "C002", "caller_name": "", "callback_email": None, "callback_phone": None}
        rec = map_crm_c(msg, TS)
        assert rec.first_name is None
        assert rec.last_name is None
