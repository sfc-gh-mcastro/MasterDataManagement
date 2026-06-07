#!/usr/bin/env python3
"""
generate_test_data.py
Norwegian MDM Test Data Generator for Norwegian Bank POC

Generates synthetic data for three source systems:
  FREG  — Folkeregisteret (national population register, highest trust)
  BS    — Bank System (mid trust)
  NICE  — CRM system (lowest trust)

Embedded MDM scenarios:
  1. ~200 shared persons: exact SSN+name match across FREG/BS/NICE
  2. ~50 fuzzy-only:  BS has SSN; NICE has same phone but NO SSN
  3.   5 data steward: NICE, no SSN, unique name — no match anywhere
  4. ~30 cross-org:   same person (same SSN) in both BANK and INS in BS
  5.   8 nickname pairs: FREG canonical / BS nickname — Cortex AI scenario
"""

import calendar
import csv
import os
import random
import shutil
from dataclasses import dataclass, replace
from datetime import date, datetime, timedelta, timezone
from typing import Optional
from faker import Faker

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), '..', 'output')

fake = Faker('no_NO')
Faker.seed(42)
random.seed(42)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SOURCE_FREG = 'FREG'
SOURCE_BS   = 'BS'
SOURCE_NICE = 'NICE'
ORG_BANK    = 'BANK'
ORG_INS     = 'INS'

NO_STREETS = [
    'Storgata', 'Kirkeveien', 'Osloveien', 'Parkveien', 'Skoleveien',
    'Fjordveien', 'Bergveien', 'Nesveien', 'Søndre gate', 'Nordre gate',
    'Langveien', 'Dronningens gate', 'Kongens gate', 'Torggata', 'Markveien',
    'Bygdøy allé', 'Trondheimsveien', 'Sandakerveien', 'Maridalsveien', 'Holmenveien',
]

NO_CITIES = [
    'Oslo', 'Bergen', 'Trondheim', 'Stavanger', 'Kristiansand',
    'Tromsø', 'Fredrikstad', 'Sandnes', 'Drammen', 'Sarpsborg',
    'Bodø', 'Ålesund', 'Hamar', 'Lillestrøm', 'Moss',
]

# 90 % Norwegian, 10 % other
CITIZENSHIPS = ['NO'] * 90 + ['SE'] * 4 + ['PL'] * 3 + ['LT'] * 3

# Cortex AI test: canonical ↔ nickname pairs
NORWEGIAN_NICKNAME_PAIRS = [
    ('Per',  'Petter'),
    ('Kari', 'Karen'),
    ('Ole',  'Olav'),
    ('Jon',  'Jonas'),
    ('Lise', 'Elisabeth'),
    ('Tor',  'Torben'),
    ('Mari', 'Maria'),
    ('Hans', 'Johan'),
]

# Data steward queue: unique foreign names — guaranteed no SSN + no fuzzy match
STEWARD_QUEUE_NAMES = [
    ('Zygmunt',    'Wierzbicki'),
    ('Bartholomew','Throgmorton'),
    ('Xiomara',    'Felicissimo'),
    ('Oswaldo',    'Baumgartner'),
    ('Perpetua',   'Quisenberry'),
]


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class NorwegianCustomer:
    id: str
    ssn: Optional[str]          # 11-digit personnummer; None for some NICE records
    first_name: str
    last_name: str
    birth_date: Optional[date]  # Populated for FREG (derived from SSN)
    citizenship: Optional[str]  # Populated for FREG only
    phone: Optional[str]
    email: Optional[str]
    record_date: date
    organization: Optional[str] # BANK | INS; None for FREG
    source: str                 # FREG | BS | NICE


@dataclass
class NorwegianAddress:
    id: str
    customer_id: str            # FK to NorwegianCustomer.id
    gate: str
    postnummer: str             # 4-digit zero-padded
    by: str
    land: str


# ---------------------------------------------------------------------------
# Personnummer (modulus-11)
# ---------------------------------------------------------------------------

