"""Rule-based matching engine for entity resolution.

Implements deterministic + probabilistic scoring with a configurable threshold.
No ML model -- uses jellyfish for Jaro-Winkler similarity and SOUNDEX.
"""

import jellyfish

from nrt_mdm.models import SourceCustomer

# Threshold for merge decision
MATCH_THRESHOLD = 0.70


def compute_match_score(a: SourceCustomer, b: SourceCustomer) -> float:
    """Compute combined match score between two source records.

    Formula: MAX(deterministic) + SUM(probabilistic)

    Returns a float score. If >= MATCH_THRESHOLD, records should be merged.
    """
    # --- Deterministic rules (take the MAX) ---

    # MATCH-D01: Email exact equality
    email_match = 1.0 if (a.email and b.email and a.email == b.email) else 0.0

    # MATCH-D02: Phone last-10 digits equality
    phone_match = 0.0
    if a.phone and b.phone:
        a_digits = a.phone.replace("+", "")
        b_digits = b.phone.replace("+", "")
        if len(a_digits) >= 10 and len(b_digits) >= 10 and a_digits[-10:] == b_digits[-10:]:
            phone_match = 0.95

    # MATCH-C01: Canonical name exact (case-insensitive)
    canonical_exact = 0.0
    if (a.canonical_first_name and b.canonical_first_name
            and a.last_name and b.last_name
            and a.canonical_first_name.lower() == b.canonical_first_name.lower()
            and a.last_name.lower() == b.last_name.lower()):
        canonical_exact = 0.80

    # --- Probabilistic rules (SUM all that fire) ---

    # MATCH-P01: Full name Jaro-Winkler similarity
    name_sim = 0.0
    if a.canonical_first_name and b.canonical_first_name and a.last_name and b.last_name:
        full_a = f"{a.canonical_first_name} {a.last_name}"
        full_b = f"{b.canonical_first_name} {b.last_name}"
        jw = jellyfish.jaro_winkler_similarity(full_a, full_b)
        if jw >= 0.85:
            name_sim = jw * 0.30

    # MATCH-P03: Last name SOUNDEX equality
    soundex_match = 0.0
    if (a.block_soundex and b.block_soundex and a.block_soundex == b.block_soundex):
        soundex_match = 0.20

    # MATCH-P04: Email domain match + first name JW >= 0.90
    email_domain_name = 0.0
    if a.email and b.email and "@" in a.email and "@" in b.email:
        a_domain = a.email[a.email.index("@"):]
        b_domain = b.email[b.email.index("@"):]
        if a_domain == b_domain:
            if a.canonical_first_name and b.canonical_first_name:
                fn_jw = jellyfish.jaro_winkler_similarity(
                    a.canonical_first_name.lower(), b.canonical_first_name.lower()
                )
                if fn_jw >= 0.90:
                    email_domain_name = 0.15

    # --- Final score ---
    deterministic_max = max(email_match, phone_match, canonical_exact)
    probabilistic_sum = name_sim + soundex_match + email_domain_name

    return deterministic_max + probabilistic_sum


def is_match(a: SourceCustomer, b: SourceCustomer) -> bool:
    """Determine if two records should be merged."""
    return compute_match_score(a, b) >= MATCH_THRESHOLD
