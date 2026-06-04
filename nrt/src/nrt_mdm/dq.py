"""Data Quality scoring engine.

Applies 11 non-AI rules to a golden record. Base score 100, clamped 0-100.
Same rules as the batch Snowflake pipeline (DT_CUSTOMER_GOLDEN_FUZZY) minus DQ-AI01.
"""

import re

from nrt_mdm.models import GoldenCustomer

DISPOSABLE_DOMAINS = {"mailinator.com", "tempmail.com", "guerrillamail.com", "10minutemail.com"}
PLACEHOLDER_PHONES = {"0000000000", "1111111111", "1234567890"}

EMAIL_REGEX = re.compile(r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$")
PHONE_REGEX = re.compile(r"^\+?[0-9]{10,15}$")
NAME_REGEX = re.compile(r"^[A-Za-z '\-]+$")


def compute_dq_score(golden: GoldenCustomer) -> int:
    """Compute DQ score for a golden record. Returns 0-100."""
    score = 100

    # DQ-001: Invalid email format (-20)
    if not golden.email or not EMAIL_REGEX.match(golden.email):
        score -= 20

    # DQ-002: Disposable email domain (-5)
    if golden.email and "@" in golden.email:
        domain = golden.email.split("@")[1].lower()
        if domain in DISPOSABLE_DOMAINS:
            score -= 5

    # DQ-003: Missing/short first_name (-20)
    if not golden.first_name or len(golden.first_name.strip()) <= 1:
        score -= 20

    # DQ-004: Special chars in first_name (-5)
    if golden.first_name and len(golden.first_name.strip()) > 1:
        if not NAME_REGEX.match(golden.first_name):
            score -= 5

    # DQ-005: Missing/short last_name (-20)
    if not golden.last_name or len(golden.last_name.strip()) <= 1:
        score -= 20

    # DQ-006: Special chars in last_name (-5)
    if golden.last_name and len(golden.last_name.strip()) > 1:
        if not NAME_REGEX.match(golden.last_name):
            score -= 5

    # DQ-007: Invalid phone format (-5)
    if golden.phone:
        cleaned = re.sub(r"[^0-9+]", "", golden.phone)
        if not PHONE_REGEX.match(cleaned):
            score -= 5

    # DQ-008: Placeholder phone (-20)
    if golden.phone:
        digits = re.sub(r"[^0-9]", "", golden.phone)
        if digits in PLACEHOLDER_PHONES:
            score -= 20

    # DQ-C01: No contact method (-20)
    has_valid_email = golden.email is not None and EMAIL_REGEX.match(golden.email)
    has_valid_phone = golden.phone is not None and len(re.sub(r"[^0-9]", "", golden.phone)) >= 7
    if not has_valid_email and not has_valid_phone:
        score -= 20

    # DQ-C02: No complete name (-20)
    has_first = golden.first_name is not None and len(golden.first_name.strip()) > 1
    has_last = golden.last_name is not None and len(golden.last_name.strip()) > 1
    if not has_first and not has_last:
        score -= 20

    # DQ-X03: Name appears in email (+5 bonus)
    if (golden.first_name and len(golden.first_name.strip()) > 1
            and golden.email
            and golden.first_name.strip().lower() in golden.email.lower()):
        score += 5

    return max(0, min(100, score))