def generate_personnummer(birth_date: Optional[date] = None):
    """Generate a valid Norwegian personnummer.

    Format: DDMMYY + 3-digit individual number (001–499 for 1900-1999) + 2 check digits.

    Check digit algorithm (modulus-11):
      c1 weights [3,7,6,1,8,9,4,5,2] over digits 0-8
      c2 weights [5,4,3,2,7,6,5,4,3,2] over digits 0-9
      result = 11 − (sum % 11)
        if result == 10 → invalid, regenerate with different individual number
        if result == 11 → treat as 0

    Returns (personnummer_str, birth_date).
    """
    if birth_date is None:
        year  = random.randint(1940, 2000)
        month = random.randint(1, 12)
        day   = random.randint(1, calendar.monthrange(year, month)[1])
        bd    = date(year, month, day)
    else:
        bd = birth_date

    dd = f"{bd.day:02d}"
    mm = f"{bd.month:02d}"
    yy = f"{bd.year % 100:02d}"

    c1_weights = [3, 7, 6, 1, 8, 9, 4, 5, 2]
    c2_weights = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]

    for _ in range(1000):
        ind     = random.randint(1, 499)
        ind_str = f"{ind:03d}"
        digits  = [int(c) for c in dd + mm + yy + ind_str]   # 9 digits

        c1_raw = 11 - (sum(w * d for w, d in zip(c1_weights, digits)) % 11)
        if c1_raw == 10:
            continue
        c1 = 0 if c1_raw == 11 else c1_raw

        digits_10 = digits + [c1]                             # 10 digits
        c2_raw    = 11 - (sum(w * d for w, d in zip(c2_weights, digits_10)) % 11)
        if c2_raw == 10:
            continue
        c2 = 0 if c2_raw == 11 else c2_raw

        return dd + mm + yy + ind_str + str(c1) + str(c2), bd

    raise ValueError(f"Could not generate valid personnummer for {bd}")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def generate_norwegian_phone() -> str:
    """Return a Norwegian mobile number: +47 followed by 8 digits, first digit 9 or 4."""
    prefix = random.choice(['9', '4'])
    rest   = ''.join(str(random.randint(0, 9)) for _ in range(7))
    return f"+47{prefix}{rest}"


def generate_email(first_name: str, last_name: str) -> str:
    """Generate a plausible Norwegian email address."""
    domains  = ['gmail.com', 'hotmail.com', 'outlook.com', 'yahoo.no', 'online.no']
    first    = first_name.lower().replace('æ','ae').replace('ø','o').replace('å','a')
    last     = last_name.lower().replace('æ','ae').replace('ø','o').replace('å','a')
    patterns = [
        f"{first}.{last}@{random.choice(domains)}",
        f"{first}{last[0]}@{random.choice(domains)}",
        f"{first[0]}{last}@{random.choice(domains)}",
        f"{first}{random.randint(1,99)}@{random.choice(domains)}",
    ]
    return random.choice(patterns)


def typo_name(name: str) -> str:
    """Introduce a realistic single-character typo (Jaro-Winkler ~85 %)."""
    if len(name) < 3:
        return name
    op  = random.choice(['swap', 'drop', 'replace'])
    idx = random.randint(1, len(name) - 2)
    if op == 'swap' and idx < len(name) - 1:
        return name[:idx] + name[idx+1] + name[idx] + name[idx+2:]
    if op == 'drop':
        return name[:idx] + name[idx+1:]
    similar = {'a':'e','e':'i','i':'y','o':'u','s':'z',
               'n':'m','r':'l','k':'g','ø':'o','æ':'a','å':'a'}
    return name[:idx] + similar.get(name[idx].lower(), name[idx]) + name[idx+1:]


def random_record_date(days_back: int = 730) -> date:
    delta = random.randint(0, days_back)
    return (datetime.now(timezone.utc) - timedelta(days=delta)).date()


