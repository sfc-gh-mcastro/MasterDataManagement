"""Data models for NRT MDM."""

from dataclasses import dataclass
from datetime import datetime


@dataclass
class SourceCustomer:
    """A normalized source record ready for matching and storage."""

    source_system: str
    source_key: str
    first_name: str | None
    last_name: str | None
    email: str | None
    phone: str | None
    event_timestamp: datetime
    canonical_first_name: str | None = None
    block_soundex: str | None = None
    block_email_domain: str | None = None
    block_phone_suffix: str | None = None


@dataclass
class GoldenCustomer:
    """The survivorship result for a cluster -- the golden record."""

    cluster_id: int
    first_name: str | None
    last_name: str | None
    email: str | None
    phone: str | None
    dq_score: int
    source_count: int
    row_hash: str | None = None