def make_address(addr_id: str, customer_id: str) -> NorwegianAddress:
    return NorwegianAddress(
        id=addr_id,
        customer_id=customer_id,
        gate=f"{random.choice(NO_STREETS)} {random.randint(1, 120)}",
        postnummer=f"{random.randint(1, 9999):04d}",
        by=random.choice(NO_CITIES),
        land='NO',
    )


# ---------------------------------------------------------------------------
# Shared-person pool (backbone of all cross-source matching scenarios)
# ---------------------------------------------------------------------------

class SharedPerson:
    """One real individual who may appear in multiple source systems."""
    __slots__ = ('idx','ssn','birth_date','first_name','last_name',
                 'citizenship','phone','email')

    def __init__(self, idx: int):
        self.idx         = idx
        self.ssn, bd     = generate_personnummer()
        self.birth_date  = bd
        self.first_name  = fake.first_name()
        self.last_name   = fake.last_name()
        self.citizenship = random.choice(CITIZENSHIPS)
        self.phone       = generate_norwegian_phone()
        self.email       = generate_email(self.first_name, self.last_name)


# ---------------------------------------------------------------------------
# FREG (~400 records)
# ---------------------------------------------------------------------------

def generate_freg_customers(
    count: int,
    shared_persons: list,          # SharedPerson list
    nickname_pairs_last: list,     # shared last names for nickname pairs
) -> list:
    customers = []

    # Shared persons → will match BS/NICE via SSN
    for p in shared_persons:
        customers.append(NorwegianCustomer(
            id=f"FREG{p.idx+1:06d}",
            ssn=p.ssn,
            first_name=p.first_name,
            last_name=p.last_name,
            birth_date=p.birth_date,
            citizenship=p.citizenship,
            phone=None,
            email=None,
            record_date=random_record_date(1825),
            organization=None,
            source=SOURCE_FREG,
        ))

    # Nickname pairs: canonical name in FREG
    for idx, ((canonical, _nickname), shared_last) in enumerate(
            zip(NORWEGIAN_NICKNAME_PAIRS, nickname_pairs_last)):
        pnr, bd = generate_personnummer()
        customers.append(NorwegianCustomer(
            id=f"FREG_NP{idx+1:03d}",
            ssn=pnr,
            first_name=canonical,
            last_name=shared_last,
            birth_date=bd,
            citizenship='NO',
            phone=None,
            email=None,
            record_date=random_record_date(1825),
            organization=None,
            source=SOURCE_FREG,
        ))

    # Unique FREG-only persons to reach target count
    offset = len(shared_persons)
    for i in range(count - len(customers)):
        pnr, bd = generate_personnummer()
        customers.append(NorwegianCustomer(
            id=f"FREG{offset+i+1:06d}",
            ssn=pnr,
            first_name=fake.first_name(),
            last_name=fake.last_name(),
            birth_date=bd,
            citizenship=random.choice(CITIZENSHIPS),
            phone=None,
            email=None,
            record_date=random_record_date(1825),
            organization=None,
            source=SOURCE_FREG,
        ))

    return customers[:count]


# ---------------------------------------------------------------------------
# BS (~500 records)
# ---------------------------------------------------------------------------

def generate_bs_customers(
    count: int,
    shared_persons: list,          # same SharedPerson pool as FREG
    cross_org_indices: set,        # indices of shared_persons that appear in BOTH orgs
    fuzzy_persons: list,           # SharedPerson — BS has SSN; NICE will have same phone, no SSN
    nickname_pairs: list,          # list of (nickname_str, shared_last_str, phone_str)
) -> list:
    customers = []

    # Shared persons — exact SSN+name match with FREG
    for p in shared_persons:
        if p.idx in cross_org_indices:
            # Cross-org: same person in BANK and INS
            for org in [ORG_BANK, ORG_INS]:
                customers.append(NorwegianCustomer(
                    id=f"BS{p.idx+1:06d}_{org}",
                    ssn=p.ssn,
                    first_name=p.first_name,
                    last_name=p.last_name,
                    birth_date=None,
                    citizenship=None,
                    phone=p.phone,
                    email=p.email,
                    record_date=random_record_date(730),
                    organization=org,
                    source=SOURCE_BS,
                ))
        else:
            customers.append(NorwegianCustomer(
                id=f"BS{p.idx+1:06d}",
                ssn=p.ssn,
                first_name=p.first_name,
                last_name=p.last_name,
                birth_date=None,
                citizenship=None,
                phone=p.phone,
                email=p.email,
                record_date=random_record_date(730),
                organization=random.choice([ORG_BANK, ORG_INS]),
                source=SOURCE_BS,
            ))

    # Fuzzy-only persons: BS has SSN; NICE will have same phone but no SSN
    for p in fuzzy_persons:
        customers.append(NorwegianCustomer(
            id=f"BS_FZ{p.idx+1:06d}",
            ssn=p.ssn,
            first_name=p.first_name,
            last_name=p.last_name,
            birth_date=None,
            citizenship=None,
            phone=p.phone,
            email=p.email,
            record_date=random_record_date(365),
            organization=random.choice([ORG_BANK, ORG_INS]),
            source=SOURCE_BS,
        ))

    # Nickname pairs: FREG has canonical; BS has same last name, same phone, nickname first
    for idx, (nickname, shared_last, shared_phone) in enumerate(nickname_pairs):
        pnr, _ = generate_personnummer()   # different SSN — forces AI resolution
        customers.append(NorwegianCustomer(
            id=f"BS_NP{idx+1:03d}",
            ssn=pnr,
            first_name=nickname,
            last_name=shared_last,
            birth_date=None,
            citizenship=None,
            phone=shared_phone,
            email=generate_email(nickname, shared_last),
            record_date=random_record_date(365),
            organization=random.choice([ORG_BANK, ORG_INS]),
            source=SOURCE_BS,
        ))

    # Fill to target with BS-unique persons
    for i in range(count - len(customers)):
        pnr, _ = generate_personnummer()
        customers.append(NorwegianCustomer(
            id=f"BS_U{i+1:06d}",
            ssn=pnr,
            first_name=fake.first_name(),
            last_name=fake.last_name(),
            birth_date=None,
            citizenship=None,
            phone=generate_norwegian_phone(),
            email=fake.email(),
            record_date=random_record_date(730),
            organization=random.choice([ORG_BANK, ORG_INS]),
            source=SOURCE_BS,
        ))

    return customers[:count]


# ---------------------------------------------------------------------------
# NICE (~600 records)
# ---------------------------------------------------------------------------

def generate_nice_customers(
    count: int,
    shared_persons: list,          # first nice_ssn_count entries match FREG+BS
    nice_ssn_count: int,
    fuzzy_persons: list,           # same SharedPerson pool as BS fuzzy — NICE has no SSN
    nickname_pairs: list,          # list of (nickname_str, shared_last_str, phone_str)
) -> list:
    customers = []

    # Shared persons WITH SSN (exact match across all 3 sources)
    for p in shared_persons[:nice_ssn_count]:
        customers.append(NorwegianCustomer(
            id=f"NICE{p.idx+1:06d}",
            ssn=p.ssn,
            first_name=p.first_name,
            last_name=p.last_name,
            birth_date=None,
            citizenship=None,
            phone=p.phone,
            email=p.email,
            record_date=random_record_date(365),
            organization=random.choice([ORG_BANK, ORG_INS]),
            source=SOURCE_NICE,
        ))

    # Fuzzy-only: same phone as BS counterpart but NO SSN
    for p in fuzzy_persons:
        # ~50 % chance of first-name typo to exercise Jaro-Winkler
        variant_first = typo_name(p.first_name) if random.random() < 0.5 else p.first_name
        customers.append(NorwegianCustomer(
            id=f"NICE_FZ{p.idx+1:06d}",
            ssn=None,               # drives fuzzy-only scenario
            first_name=variant_first,
            last_name=p.last_name,
            birth_date=None,
            citizenship=None,
            phone=p.phone,          # same phone as BS record → phone match
            email=p.email,
            record_date=random_record_date(365),
            organization=random.choice([ORG_BANK, ORG_INS]),
            source=SOURCE_NICE,
        ))

    # Data steward queue: no SSN, unique foreign names, no match possible
    for idx, (first, last) in enumerate(STEWARD_QUEUE_NAMES):
        customers.append(NorwegianCustomer(
            id=f"NICE_SQ{idx+1:03d}",
            ssn=None,
            first_name=first,
            last_name=last,
            birth_date=None,
            citizenship=None,
            phone=generate_norwegian_phone(),
            email=fake.email(),
            record_date=random_record_date(180),
            organization=random.choice([ORG_BANK, ORG_INS]),
            source=SOURCE_NICE,
        ))

    # Nickname pairs in NICE: same phone as BS nickname record, no SSN
    for idx, (nickname, shared_last, shared_phone) in enumerate(nickname_pairs):
        customers.append(NorwegianCustomer(
            id=f"NICE_NP{idx+1:03d}",
            ssn=None,               # no SSN — forces nickname-based AI resolution
            first_name=nickname,
            last_name=shared_last,
            birth_date=None,
            citizenship=None,
            phone=shared_phone,     # same phone → phone match + AI confirmation
            email=generate_email(nickname, shared_last),
            record_date=random_record_date(365),
            organization=random.choice([ORG_BANK, ORG_INS]),
            source=SOURCE_NICE,
        ))

    # Fill remaining with NICE-unique records; ~30 % have no SSN
    for i in range(count - len(customers)):
        has_ssn = random.random() > 0.30
        ssn = None
        if has_ssn:
            ssn, _ = generate_personnummer()
        customers.append(NorwegianCustomer(
            id=f"NICE_U{i+1:06d}",
            ssn=ssn,
            first_name=fake.first_name(),
            last_name=fake.last_name(),
            birth_date=None,
            citizenship=None,
            phone=generate_norwegian_phone(),
            email=fake.email(),
            record_date=random_record_date(365),
            organization=random.choice([ORG_BANK, ORG_INS]),
            source=SOURCE_NICE,
        ))

    return customers[:count]


# ---------------------------------------------------------------------------
# Address generation (1 address per customer)
# ---------------------------------------------------------------------------

def generate_addresses(customers: list, prefix: str) -> list:
    return [make_address(f"{prefix}{i+1:06d}", c.id) for i, c in enumerate(customers)]


# ---------------------------------------------------------------------------
# CSV writers
# ---------------------------------------------------------------------------

def write_freg_customer_csv(customers: list, filepath: str):
    with open(filepath, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['ssn', 'first_name', 'last_name', 'birth_date',
                         'citizenship', 'record_date'])
        for c in customers:
            writer.writerow([
                c.ssn or '',
                c.first_name or '',
                c.last_name or '',
                c.birth_date.isoformat() if c.birth_date else '',
                c.citizenship or '',
                c.record_date.isoformat(),
            ])


def write_bs_customer_csv(customers: list, filepath: str):
    with open(filepath, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['ssn', 'first_name', 'last_name', 'phone',
                         'email', 'record_date', 'organization'])
        for c in customers:
            writer.writerow([
                c.ssn or '',
                c.first_name or '',
                c.last_name or '',
                c.phone or '',
                c.email or '',
                c.record_date.isoformat(),
                c.organization or '',
            ])


def write_nice_customer_csv(customers: list, filepath: str):
    with open(filepath, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['ssn', 'first_name', 'last_name', 'phone',
                         'email', 'record_date', 'organization'])
        for c in customers:
            writer.writerow([
                c.ssn or '',      # empty string when SSN is NULL
                c.first_name or '',
                c.last_name or '',
                c.phone or '',
                c.email or '',
                c.record_date.isoformat(),
                c.organization or '',
            ])


def write_address_csv(addresses: list, filepath: str):
    with open(filepath, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['src_address_id', 'src_customer_id',
                         'gate', 'postnummer', 'by', 'land'])
        for a in addresses:
            writer.writerow([a.id, a.customer_id, a.gate, a.postnummer, a.by, a.land])


# ---------------------------------------------------------------------------
# Daily update generators (SCD Type 2)
# ---------------------------------------------------------------------------

def generate_daily_updates_freg(base: list, _day: int, change_rate: float = 0.005) -> list:
    """FREG is very stable — only record_date bumps."""
    updates = []
    for cust in random.sample(base, max(1, int(len(base) * change_rate))):
        updates.append(replace(cust, record_date=date.today()))
    return updates


def generate_daily_updates_bs_or_nice(base: list, _day: int, change_rate: float = 0.01) -> list:
    """Email/phone/name corrections for BS and NICE."""
    updates = []
    for i, cust in enumerate(random.sample(base, max(1, int(len(base) * change_rate)))):
        scenario = i % 4
        if scenario == 0:
            updates.append(replace(cust, email=generate_email(cust.first_name, cust.last_name),
                                   record_date=date.today()))
        elif scenario == 1:
            updates.append(replace(cust, phone=generate_norwegian_phone(),
                                   record_date=date.today()))
        elif scenario == 2:
            updates.append(replace(cust, record_date=date.today()))
        else:
            updates.append(replace(cust, last_name=fake.last_name(),
                                   record_date=date.today()))
    return updates


def generate_daily_updates_addresses(base: list, _day: int, change_rate: float = 0.015) -> list:
    updates = []
    for addr in random.sample(base, max(1, int(len(base) * change_rate))):
        updates.append(make_address(addr.id, addr.customer_id))
    return updates


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def print_report(freg_c, bs_c, nice_c, freg_a, bs_a, nice_a,
                 fuzzy_count, steward_count, cross_org_count):
    print("\n" + "=" * 70)
    print("TEST DATA GENERATION REPORT — Norwegian Bank MDM POC")
    print("=" * 70)
    print(f"\n{'Category':<35} {'Count':>10}")
    print("-" * 45)
    print(f"{'FREG Customers':<35} {len(freg_c):>10}")
    print(f"{'BS Customers':<35} {len(bs_c):>10}")
    print(f"{'NICE Customers':<35} {len(nice_c):>10}")
    print(f"{'Total Raw Customer Records':<35} {len(freg_c)+len(bs_c)+len(nice_c):>10}")
    print(f"{'FREG Addresses':<35} {len(freg_a):>10}")
    print(f"{'BS Addresses':<35} {len(bs_a):>10}")
    print(f"{'NICE Addresses':<35} {len(nice_a):>10}")
    print()
    print("-" * 70)
    print("MDM SCENARIO COVERAGE")
    print("-" * 70)
    no_ssn_nice = sum(1 for c in nice_c if not c.ssn)
    print(f"  Exact SSN+name match (FREG/BS/NICE):   shared pool embedded")
    print(f"  Fuzzy-only (NICE no SSN, phone match):  {fuzzy_count} NICE records")
    print(f"  Data steward queue (no SSN, no match):  {steward_count} records")
    print(f"  Cross-org BANK+INS (same SSN, both):    {cross_org_count} persons × 2 rows")
    print(f"  Nickname pairs for Cortex AI:           {len(NORWEGIAN_NICKNAME_PAIRS)} pairs")
    print(f"  NICE records without SSN (total):       {no_ssn_nice} "
          f"({100*no_ssn_nice//len(nice_c)} %)")
    print()
    print("-" * 70)
    print("NORWEGIAN NICKNAME PAIRS (Cortex AI test coverage)")
    print("-" * 70)
    for canonical, nickname in NORWEGIAN_NICKNAME_PAIRS:
        print(f"  FREG: {canonical:<12} ↔ BS/NICE: {nickname}")
    print()
    print("=" * 70)
    print(f"Output written to: {OUTPUT_DIR}")
    print("=" * 70 + "\n")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("Generating Norwegian Bank MDM test data (Norwegian locale)...")

    if os.path.exists(OUTPUT_DIR):
        print(f"Cleaning: {OUTPUT_DIR}")
        shutil.rmtree(OUTPUT_DIR)
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # --- Volume parameters ---
    FREG_TARGET   = 400
    BS_TARGET     = 500
    NICE_TARGET   = 600
    FREG_SHARED   = 200   # persons that appear in all 3 sources
    NICE_SSN      = 100   # of shared persons also appear in NICE with SSN
    CROSS_ORG     = 30    # of shared persons appear in BOTH BANK and INS in BS
    FUZZY_COUNT   = 50    # persons: BS (with SSN) ↔ NICE (no SSN, same phone)
    STEWARD_COUNT = len(STEWARD_QUEUE_NAMES)  # 5

    # Build shared-person pool
    shared_persons = [SharedPerson(i) for i in range(FREG_SHARED)]
    cross_org_idx  = set(random.sample(range(FREG_SHARED), CROSS_ORG))

    # Fuzzy-only pool (distinct index range so SSNs don't collide)
    fuzzy_persons  = [SharedPerson(FREG_SHARED + i) for i in range(FUZZY_COUNT)]

    # Nickname pairs: shared last name + shared phone (FREG canonical / BS+NICE nickname)
    nickname_pairs_last  = [fake.last_name() for _ in NORWEGIAN_NICKNAME_PAIRS]
    nickname_pairs_phone = [generate_norwegian_phone() for _ in NORWEGIAN_NICKNAME_PAIRS]
    # List of (nickname, shared_last, shared_phone) for BS and NICE writers
    nickname_triples = [
        (nickname, nickname_pairs_last[i], nickname_pairs_phone[i])
        for i, (_canonical, nickname) in enumerate(NORWEGIAN_NICKNAME_PAIRS)
    ]

    # --- Generate source data ---
    freg_customers = generate_freg_customers(
        count=FREG_TARGET,
        shared_persons=shared_persons,
        nickname_pairs_last=nickname_pairs_last,
    )
    bs_customers = generate_bs_customers(
        count=BS_TARGET,
        shared_persons=shared_persons,
        cross_org_indices=cross_org_idx,
        fuzzy_persons=fuzzy_persons,
        nickname_pairs=nickname_triples,
    )
    nice_customers = generate_nice_customers(
        count=NICE_TARGET,
        shared_persons=shared_persons,
        nice_ssn_count=NICE_SSN,
        fuzzy_persons=fuzzy_persons,
        nickname_pairs=nickname_triples,
    )

    freg_addresses = generate_addresses(freg_customers, 'AF')
    bs_addresses   = generate_addresses(bs_customers,   'AB')
    nice_addresses = generate_addresses(nice_customers,  'AN')

    # --- Directory structure ---
    dirs = {}
    for src in [SOURCE_FREG, SOURCE_BS, SOURCE_NICE]:
        for kind in ['customer', 'address']:
            for phase in ['initial', 'update']:
                key       = f"{phase}_{src}_{kind}"
                dirs[key] = os.path.join(OUTPUT_DIR, phase, src, kind)
                os.makedirs(dirs[key], exist_ok=True)

    num_months   = 1
    num_days     = num_months * 30
    initial_date = (datetime.now(timezone.utc) - timedelta(days=num_days)).strftime('%Y-%m-%d')

    # --- Initial load CSVs ---
    write_freg_customer_csv(freg_customers,
        os.path.join(dirs['initial_FREG_customer'], f'{initial_date}_crm_freg_customers.csv'))
    write_bs_customer_csv(bs_customers,
        os.path.join(dirs['initial_BS_customer'],   f'{initial_date}_crm_bs_customers.csv'))
    write_nice_customer_csv(nice_customers,
        os.path.join(dirs['initial_NICE_customer'], f'{initial_date}_crm_nice_customers.csv'))
    write_address_csv(freg_addresses,
        os.path.join(dirs['initial_FREG_address'],  f'{initial_date}_crm_freg_addresses.csv'))
    write_address_csv(bs_addresses,
        os.path.join(dirs['initial_BS_address'],    f'{initial_date}_crm_bs_addresses.csv'))
    write_address_csv(nice_addresses,
        os.path.join(dirs['initial_NICE_address'],  f'{initial_date}_crm_nice_addresses.csv'))

    print(f"Initial load: {initial_date}")
    print(f"Generating {num_days} days of updates...")

    # --- Daily update CSVs (SCD Type 2) ---
    for day in range(1, num_days + 1):
        upd_date = (datetime.now(timezone.utc)
                    - timedelta(days=num_days)
                    + timedelta(days=day)).strftime('%Y-%m-%d')

        upd_freg      = generate_daily_updates_freg(freg_customers, day)
        upd_bs        = generate_daily_updates_bs_or_nice(bs_customers, day)
        upd_nice      = generate_daily_updates_bs_or_nice(nice_customers, day)
        upd_freg_addr = generate_daily_updates_addresses(freg_addresses, day)
        upd_bs_addr   = generate_daily_updates_addresses(bs_addresses, day)
        upd_nice_addr = generate_daily_updates_addresses(nice_addresses, day)

        if upd_freg:
            write_freg_customer_csv(upd_freg,
                os.path.join(dirs['update_FREG_customer'], f'{upd_date}_crm_freg_customers.csv'))
        if upd_bs:
            write_bs_customer_csv(upd_bs,
                os.path.join(dirs['update_BS_customer'],   f'{upd_date}_crm_bs_customers.csv'))
        if upd_nice:
            write_nice_customer_csv(upd_nice,
                os.path.join(dirs['update_NICE_customer'], f'{upd_date}_crm_nice_customers.csv'))
        if upd_freg_addr:
            write_address_csv(upd_freg_addr,
                os.path.join(dirs['update_FREG_address'],  f'{upd_date}_crm_freg_addresses.csv'))
        if upd_bs_addr:
            write_address_csv(upd_bs_addr,
                os.path.join(dirs['update_BS_address'],    f'{upd_date}_crm_bs_addresses.csv'))
        if upd_nice_addr:
            write_address_csv(upd_nice_addr,
                os.path.join(dirs['update_NICE_address'],  f'{upd_date}_crm_nice_addresses.csv'))

        if day % 30 == 0:
            print(f"  Month {day // 30}: {upd_date}")

    print_report(
        freg_customers, bs_customers, nice_customers,
        freg_addresses, bs_addresses, nice_addresses,
        fuzzy_count=FUZZY_COUNT,
        steward_count=STEWARD_COUNT,
        cross_org_count=CROSS_ORG,
    )

    print("-" * 70)
    print("SCD TYPE 2 TEST DATA SUMMARY")
    print("-" * 70)
    print(f"Initial load:  {os.path.join(OUTPUT_DIR, 'initial')}/")
    print(f"               {initial_date}_crm_*.csv")
    print(f"Daily updates: {os.path.join(OUTPUT_DIR, 'update')}/")
    print(f"               {num_days} days ({num_months} month) of incremental changes")
    print(f"               ~0.5 % FREG changes/day, ~1 % BS/NICE changes/day")
    print(f"\nDirectory structure:")
    for src in [SOURCE_FREG, SOURCE_BS, SOURCE_NICE]:
        for phase in ['initial', 'update']:
            print(f"  output/{phase}/{src}/customer/")
            print(f"  output/{phase}/{src}/address/")
    print("-" * 70 + "\n")


if __name__ == '__main__':
    main()
